defmodule Raxol.Agent.Harness.CursorTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Harness.Cursor

  test "names the cursor-agent binary" do
    assert Cursor.executable() == "cursor-agent"
    assert Cursor.name() == "Cursor"
  end

  describe "args/1" do
    test "builds a stream-json invocation" do
      assert Cursor.args(%{prompt: "p"}) == ["-p", "p", "--output-format", "stream-json"]
    end

    test "appends model and mcp config when present" do
      args = Cursor.args(%{prompt: "p", model: "gpt-5", mcp_config_path: "/tmp/m.json"})
      assert "--model" in args and "gpt-5" in args
      assert "--mcp-config" in args and "/tmp/m.json" in args
    end
  end

  test "parse_line/1 delegates to the stream-json parser" do
    line = ~s({"type":"result","subtype":"success","result":"ok","usage":{}})
    assert [{:done, %{content: "ok"}}] = Cursor.parse_line(line)
  end
end
