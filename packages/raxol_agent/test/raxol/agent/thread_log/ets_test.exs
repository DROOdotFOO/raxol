defmodule Raxol.Agent.ThreadLog.EtsTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.ThreadEvent
  alias Raxol.Agent.ThreadLog.Ets

  setup do
    nonce = System.unique_integer([:positive])
    table = :"thread_log_test_#{nonce}"
    seq_table = :"#{table}_seq"

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
      if :ets.whereis(seq_table) != :undefined, do: :ets.delete(seq_table)
    end)

    {:ok, config: %{table: table}}
  end

  describe "append + latest" do
    test "first append on a fresh thread starts at sequence 0", %{
      config: config
    } do
      assert {:ok, %ThreadEvent{sequence: 0}} =
               Ets.append(config, "thr-1", :directive, %{step: 1})

      assert {:ok, %ThreadEvent{sequence: 0, kind: :directive, payload: %{step: 1}}} =
               Ets.latest(config, "thr-1")
    end

    test "subsequent appends increment sequence monotonically", %{
      config: config
    } do
      for n <- 0..4 do
        {:ok, %ThreadEvent{sequence: ^n}} =
          Ets.append(config, "thr-1", :tool_call, %{n: n})
      end

      assert {:ok, %ThreadEvent{sequence: 4}} = Ets.latest(config, "thr-1")
    end

    test "sequence is isolated per thread", %{config: config} do
      {:ok, %{sequence: 0}} = Ets.append(config, "thr-a", :message, "hello")
      {:ok, %{sequence: 0}} = Ets.append(config, "thr-b", :message, "world")
      {:ok, %{sequence: 1}} = Ets.append(config, "thr-a", :message, "from a")

      assert {:ok, %{sequence: 1, payload: "from a"}} =
               Ets.latest(config, "thr-a")

      assert {:ok, %{sequence: 0, payload: "world"}} =
               Ets.latest(config, "thr-b")
    end

    test "latest returns :not_found for unknown thread", %{config: config} do
      assert {:error, :not_found} = Ets.latest(config, "ghost")
    end

    test "metadata is preserved verbatim", %{config: config} do
      {:ok, event} =
        Ets.append(config, "thr-1", :directive, "p",
          metadata: %{causation_id: "abc", trace_id: "def"}
        )

      assert event.metadata == %{causation_id: "abc", trace_id: "def"}
    end
  end

  describe "list" do
    test "returns all events in ascending sequence by default", %{
      config: config
    } do
      for n <- 0..4, do: Ets.append(config, "thr-1", :tool_call, n)

      assert {:ok, events} = Ets.list(config, "thr-1")
      sequences = Enum.map(events, & &1.sequence)
      assert sequences == [0, 1, 2, 3, 4]
    end

    test "respects :from and :to bounds (inclusive)", %{config: config} do
      for n <- 0..9, do: Ets.append(config, "thr-1", :tool_call, n)

      assert {:ok, events} = Ets.list(config, "thr-1", from: 2, to: 5)
      assert Enum.map(events, & &1.sequence) == [2, 3, 4, 5]
    end

    test "respects :limit", %{config: config} do
      for n <- 0..9, do: Ets.append(config, "thr-1", :tool_call, n)

      assert {:ok, events} = Ets.list(config, "thr-1", limit: 3)
      assert length(events) == 3
      assert Enum.map(events, & &1.sequence) == [0, 1, 2]
    end

    test ":order :desc reverses the result", %{config: config} do
      for n <- 0..4, do: Ets.append(config, "thr-1", :tool_call, n)

      assert {:ok, events} = Ets.list(config, "thr-1", order: :desc)
      assert Enum.map(events, & &1.sequence) == [4, 3, 2, 1, 0]
    end

    test "returns empty for unknown thread", %{config: config} do
      assert {:ok, []} = Ets.list(config, "ghost")
    end

    test "isolates threads", %{config: config} do
      Ets.append(config, "thr-a", :message, "A")
      Ets.append(config, "thr-b", :message, "B")

      assert {:ok, [%{payload: "A"}]} = Ets.list(config, "thr-a")
      assert {:ok, [%{payload: "B"}]} = Ets.list(config, "thr-b")
    end
  end

  describe "list_by_kind" do
    test "filters by kind preserving sequence order", %{config: config} do
      Ets.append(config, "thr-1", :directive, %{n: 1})
      Ets.append(config, "thr-1", :tool_call, %{n: 2})
      Ets.append(config, "thr-1", :directive, %{n: 3})
      Ets.append(config, "thr-1", :tool_call, %{n: 4})

      assert {:ok, [%{payload: %{n: 1}}, %{payload: %{n: 3}}]} =
               Ets.list_by_kind(config, "thr-1", :directive)

      assert {:ok, [%{payload: %{n: 2}}, %{payload: %{n: 4}}]} =
               Ets.list_by_kind(config, "thr-1", :tool_call)
    end

    test "respects :limit", %{config: config} do
      for n <- 0..4, do: Ets.append(config, "thr-1", :tool_call, n)

      assert {:ok, events} =
               Ets.list_by_kind(config, "thr-1", :tool_call, limit: 2)

      assert length(events) == 2
    end
  end

  describe "truncate" do
    test "removes events with sequence < before", %{config: config} do
      for n <- 0..9, do: Ets.append(config, "thr-1", :tool_call, n)

      assert :ok = Ets.truncate(config, "thr-1", 5)

      assert {:ok, events} = Ets.list(config, "thr-1")
      assert Enum.map(events, & &1.sequence) == [5, 6, 7, 8, 9]
    end

    test "is idempotent", %{config: config} do
      Ets.append(config, "thr-1", :tool_call, 0)
      :ok = Ets.truncate(config, "thr-1", 5)
      :ok = Ets.truncate(config, "thr-1", 5)

      assert {:ok, []} = Ets.list(config, "thr-1")
    end

    test "only affects the named thread", %{config: config} do
      for n <- 0..3, do: Ets.append(config, "thr-a", :tool_call, n)
      for n <- 0..3, do: Ets.append(config, "thr-b", :tool_call, n)

      :ok = Ets.truncate(config, "thr-a", 2)

      assert {:ok, a_events} = Ets.list(config, "thr-a")
      assert {:ok, b_events} = Ets.list(config, "thr-b")

      assert Enum.map(a_events, & &1.sequence) == [2, 3]
      assert Enum.map(b_events, & &1.sequence) == [0, 1, 2, 3]
    end
  end
end
