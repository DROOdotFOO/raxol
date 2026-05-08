defmodule Raxol.Symphony.Runners.Codex.ProtocolTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Runners.Codex.Protocol

  describe "outbound payload builders" do
    test "initialize_request/0 sets the client identity and initialize id" do
      payload = Protocol.initialize_request()

      assert payload["method"] == "initialize"
      assert payload["id"] == Protocol.initialize_id()
      assert payload["params"]["capabilities"]["experimentalApi"] == true
      assert payload["params"]["clientInfo"]["name"] == "raxol-symphony"
    end

    test "initialized_notification/0 has no id (notification)" do
      payload = Protocol.initialized_notification()
      assert payload["method"] == "initialized"
      refute Map.has_key?(payload, "id")
    end

    test "thread_start_request/2 carries cwd, approvalPolicy, sandbox, dynamicTools" do
      payload =
        Protocol.thread_start_request("/tmp/ws",
          approval_policy: "never",
          thread_sandbox: "workspace-write",
          dynamic_tools: [%{"name" => "linear_graphql"}]
        )

      assert payload["method"] == "thread/start"
      assert payload["id"] == Protocol.thread_start_id()
      assert payload["params"]["cwd"] == "/tmp/ws"
      assert payload["params"]["approvalPolicy"] == "never"
      assert payload["params"]["sandbox"] == "workspace-write"
      assert payload["params"]["dynamicTools"] == [%{"name" => "linear_graphql"}]
    end

    test "turn_start_request/6 carries threadId, prompt input, title, sandboxPolicy" do
      issue = %{identifier: "MT-1", title: "Refactor X"}
      payload = Protocol.turn_start_request(42, "thread-abc", "/tmp/ws", "do work", issue, [])

      assert payload["method"] == "turn/start"
      assert payload["id"] == 42
      assert payload["params"]["threadId"] == "thread-abc"
      assert payload["params"]["input"] == [%{"type" => "text", "text" => "do work"}]
      assert payload["params"]["title"] == "MT-1: Refactor X"
      assert payload["params"]["cwd"] == "/tmp/ws"
    end

    test "tool_call_result/2 wraps a result with the request id" do
      assert Protocol.tool_call_result(7, %{"success" => true}) ==
               %{"id" => 7, "result" => %{"success" => true}}
    end

    test "approval_result/2 wraps a decision string" do
      assert Protocol.approval_result(7, "acceptForSession") ==
               %{"id" => 7, "result" => %{"decision" => "acceptForSession"}}
    end
  end

  describe "classify/1 -- terminal turn events" do
    test "turn/completed -> {:turn_completed, event}" do
      payload = %{"method" => "turn/completed", "usage" => %{"total_tokens" => 100}}
      assert {:turn_completed, event} = Protocol.classify(payload)
      assert event.event == :turn_completed
      assert event.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 100}
    end

    test "turn/failed -> {:turn_failed, event, {:turn_failed, params}}" do
      payload = %{"method" => "turn/failed", "params" => %{"reason" => "timeout"}}

      assert {:turn_failed, event, {:turn_failed, %{"reason" => "timeout"}}} =
               Protocol.classify(payload)

      assert event.event == :turn_failed
    end

    test "turn/cancelled -> {:turn_failed, event, {:turn_cancelled, params}}" do
      payload = %{"method" => "turn/cancelled", "params" => %{"by" => "user"}}
      assert {:turn_failed, _, {:turn_cancelled, %{"by" => "user"}}} = Protocol.classify(payload)
    end
  end

  describe "classify/1 -- tool calls and approvals" do
    test "item/tool/call -> {:tool_call, id, name, args, event}" do
      payload = %{
        "method" => "item/tool/call",
        "id" => 9,
        "params" => %{"tool" => "linear_graphql", "arguments" => %{"q" => "x"}}
      }

      assert {:tool_call, 9, "linear_graphql", %{"q" => "x"}, event} = Protocol.classify(payload)
      assert event.event == :tool_use
      assert event.message == "tool: linear_graphql"
    end

    test "item/tool/call with missing tool name -> name nil" do
      payload = %{"method" => "item/tool/call", "id" => 9, "params" => %{}}
      assert {:tool_call, 9, nil, %{}, _} = Protocol.classify(payload)
    end

    test "item/commandExecution/requestApproval -> acceptForSession" do
      payload = %{"method" => "item/commandExecution/requestApproval", "id" => 5}
      assert {:approval, 5, "acceptForSession", _} = Protocol.classify(payload)
    end

    test "item/fileChange/requestApproval -> acceptForSession" do
      payload = %{"method" => "item/fileChange/requestApproval", "id" => 5}
      assert {:approval, 5, "acceptForSession", _} = Protocol.classify(payload)
    end

    test "execCommandApproval -> approved_for_session" do
      payload = %{"method" => "execCommandApproval", "id" => 5}
      assert {:approval, 5, "approved_for_session", _} = Protocol.classify(payload)
    end

    test "applyPatchApproval -> approved_for_session" do
      payload = %{"method" => "applyPatchApproval", "id" => 5}
      assert {:approval, 5, "approved_for_session", _} = Protocol.classify(payload)
    end

    test "item/tool/requestUserInput -> :input_required" do
      payload = %{"method" => "item/tool/requestUserInput", "id" => 5}
      assert {:input_required, _, :tool_user_input} = Protocol.classify(payload)
    end
  end

  describe "classify/1 -- notifications and responses" do
    test "result responses tagged :response" do
      assert {:response, %{"id" => 1, "result" => _}} =
               Protocol.classify(%{"id" => 1, "result" => %{}})
    end

    test "error responses tagged :response" do
      assert {:response, %{"id" => 1, "error" => _}} =
               Protocol.classify(%{"id" => 1, "error" => %{"code" => -1}})
    end

    test "agentMessage notification -> :text_delta with extracted text" do
      payload = %{"method" => "item/agentMessage/delta", "params" => %{"text" => "hello"}}
      assert {:notification, event} = Protocol.classify(payload)
      assert event.event == :text_delta
      assert event.message == "hello"
    end

    test "agentMessage with delta.text shape extracts text" do
      payload = %{"method" => "item/agentMessage", "params" => %{"delta" => %{"text" => "hi"}}}
      assert {:notification, %{event: :text_delta, message: "hi"}} = Protocol.classify(payload)
    end

    test "unknown notification -> :tool_use with method as message" do
      payload = %{"method" => "item/unknownThing"}

      assert {:notification, %{event: :tool_use, message: "item/unknownThing"}} =
               Protocol.classify(payload)
    end

    test "non-protocol payload -> :ignore" do
      assert :ignore = Protocol.classify(%{"foo" => "bar"})
      assert :ignore = Protocol.classify("not a map")
    end
  end

  describe "usage extraction" do
    test "top-level usage normalizes input/output/total tokens" do
      payload = %{
        "method" => "turn/completed",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20, "total_tokens" => 30}
      }

      assert {:turn_completed, %{usage: usage}} = Protocol.classify(payload)
      assert usage == %{input_tokens: 10, output_tokens: 20, total_tokens: 30}
    end

    test "usage tucked inside params is also picked up" do
      payload = %{"method" => "turn/completed", "params" => %{"usage" => %{"prompt_tokens" => 5}}}
      assert {:turn_completed, %{usage: %{input_tokens: 5}}} = Protocol.classify(payload)
    end

    test "no usage on text_delta events" do
      payload = %{"method" => "item/agentMessage/delta", "params" => %{"text" => "x"}}
      assert {:notification, event} = Protocol.classify(payload)
      refute Map.has_key?(event, :usage)
    end
  end
end
