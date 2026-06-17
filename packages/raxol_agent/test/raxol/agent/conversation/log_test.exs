defmodule Raxol.Agent.Conversation.LogTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Conversation.Log
  alias Raxol.Agent.Conversation.Store.ETS

  setup do
    table = :"log_items_#{System.unique_integer([:positive])}"
    log = start_supervised!({Log, store: {ETS, %{table: table}}})
    %{log: log, conv: "conv-#{System.unique_integer([:positive])}"}
  end

  describe "append + subscribe" do
    test "a subscriber receives items appended after it subscribes", %{log: log, conv: conv} do
      {:ok, %{snapshot: [], last_seq: nil}} = Log.subscribe(log, conv)
      {:ok, [item]} = Log.append(log, conv, %{type: :message, data: %{n: 1}})

      assert_receive {:conversation_item, ^conv, ^item}
    end

    test "append accepts a single item map or a list", %{log: log, conv: conv} do
      assert {:ok, [_]} = Log.append(log, conv, %{type: :message})
      assert {:ok, [_, _]} = Log.append(log, conv, [%{type: :message}, %{type: :reasoning}])
    end
  end

  describe "exact snapshot/live-tail partition" do
    test "subscribing between appends never gaps or duplicates", %{log: log, conv: conv} do
      {:ok, [_item0]} = Log.append(log, conv, %{type: :message, data: %{n: 0}})

      {:ok, %{snapshot: snapshot, last_seq: last_seq}} = Log.subscribe(log, conv)
      assert Enum.map(snapshot, & &1.seq) == [0]
      assert last_seq == 0

      {:ok, [item1]} = Log.append(log, conv, %{type: :message, data: %{n: 1}})

      # The post-subscribe item arrives live...
      assert_receive {:conversation_item, ^conv, ^item1}
      # ...and the pre-subscribe item (already in the snapshot) is NOT re-sent.
      refute_received {:conversation_item, ^conv, %{seq: 0}}
    end

    test "reconnect with :after only snapshots items past the cursor", %{log: log, conv: conv} do
      {:ok, _} = Log.append(log, conv, [%{type: :message}, %{type: :message}, %{type: :message}])

      {:ok, %{snapshot: snapshot, last_seq: last_seq}} = Log.subscribe(log, conv, after: 0)
      assert Enum.map(snapshot, & &1.seq) == [1, 2]
      assert last_seq == 2
    end
  end

  describe "multiple subscribers" do
    test "every subscriber receives each appended item", %{log: log, conv: conv} do
      parent = self()

      other =
        spawn_link(fn ->
          {:ok, _} = Log.subscribe(log, conv)
          send(parent, :ready)

          receive do
            {:conversation_item, ^conv, item} -> send(parent, {:other_got, item.seq})
          end
        end)

      assert_receive :ready
      {:ok, %{}} = Log.subscribe(log, conv)

      {:ok, [item]} = Log.append(log, conv, %{type: :message})
      assert_receive {:conversation_item, ^conv, ^item}
      assert_receive {:other_got, 0}

      Process.exit(other, :normal)
    end
  end

  describe "subscriber lifecycle" do
    test "unsubscribe stops live delivery", %{log: log, conv: conv} do
      {:ok, _} = Log.subscribe(log, conv)
      :ok = Log.unsubscribe(log, conv)

      {:ok, _} = Log.append(log, conv, %{type: :message})
      refute_receive {:conversation_item, ^conv, _}
    end

    test "a dead subscriber is dropped without breaking the log", %{log: log, conv: conv} do
      parent = self()

      doomed =
        spawn(fn ->
          {:ok, _} = Log.subscribe(log, conv)
          send(parent, :subscribed)
          Process.sleep(:infinity)
        end)

      assert_receive :subscribed
      ref = Process.monitor(doomed)
      Process.exit(doomed, :kill)
      assert_receive {:DOWN, ^ref, :process, ^doomed, _}

      # A live subscriber still works after the dead one is cleaned up.
      {:ok, _} = Log.subscribe(log, conv)
      {:ok, [item]} = Log.append(log, conv, %{type: :message})
      assert_receive {:conversation_item, ^conv, ^item}
      assert Process.alive?(log)
    end
  end

  describe "queries" do
    test "items/3 pages through stored history", %{log: log, conv: conv} do
      {:ok, _} = Log.append(log, conv, [%{type: :message}, %{type: :tool_call}])
      {:ok, items} = Log.items(log, conv, type: :message)
      assert Enum.map(items, & &1.type) == [:message]
    end

    test "get_conversation and list_conversations", %{log: log, conv: conv} do
      {:ok, _} = Log.append(log, conv, %{type: :message})
      assert {:ok, %{id: ^conv, item_count: 1}} = Log.get_conversation(log, conv)
      assert {:ok, ids} = Log.list_conversations(log)
      assert conv in ids
    end
  end
end
