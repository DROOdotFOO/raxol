defmodule Raxol.Agent.Conversation.RecorderTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Conversation.{Log, Recorder}
  alias Raxol.Agent.Conversation.Store.ETS

  setup do
    table = :"rec_items_#{System.unique_integer([:positive])}"
    log = start_supervised!({Log, store: {ETS, %{table: table}}})
    %{log: log, conv: "conv-#{System.unique_integer([:positive])}"}
  end

  describe "record_event/4" do
    test "maps a tool_use to a tool_call item", %{log: log, conv: conv} do
      {:ok, [item]} =
        Recorder.record_event(log, conv, [response_id: "r1"], {
          :tool_use,
          %{name: "search", arguments: %{q: "x"}, id: "t1"}
        })

      assert item.type == :tool_call
      assert item.data.name == "search"
      assert item.data.arguments == %{q: "x"}
      assert item.response_id == "r1"
      assert item.created_by == :assistant
    end

    test "maps a tool_result to a tool_result item", %{log: log, conv: conv} do
      {:ok, [item]} =
        Recorder.record_event(
          log,
          conv,
          [],
          {:tool_result, %{name: "search", result: %{hits: 3}}}
        )

      assert item.type == :tool_result
      assert item.data.result == %{hits: 3}
      assert item.created_by == :tool
    end

    test "maps a done to an assistant message item", %{log: log, conv: conv} do
      {:ok, [item]} =
        Recorder.record_event(log, conv, [], {:done, %{content: "the answer", usage: %{t: 1}}})

      assert item.type == :message
      assert item.data.role == :assistant
      assert item.data.content == "the answer"
      assert item.data.usage == %{t: 1}
    end

    test "maps an error to an error item", %{log: log, conv: conv} do
      {:ok, [item]} = Recorder.record_event(log, conv, [], {:error, :boom})
      assert item.type == :error
      assert item.data.reason == ":boom"
    end

    test "ignores text_delta and turn_complete (content lands at :done)", %{log: log, conv: conv} do
      assert {:ok, []} = Recorder.record_event(log, conv, [], {:text_delta, "hi"})
      assert {:ok, []} = Recorder.record_event(log, conv, [], {:turn_complete, %{iteration: 0}})
    end
  end

  describe "record_stream/4" do
    test "appends one item per meaningful event, in order", %{log: log, conv: conv} do
      events = [
        {:text_delta, "hi"},
        {:tool_use, %{name: "x", arguments: %{}, id: "t"}},
        {:tool_result, %{name: "x", result: %{ok: true}}},
        {:done, %{content: "answer", usage: %{}}}
      ]

      {:ok, items} = Recorder.record_stream(log, conv, events, response_id: "r1")

      assert Enum.map(items, & &1.type) == [:tool_call, :tool_result, :message]
      assert Enum.map(items, & &1.seq) == [0, 1, 2]
      assert List.last(items).data.content == "answer"
      assert Enum.all?(items, &(&1.response_id == "r1"))
    end

    test "the recorded items are durable in the log", %{log: log, conv: conv} do
      events = [{:done, %{content: "done", usage: %{}}}]
      {:ok, _} = Recorder.record_stream(log, conv, events)

      {:ok, stored} = Log.items(log, conv)
      assert Enum.map(stored, & &1.type) == [:message]
    end
  end
end
