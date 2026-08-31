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

  describe "limits the heap cap alone does not cover" do
    test "captured output stops accumulating at the limit" do
      # Output goes to a SEPARATE process, so it never counted against the
      # evaluation's own max_heap_size: this loop allocates almost nothing
      # locally while growing that process without bound. Nor could the caller
      # measure it -- output arrives as refc binaries, which live off-heap and
      # are invisible to process_info(:memory). So the cap is enforced where
      # the bytes are accepted.
      eval = Evaluator.new()
      limit = 100_000

      assert {:ok, result, _eval} =
               Evaluator.eval(
                 eval,
                 ~s|Enum.each(1..50_000, fn _ -> IO.puts(String.duplicate("x", 1024)) end)|,
                 max_result_bytes: limit,
                 timeout: 30_000
               )

      # 50MB was written; what is kept is bounded, and says it was cut.
      assert byte_size(result.output) < limit + 100
      assert result.output =~ "output truncated"
    end

    test "output under the limit is captured whole, unannotated" do
      eval = Evaluator.new()

      assert {:ok, result, _eval} =
               Evaluator.eval(eval, ~s|IO.puts("hello"); IO.puts("world")|)

      assert result.output == "hello\nworld\n"
      refute result.output =~ "truncated"
    end

    test "another evaluation's result is never consumed as this one's" do
      # The child's reply used to be untagged, and `demonitor(ref, [:flush])`
      # flushes only the :DOWN. So a reply that raced its timeout stayed in the
      # mailbox and the NEXT eval's receive matched it, attributing one
      # expression's value to another.
      #
      # The race itself is not reproducible on demand, so this asserts the
      # invariant that makes it impossible instead: a result this evaluation
      # did not mint is not eligible, whatever it looks like.
      send(self(), {:eval_result, {:ok, :stale_untagged, [], ""}})
      send(self(), {:eval_result, make_ref(), {:ok, :stale_tagged, [], ""}})

      eval = Evaluator.new()

      assert {:ok, result, _eval} = Evaluator.eval(eval, ":mine")
      assert result.value == :mine

      # Both plants are still queued: neither was mistaken for this result.
      assert_received {:eval_result, {:ok, :stale_untagged, [], ""}}
      assert_received {:eval_result, _, {:ok, :stale_tagged, [], ""}}
    end
  end

  # `:io.format/2` does not send the finished bytes -- it sends
  # `{put_chars, unicode, io_lib, format, [Format, Args]}` and asks the GROUP
  # LEADER to build them. `CaptureIO` applied that in its own process, which
  # has no `max_heap_size`, so the expansion escaped both the evaluation's heap
  # cap and the capture's byte cap: `~1000000000c` allocated a gigabyte before
  # anything counted it.
  describe "output built by the group leader is bounded too" do
    test "an expansion far over the cap does not allocate it" do
      eval = Evaluator.new()

      before = :erlang.memory(:total)

      assert {:ok, result, _eval} =
               Evaluator.eval(
                 eval,
                 ~S|:io.format("~100000000c", [?x]); :done|,
                 timeout: 15_000,
                 max_result_bytes: 4_096,
                 max_heap_bytes: 8 * 1024 * 1024
               )

      assert result.value == :done

      # 100M characters. Anything close to that reaching the VM means the
      # expansion ran unbounded somewhere.
      growth = :erlang.memory(:total) - before

      assert growth < 50_000_000,
             "the group leader allocated #{growth} bytes for a capped write"
    end

    test "output within the cap still arrives" do
      eval = Evaluator.new()

      assert {:ok, result, _eval} =
               Evaluator.eval(eval, ~S|:io.format("~s", ["hello"]); :ok|,
                 max_result_bytes: 4_096
               )

      assert result.output =~ "hello"
      assert result.value == :ok
    end
  end
end
