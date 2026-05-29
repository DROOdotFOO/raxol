defmodule Raxol.Agent.Memory.RecordTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Memory.Record

  describe "new/1" do
    test "fills id, timestamps, and defaults" do
      r = Record.new(%{content: "hello"})
      assert is_binary(r.id) and byte_size(r.id) > 0
      assert r.content == "hello"
      assert r.type == :note
      assert r.tags == []
      assert is_integer(r.inserted_at)
      assert r.last_accessed == r.inserted_at
    end

    test "normalizes string type to a known atom, unknown to :note" do
      assert Record.new(%{content: "x", type: "decision"}).type == :decision
      assert Record.new(%{content: "x", type: "bogus"}).type == :note
      assert Record.new(%{content: "x", type: :gotcha}).type == :gotcha
    end

    test "downcases and dedups tags" do
      assert Record.new(%{content: "x", tags: ["Elixir", "elixir", "OTP"]}).tags ==
               ["elixir", "otp"]
    end

    test "raises without content" do
      assert_raise KeyError, fn -> Record.new(%{type: :note}) end
    end
  end

  describe "tokenize/1" do
    test "downcases, splits on non-word, drops short tokens, dedups" do
      assert Record.tokenize("Elixir GenServer, supervision-tree!") ==
               ["elixir", "genserver", "supervision", "tree"]
    end

    test "drops tokens of two characters or fewer" do
      assert Record.tokenize("a be cat done") == ["cat", "done"]
    end

    test "non-binary returns empty" do
      assert Record.tokenize(nil) == []
    end
  end
end
