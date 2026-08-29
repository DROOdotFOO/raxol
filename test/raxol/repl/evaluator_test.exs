defmodule Raxol.REPL.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Raxol.REPL.Evaluator

  describe "new/0" do
    test "creates evaluator with empty state" do
      eval = Evaluator.new()
      assert Evaluator.bindings(eval) == []
      assert Evaluator.history(eval) == []
    end
  end

  describe "eval/3" do
    test "evaluates simple expression" do
      eval = Evaluator.new()
      assert {:ok, result, _eval} = Evaluator.eval(eval, "1 + 2")
      assert result.value == 3
      assert result.formatted == "3"
    end

    test "persists bindings across calls" do
      eval = Evaluator.new()
      {:ok, _result, eval} = Evaluator.eval(eval, "x = 42")
      {:ok, result, _eval} = Evaluator.eval(eval, "x * 2")
      assert result.value == 84
    end

    test "captures IO output" do
      eval = Evaluator.new()
      {:ok, result, _eval} = Evaluator.eval(eval, ~S[IO.puts("hello")])
      assert result.output == "hello\n"
    end

    test "returns error for invalid syntax" do
      eval = Evaluator.new()
      {:error, reason, _eval} = Evaluator.eval(eval, "def +++ end")
      assert is_binary(reason)
    end

    test "returns error for runtime exceptions" do
      eval = Evaluator.new()
      {:error, reason, _eval} = Evaluator.eval(eval, "raise \"boom\"")
      assert reason =~ "boom"
    end

    test "times out on long-running code" do
      eval = Evaluator.new()

      {:error, reason, _eval} =
        Evaluator.eval(eval, ":timer.sleep(10_000)", timeout: 100)

      assert reason =~ "timed out"
    end

    test "kills evaluation that exceeds its heap budget" do
      eval = Evaluator.new()

      assert {:error, reason, ^eval} =
               Evaluator.eval(eval, "List.duplicate(0, 1_000_000)",
                 max_heap_bytes: 128_000
               )

      assert reason =~ "memory limit"
    end

    test "rejects oversized results before copying them to the owner" do
      eval = Evaluator.new()

      assert {:error, reason, ^eval} =
               Evaluator.eval(eval, "String.duplicate(\"x\", 10_000)",
                 max_result_bytes: 1_000
               )

      assert reason =~ "result limit"
    end

    test "preserves evaluator on error" do
      eval = Evaluator.new()
      {:ok, _result, eval} = Evaluator.eval(eval, "x = 10")
      {:error, _reason, eval} = Evaluator.eval(eval, "raise \"fail\"")
      assert Keyword.get(Evaluator.bindings(eval), :x) == 10
    end

    test "records history" do
      eval = Evaluator.new()
      {:ok, _result, eval} = Evaluator.eval(eval, "1 + 1")
      {:ok, _result, eval} = Evaluator.eval(eval, "2 + 2")
      history = Evaluator.history(eval)
      assert length(history) == 2
      assert {"2 + 2", _} = hd(history)
    end

    test "evaluates pattern matching" do
      eval = Evaluator.new()
      {:ok, _result, eval} = Evaluator.eval(eval, "{a, b} = {1, 2}")
      {:ok, result, _eval} = Evaluator.eval(eval, "a + b")
      assert result.value == 3
    end

    test "evaluates pipe chains" do
      eval = Evaluator.new()

      {:ok, result, _eval} =
        Evaluator.eval(eval, "[1,2,3] |> Enum.map(& &1 * 2) |> Enum.sum()")

      assert result.value == 12
    end

    test "handles multi-line code" do
      eval = Evaluator.new()

      code = """
      list = [1, 2, 3, 4, 5]
      Enum.filter(list, &(rem(&1, 2) == 0))
      """

      {:ok, result, _eval} = Evaluator.eval(eval, code)
      assert result.value == [2, 4]
    end
  end

  describe "reset_bindings/1" do
    test "clears bindings but keeps history" do
      eval = Evaluator.new()
      {:ok, _result, eval} = Evaluator.eval(eval, "x = 1")
      eval = Evaluator.reset_bindings(eval)
      assert Evaluator.bindings(eval) == []
      assert length(Evaluator.history(eval)) == 1
    end
  end

  describe "clear_history/1" do
    test "clears history but keeps bindings" do
      eval = Evaluator.new()
      {:ok, _result, eval} = Evaluator.eval(eval, "x = 1")
      eval = Evaluator.clear_history(eval)
      assert Evaluator.history(eval) == []
      assert Keyword.get(Evaluator.bindings(eval), :x) == 1
    end
  end
end
