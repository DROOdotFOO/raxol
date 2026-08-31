defmodule Raxol.Agent.Actions.AnchorTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Actions.Anchor

  describe "split/1 and join/2 round-trip" do
    for content <- [
          "",
          "\n",
          "a",
          "a\n",
          "a\nb",
          "a\nb\n",
          "\n\n",
          "a\n\nb\n",
          "trailing spaces   \n"
        ] do
      test "#{inspect(content)}" do
        content = unquote(content)
        {lines, trailing?} = Anchor.split(content)
        assert Anchor.join(lines, trailing?) == content
      end
    end
  end

  describe "split/1" do
    test "a trailing newline is a flag, not an empty last line" do
      assert Anchor.split("a\nb\n") == {["a", "b"], true}
    end

    test "no trailing newline is reported as such" do
      assert Anchor.split("a\nb") == {["a", "b"], false}
    end

    test "a lone newline is one empty line" do
      assert Anchor.split("\n") == {[""], true}
    end

    test "empty content has no lines" do
      assert Anchor.split("") == {[], false}
    end
  end

  describe "hash/1" do
    test "is stable and six lowercase hex digits" do
      hash = Anchor.hash("defp handle(x) do")
      assert hash == Anchor.hash("defp handle(x) do")
      assert String.match?(hash, ~r/\A[0-9a-f]{6}\z/)
    end

    test "distinguishes lines that differ only in whitespace" do
      refute Anchor.hash("  x") == Anchor.hash("    x")
      refute Anchor.hash("x") == Anchor.hash("x ")
    end
  end

  describe "render/1" do
    test "prefixes each line with its number and hash" do
      rendered = Anchor.render(["alpha", "beta"], 1)

      assert rendered == "1:#{Anchor.hash("alpha")}|alpha\n2:#{Anchor.hash("beta")}|beta"
    end

    test "numbers from the given offset so a windowed read stays addressable" do
      rendered = Anchor.render(["beta"], 2)
      assert rendered == "2:#{Anchor.hash("beta")}|beta"
    end

    test "renders an empty line as a bare prefix" do
      assert Anchor.render([""], 1) == "1:#{Anchor.hash("")}|"
    end
  end

  describe "parse/1" do
    test "accepts a rendered prefix" do
      assert {:ok, {12, "a3f1c2"}} = Anchor.parse("12:a3f1c2")
    end

    test "refuses a missing hash" do
      assert {:error, :malformed_anchor} = Anchor.parse("12")
    end

    test "refuses a non-numeric line" do
      assert {:error, :malformed_anchor} = Anchor.parse("x:a3f1c2")
    end

    test "refuses line zero" do
      assert {:error, :malformed_anchor} = Anchor.parse("0:a3f1c2")
    end

    test "refuses a hash of the wrong length" do
      assert {:error, :malformed_anchor} = Anchor.parse("12:a3f1")
      assert {:error, :malformed_anchor} = Anchor.parse("12:a3f1c2d4")
    end

    test "refuses uppercase or non-hex" do
      assert {:error, :malformed_anchor} = Anchor.parse("12:A3F1C2")
      assert {:error, :malformed_anchor} = Anchor.parse("12:zzzzzz")
    end

    test "refuses a non-binary" do
      assert {:error, :malformed_anchor} = Anchor.parse(12)
      assert {:error, :malformed_anchor} = Anchor.parse(nil)
    end
  end

  describe "verify/2" do
    setup do
      {lines, _} = Anchor.split("alpha\nbeta\ngamma\n")
      %{lines: lines}
    end

    test "accepts an anchor that still names its line", %{lines: lines} do
      assert :ok = Anchor.verify(lines, {2, Anchor.hash("beta")})
    end

    test "reports a line that no longer holds those bytes", %{lines: lines} do
      stale = Anchor.hash("beta_old")

      assert {:error, {:anchor_mismatch, 2, ^stale, actual}} =
               Anchor.verify(lines, {2, stale})

      assert actual == Anchor.hash("beta")
    end

    test "reports a line past the end of the file", %{lines: lines} do
      assert {:error, {:anchor_out_of_range, 9, 3}} =
               Anchor.verify(lines, {9, Anchor.hash("beta")})
    end
  end
end
