defmodule Raxol.Agent.Stream.EventTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Stream.Event

  describe "from_tuple/1" do
    test "lifts text_delta" do
      assert %Event.TextDelta{text: "hi"} =
               Event.from_tuple({:text_delta, "hi"})
    end

    test "lifts tool_use with full info" do
      info = %{name: "linear_graphql", arguments: %{q: 1}, id: "call_1"}

      assert %Event.ToolUse{
               name: "linear_graphql",
               arguments: %{q: 1},
               id: "call_1"
             } =
               Event.from_tuple({:tool_use, info})
    end

    test "lifts tool_use with missing optional fields" do
      assert %Event.ToolUse{name: "x", arguments: %{}, id: nil} =
               Event.from_tuple({:tool_use, %{name: "x"}})
    end

    test "lifts tool_result" do
      assert %Event.ToolResult{name: "x", result: %{ok: true}} =
               Event.from_tuple(
                 {:tool_result, %{name: "x", result: %{ok: true}}}
               )
    end

    test "lifts turn_complete with defaults" do
      assert %Event.TurnComplete{content: "", usage: %{}, iteration: 0} =
               Event.from_tuple({:turn_complete, %{}})
    end

    test "lifts done with defaults" do
      assert %Event.Done{content: "answer", tool_results: [], usage: %{}} =
               Event.from_tuple({:done, %{content: "answer"}})
    end

    test "lifts error" do
      assert %Event.Error{reason: :timeout} =
               Event.from_tuple({:error, :timeout})
    end

    test "wraps unknown shapes as Error rather than raising" do
      assert %Event.Error{reason: {:unknown_event, :nope}} =
               Event.from_tuple(:nope)
    end
  end

  describe "to_payload/1" do
    test "TextDelta payload carries the text as message" do
      payload = Event.to_payload(%Event.TextDelta{text: "hello"})
      assert payload.event == :text_delta
      assert payload.message == "hello"
      assert %DateTime{} = payload.timestamp
    end

    test "ToolUse payload carries name in message and full info in payload" do
      ev = %Event.ToolUse{name: "linear_graphql", arguments: %{q: 1}, id: "id1"}
      payload = Event.to_payload(ev)

      assert payload.event == :tool_use
      assert payload.message == "tool: linear_graphql"

      assert payload.payload == %{
               name: "linear_graphql",
               arguments: %{q: 1},
               id: "id1"
             }
    end

    test "ToolResult payload" do
      ev = %Event.ToolResult{name: "x", result: %{ok: 1}}
      payload = Event.to_payload(ev)

      assert payload.event == :tool_result
      assert payload.message =~ "x"
      assert payload.payload == %{name: "x", result: %{ok: 1}}
    end

    test "TurnComplete payload promotes usage" do
      ev = %Event.TurnComplete{
        content: "x",
        usage: %{total_tokens: 42},
        iteration: 1
      }

      payload = Event.to_payload(ev)

      assert payload.event == :turn_completed
      assert payload.usage == %{total_tokens: 42}
    end

    test "Done payload uses content as message" do
      ev = %Event.Done{content: "final answer", tool_results: [], usage: %{}}
      payload = Event.to_payload(ev)

      assert payload.event == :turn_completed
      assert payload.message == "final answer"
    end

    test "Error payload" do
      assert %{event: :turn_failed, message: ":boom"} =
               Event.to_payload(%Event.Error{reason: :boom})
    end

    test "accepts raw tuples (composes from_tuple + to_payload)" do
      assert %{event: :text_delta, message: "ok"} =
               Event.to_payload({:text_delta, "ok"})
    end
  end
end
