defmodule Raxol.UI.Components.Harness.LineDiffTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.LineDiff

  describe "diff/2" do
    test "identical content is all equal" do
      assert LineDiff.diff("a\nb\nc", "a\nb\nc") ==
               [equal: "a", equal: "b", equal: "c"]
    end

    test "pure addition" do
      assert LineDiff.diff("a\nc", "a\nb\nc") ==
               [equal: "a", insert: "b", equal: "c"]
    end

    test "pure deletion" do
      assert LineDiff.diff("a\nb\nc", "a\nc") ==
               [equal: "a", delete: "b", equal: "c"]
    end

    test "single line replaced keeps surrounding context" do
      assert LineDiff.diff("a\nb\nc", "a\nx\nc") ==
               [equal: "a", delete: "b", insert: "x", equal: "c"]
    end

    test "completely disjoint content deletes then inserts" do
      assert LineDiff.diff("a\nb", "c\nd") ==
               [delete: "a", delete: "b", insert: "c", insert: "d"]
    end

    test "empty old reads as a whole-file add" do
      assert LineDiff.diff("", "a\nb") == [insert: "a", insert: "b"]
    end

    test "empty new reads as a whole-file removal" do
      assert LineDiff.diff("a\nb", "") == [delete: "a", delete: "b"]
    end

    test "both empty yields no ops" do
      assert LineDiff.diff("", "") == []
    end

    test "matching trailing newline is context, not a spurious change" do
      assert LineDiff.diff("a\n", "a\n") == [equal: "a", equal: ""]
    end

    test "realistic mixed edit: context, a deletion, and an insertion" do
      old = "def f(x) do\n  IO.inspect(x)\n  x\nend"
      new = "def f(x) do\n  x\n  x + 1\nend"

      assert LineDiff.diff(old, new) == [
               equal: "def f(x) do",
               delete: "  IO.inspect(x)",
               equal: "  x",
               insert: "  x + 1",
               equal: "end"
             ]
    end
  end
end
