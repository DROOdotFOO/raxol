defmodule Mix.Tasks.Raxol.ReplTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Raxol.Repl

  describe "parse_options!/1" do
    test "uses strict sandboxing and the configured timeout by default" do
      assert [sandbox: :strict, timeout: timeout] = Repl.parse_options!([])
      assert timeout == Raxol.Core.Defaults.timeout_ms()
    end

    test "accepts each exact sandbox value and a positive timeout" do
      for {value, level} <- [
            {"none", :none},
            {"standard", :standard},
            {"strict", :strict}
          ] do
        assert [sandbox: ^level, timeout: 250] =
                 Repl.parse_options!(["--sandbox", value, "--timeout", "250"])
      end
    end

    test "rejects unknown and case-mistyped sandbox values" do
      for value <- ["Strict", "STANDARD", "typo", ""] do
        assert_raise Mix.Error, ~r/invalid --sandbox value/, fn ->
          Repl.parse_options!(["--sandbox", value])
        end
      end
    end

    test "rejects zero and negative timeouts" do
      for timeout <- ["0", "-1"] do
        assert_raise Mix.Error, ~r/expected a positive integer/, fn ->
          Repl.parse_options!(["--timeout", timeout])
        end
      end
    end

    test "rejects malformed and unknown options" do
      for args <- [["--timeout", "later"], ["--unknown"]] do
        assert_raise Mix.Error, ~r/invalid raxol\.repl options/, fn ->
          Repl.parse_options!(args)
        end
      end
    end
  end
end
