defmodule Raxol.Agent.ThreadLogTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.ThreadEvent
  alias Raxol.Agent.ThreadLog

  describe "normalize/1" do
    test "nil passes through" do
      assert ThreadLog.normalize(nil) == nil
    end

    test "{module, config} tuple is preserved" do
      assert ThreadLog.normalize({ThreadLog.Ets, %{table: :t}}) ==
               {ThreadLog.Ets, %{table: :t}}
    end

    test "bare module becomes {module, %{}}" do
      assert ThreadLog.normalize(ThreadLog.Ets) == {ThreadLog.Ets, %{}}
    end
  end

  describe "dispatcher with nil adapter" do
    test "append returns {:ok, :no_log}" do
      assert {:ok, :no_log} = ThreadLog.append(nil, "thr-1", :directive, %{})
    end

    test "list returns {:ok, []}" do
      assert {:ok, []} = ThreadLog.list(nil, "thr-1")
    end

    test "list_by_kind returns {:ok, []}" do
      assert {:ok, []} = ThreadLog.list_by_kind(nil, "thr-1", :directive)
    end

    test "latest returns {:error, :not_found}" do
      assert {:error, :not_found} = ThreadLog.latest(nil, "thr-1")
    end

    test "truncate returns :ok" do
      assert :ok = ThreadLog.truncate(nil, "thr-1", 5)
    end
  end

  describe "ThreadEvent.new/1" do
    test "constructs from required fields" do
      event =
        ThreadEvent.new(
          thread_id: "thr-1",
          sequence: 0,
          kind: :directive,
          payload: %{step: 1}
        )

      assert event.thread_id == "thr-1"
      assert event.sequence == 0
      assert event.kind == :directive
      assert event.payload == %{step: 1}
      assert event.metadata == %{}
      assert %DateTime{} = event.recorded_at
    end

    test "raises without required fields" do
      assert_raise KeyError, fn ->
        ThreadEvent.new(thread_id: "thr-1", sequence: 0)
      end
    end

    test "preserves explicit metadata and recorded_at" do
      ts = ~U[2026-01-01 00:00:00Z]

      event =
        ThreadEvent.new(
          thread_id: "thr-1",
          sequence: 3,
          kind: :tool_call,
          metadata: %{causation_id: "abc"},
          recorded_at: ts
        )

      assert event.metadata == %{causation_id: "abc"}
      assert event.recorded_at == ts
    end
  end
end
