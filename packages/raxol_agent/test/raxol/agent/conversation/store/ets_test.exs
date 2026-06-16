defmodule Raxol.Agent.Conversation.Store.ETSTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Conversation.Store.ETS

  setup do
    %{config: %{table: :"items_#{System.unique_integer([:positive])}"}}
  end

  describe "append/3" do
    test "assigns monotonic 0-based sequences and stable ids", %{config: config} do
      {:ok, items} =
        ETS.append(config, "c", [
          %{type: :message, data: %{n: 1}},
          %{type: :tool_call, data: %{n: 2}}
        ])

      assert Enum.map(items, & &1.seq) == [0, 1]
      assert Enum.map(items, & &1.id) == ["c:0", "c:1"]
      assert Enum.map(items, & &1.type) == [:message, :tool_call]
    end

    test "continues the sequence across append calls", %{config: config} do
      {:ok, [a]} = ETS.append(config, "c", [%{type: :message}])
      {:ok, [b]} = ETS.append(config, "c", [%{type: :message}])
      assert a.seq == 0
      assert b.seq == 1
    end

    test "sequences are independent per conversation", %{config: config} do
      {:ok, [a]} = ETS.append(config, "c1", [%{type: :message}])
      {:ok, [b]} = ETS.append(config, "c2", [%{type: :message}])
      assert a.seq == 0
      assert b.seq == 0
    end
  end

  describe "list_items/3" do
    setup %{config: config} do
      {:ok, _} =
        ETS.append(config, "c", [
          %{type: :message, data: %{n: 0}},
          %{type: :tool_call, data: %{n: 1}},
          %{type: :message, data: %{n: 2}}
        ])

      :ok
    end

    test "returns items in sequence order", %{config: config} do
      {:ok, items} = ETS.list_items(config, "c")
      assert Enum.map(items, & &1.seq) == [0, 1, 2]
    end

    test ":after is an exclusive cursor", %{config: config} do
      {:ok, items} = ETS.list_items(config, "c", after: 0)
      assert Enum.map(items, & &1.seq) == [1, 2]
    end

    test ":before is exclusive", %{config: config} do
      {:ok, items} = ETS.list_items(config, "c", before: 2)
      assert Enum.map(items, & &1.seq) == [0, 1]
    end

    test ":type filters by item type", %{config: config} do
      {:ok, items} = ETS.list_items(config, "c", type: :message)
      assert Enum.map(items, & &1.seq) == [0, 2]
    end

    test ":limit caps the result", %{config: config} do
      {:ok, items} = ETS.list_items(config, "c", limit: 2)
      assert Enum.map(items, & &1.seq) == [0, 1]
    end

    test ":order :desc reverses", %{config: config} do
      {:ok, items} = ETS.list_items(config, "c", order: :desc)
      assert Enum.map(items, & &1.seq) == [2, 1, 0]
    end

    test "an unknown conversation yields an empty list", %{config: config} do
      assert {:ok, []} = ETS.list_items(config, "nope")
    end
  end

  describe "get_conversation/2 and list_conversations/1" do
    test "reports last_seq and item_count", %{config: config} do
      {:ok, _} = ETS.append(config, "c", [%{type: :message}, %{type: :message}])
      assert {:ok, %{id: "c", last_seq: 1, item_count: 2}} = ETS.get_conversation(config, "c")
    end

    test "returns :not_found for an unknown conversation", %{config: config} do
      assert {:error, :not_found} = ETS.get_conversation(config, "nope")
    end

    test "lists known conversation ids", %{config: config} do
      {:ok, _} = ETS.append(config, "c1", [%{type: :message}])
      {:ok, _} = ETS.append(config, "c2", [%{type: :message}])
      {:ok, ids} = ETS.list_conversations(config)
      assert Enum.sort(ids) == ["c1", "c2"]
    end
  end
end
