defmodule Raxol.Agent.Conversation.ItemTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Conversation.Item

  describe "id/2" do
    test "derives a stable id from conversation id and sequence" do
      assert Item.id("conv-1", 0) == "conv-1:0"
      assert Item.id("conv-1", 42) == "conv-1:42"
    end
  end

  describe "new/1" do
    test "builds an item with a derived id and defaults" do
      item = Item.new(conversation_id: "c", seq: 3, type: :message)

      assert item.id == "c:3"
      assert item.conversation_id == "c"
      assert item.seq == 3
      assert item.type == :message
      assert item.status == :completed
      assert item.data == %{}
      assert item.response_id == nil
      assert %DateTime{} = item.created_at
    end

    test "accepts explicit status, data, response_id, and created_by" do
      item =
        Item.new(
          conversation_id: "c",
          seq: 0,
          type: :tool_call,
          status: :action_required,
          data: %{name: "x"},
          response_id: "r1",
          created_by: :assistant
        )

      assert item.status == :action_required
      assert item.data == %{name: "x"}
      assert item.response_id == "r1"
      assert item.created_by == :assistant
    end

    test "requires conversation_id, seq, and type" do
      assert_raise KeyError, fn -> Item.new(seq: 0, type: :message) end
      assert_raise KeyError, fn -> Item.new(conversation_id: "c", type: :message) end
      assert_raise KeyError, fn -> Item.new(conversation_id: "c", seq: 0) end
    end
  end
end
