defmodule Raxol.Agent.Harness.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Harness.ClaudeCode

  describe "executable/0 and name/0" do
    test "names the claude binary" do
      assert ClaudeCode.executable() == "claude"
      assert ClaudeCode.name() == "Claude Code"
    end
  end

  describe "args/1" do
    test "builds a non-interactive stream-json invocation" do
      args = ClaudeCode.args(%{prompt: "do x"})
      assert args == ["-p", "do x", "--output-format", "stream-json", "--verbose"]
    end

    test "appends model, system prompt, and mcp config when present" do
      args =
        ClaudeCode.args(%{
          prompt: "p",
          model: "claude-opus-4-8",
          system_prompt: "be terse",
          mcp_config_path: "/tmp/mcp.json"
        })

      assert "--model" in args and "claude-opus-4-8" in args
      assert "--append-system-prompt" in args and "be terse" in args
      assert "--mcp-config" in args and "/tmp/mcp.json" in args
    end

    test "omits optional flags when their values are nil/blank" do
      args = ClaudeCode.args(%{prompt: "p", model: nil, system_prompt: "", mcp_config_path: nil})
      refute "--model" in args
      refute "--append-system-prompt" in args
      refute "--mcp-config" in args
    end

    test "appends extra_args verbatim at the end" do
      args = ClaudeCode.args(%{prompt: "p", extra_args: ["--foo", "bar"]})
      assert List.last(args) == "bar"
      assert "--foo" in args
    end
  end

  test "parse_line/1 delegates to the stream-json parser" do
    line = ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}})
    assert ClaudeCode.parse_line(line) == [{:text, "hi"}]
  end
end
