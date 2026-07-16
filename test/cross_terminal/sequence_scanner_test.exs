defmodule Raxol.CrossTerminal.SequenceScannerTest do
  @moduledoc """
  Tests for the shared ANSI sequence linter used as a test oracle.

  Focus: `scan/1` must terminate deterministically on every input,
  including malformed/truncated escape sequences. A test oracle that hangs
  is fail-closed (it never falsely passes) but still unusable, so
  termination is the contract we assert here.
  """
  use ExUnit.Case, async: true

  alias Raxol.Test.CrossTerminal.SequenceScanner, as: Scanner

  @known_token_types [:csi, :osc, :dcs, :esc, :text]

  # Runs scan/1 with a hard timeout so an infinite loop surfaces as a test
  # failure instead of hanging the whole suite.
  defp scan_within(bytes, timeout_ms \\ 1_000) do
    task = Task.async(fn -> Scanner.scan(bytes) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, tokens} -> tokens
      nil -> flunk("scan/1 did not terminate within #{timeout_ms}ms")
    end
  end

  describe "termination on a lone trailing ESC (Lesson #8 regression)" do
    test "scan/1 terminates on a lone trailing ESC and preserves the leading text" do
      # Before the fix this hung: the generic fallback matched the ESC at
      # position 0, sliced zero bytes, and recursed on the unchanged input.
      tokens = scan_within("abc\e")

      assert tokens == [{:text, "abc"}, {:text, "\e"}]
    end

    test "scan/1 terminates on a bare lone ESC with no other content" do
      assert scan_within("\e") == [{:text, "\e"}]
    end

    test "a lone trailing ESC after a completed sequence still terminates" do
      tokens = scan_within("\e[0m\e")

      assert tokens == [{:csi, "0", "m"}, {:text, "\e"}]
    end

    test "every emitted token stays within the known token types" do
      for token <- scan_within("abc\e") do
        assert elem(token, 0) in @known_token_types
      end
    end
  end

  describe "existing scanning behavior is unchanged" do
    test "a complete CSI SGR sequence is tokenized as before" do
      assert Scanner.scan("\e[31mhi") == [{:csi, "31", "m"}, {:text, "hi"}]
    end

    test "a mid-stream ESC that is followed by a byte is not treated as text" do
      # "\eb" is a two-byte ESC dispatch, distinct from a lone trailing ESC.
      assert Scanner.scan("a\eb") == [{:text, "a"}, {:esc, "b"}]
    end
  end
end
