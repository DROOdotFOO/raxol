defmodule Raxol.Symphony.Runners.Codex.FramingTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Runners.Codex.Framing

  describe "push/2" do
    test "completes a line on :eol and resets the buffer" do
      assert {:line, "hello", ""} = Framing.push("hel", {:eol, "lo"})
    end

    test "accumulates partial bytes on :noeol" do
      assert {:partial, "hello"} = Framing.push("hel", {:noeol, "lo"})
    end

    test "completes a line that arrived in two partials and a final eol" do
      {:partial, b1} = Framing.push("", {:noeol, ~s({"a":)})
      {:partial, b2} = Framing.push(b1, {:noeol, "1"})
      {:line, line, ""} = Framing.push(b2, {:eol, "}"})
      assert line == ~s({"a":1})
    end

    test "handles back-to-back full lines via separate push calls" do
      {:line, line1, buf} = Framing.push("", {:eol, ~s({"a":1})})
      assert line1 == ~s({"a":1})
      {:line, line2, _} = Framing.push(buf, {:eol, ~s({"b":2})})
      assert line2 == ~s({"b":2})
    end
  end

  describe "decode/1" do
    test "decodes a JSON object" do
      assert {:ok, %{"id" => 1}} = Framing.decode(~s({"id":1}))
    end

    test "skips empty lines" do
      assert {:ok, :empty} = Framing.decode("")
      assert {:ok, :empty} = Framing.decode("   \t  \n")
    end

    test "returns the Jason error on garbage input" do
      assert {:error, %Jason.DecodeError{}} = Framing.decode("not json")
    end
  end

  describe "encode!/1" do
    test "encodes a map as JSON terminated by newline" do
      assert Framing.encode!(%{"id" => 1}) == ~s({"id":1}) <> "\n"
    end
  end
end
