defmodule Raxol.Agent.Harness.GrokBuildTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Harness.GrokBuild

  # Lines copied from xAI's headless-mode reference for `--output-format
  # streaming-json`, so the parser is pinned to the documented wire shape
  # rather than to our reading of it.
  @thought ~s({"type":"thought","data":"Analyzing the directory structure..."})
  @tool_call ~s({"type":"tool_call","toolCallId":"call_1","title":"Read","kind":"read","status":"in_progress","toolName":"read_file","rawInput":{"path":"src/main.rs"},"content":[],"locations":[]})
  @tool_update ~s({"type":"tool_call_update","toolCallId":"call_1","status":"completed","content":[],"rawOutput":{"lines":42},"locations":[]})
  @text ~s({"type":"text","data":"Here's a summary"})
  @usage ~s({"type":"usage","messageId":"resp_1","stopReason":"end_turn","usage":{"input_tokens":812,"output_tokens":45},"signature":"..."})
  @end_line ~s({"type":"end","stopReason":"end_turn","sessionId":"abc123","requestId":"xyz789","usage":{"input_tokens":812,"output_tokens":45},"num_turns":7})

  describe "args/1" do
    test "a bare prompt runs headless streaming JSON" do
      assert GrokBuild.args(%{prompt: "hi"}) ==
               ["-p", "hi", "--output-format", "streaming-json"]
    end

    test "model and system prompt map onto -m and --rules" do
      args = GrokBuild.args(%{prompt: "hi", model: "grok-build", system_prompt: "be terse"})

      assert args ==
               [
                 "-p",
                 "hi",
                 "--output-format",
                 "streaming-json",
                 "-m",
                 "grok-build",
                 "--rules",
                 "be terse"
               ]
    end

    test "an empty system prompt adds no flag" do
      refute "--rules" in GrokBuild.args(%{prompt: "hi", system_prompt: ""})
    end

    test "extra args land last, so a caller can pass --tools or --max-turns" do
      args = GrokBuild.args(%{prompt: "hi", extra_args: ["--max-turns", "3"]})
      assert List.last(args) == "3"
      assert "--max-turns" in args
    end
  end

  describe "parse_line/1" do
    test "text becomes a :text event" do
      assert GrokBuild.parse_line(@text) == [{:text, "Here's a summary"}]
    end

    test "thought becomes a :reasoning event, not answer text" do
      assert GrokBuild.parse_line(@thought) ==
               [{:reasoning, "Analyzing the directory structure..."}]
    end

    test "tool_call carries the internal tool id, raw input and call id" do
      assert [{:tool_call, call}] = GrokBuild.parse_line(@tool_call)
      assert call.name == "read_file"
      assert call.id == "call_1"
      assert call.input == %{"path" => "src/main.rs"}
    end

    # `end` is documented to carry spend, never the answer: the text arrived as
    # `text` lines, and Backend.Native substitutes its accumulated content for
    # an empty one. Emitting "" here is what triggers that substitution.
    test "end closes the run with usage and an empty content" do
      assert [{:done, %{content: "", usage: usage}}] = GrokBuild.parse_line(@end_line)
      assert usage["input_tokens"] == 812
      assert usage["output_tokens"] == 45
      refute Map.has_key?(usage, "cost")
    end

    test "a stamped total_cost_usd rides on usage as a USD cost for the spend plumbing" do
      line =
        ~s({"type":"end","stopReason":"end_turn","usage":{"input_tokens":1},"total_cost_usd":0.0127})

      assert [{:done, %{usage: usage}}] = GrokBuild.parse_line(line)
      assert usage["cost"] == %{"amount" => 0.0127, "currency" => "USD"}
    end

    test "error surfaces its message" do
      line = ~s({"type":"error","message":"Couldn't start session: nope"})

      assert GrokBuild.parse_line(line) == [
               {:error, {:grok_error, "Couldn't start session: nope"}}
             ]
    end

    test "per-response usage and tool progress are not events of their own" do
      assert GrokBuild.parse_line(@usage) == []
      assert GrokBuild.parse_line(@tool_update) == []
    end

    # xAI documents the type list as non-exhaustive, so an unknown type must
    # never break a run that is otherwise fine.
    test "unknown types and non-JSON lines parse to no events" do
      assert GrokBuild.parse_line(~s({"type":"plan","entries":[]})) == []
      assert GrokBuild.parse_line(~s({"type":"max_turns_reached"})) == []
      assert GrokBuild.parse_line("Downloading update...") == []
      assert GrokBuild.parse_line("") == []
    end
  end

  describe "harness contract" do
    test "the CLI is grok and it owns its own tool loop" do
      assert GrokBuild.executable() == "grok"
      assert Raxol.Agent.AIBackend.handles_tools_internally?(Raxol.Agent.Backend.GrokBuild)
    end

    # There is no per-run flag to hand `grok` a generated MCP config, so the
    # runtime must not build one and quietly believe Raxol's tools are exposed.
    test "it does not claim MCP tool injection" do
      refute GrokBuild.injects_mcp_tools?()
      refute Raxol.Agent.NativeHarness.injects_mcp_tools?(GrokBuild)
    end

    test "the backend resolves through the selector" do
      assert {:ok, Raxol.Agent.Backend.GrokBuild, _opts} =
               Raxol.Agent.Backend.Selector.select(%Raxol.Agent.ExecutorConfig{
                 backend: :grok_native
               })
    end
  end
end
