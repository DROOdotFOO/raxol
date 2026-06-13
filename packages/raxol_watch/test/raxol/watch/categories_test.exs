defmodule Raxol.Watch.CategoriesTest do
  use ExUnit.Case, async: true

  alias Raxol.Watch.Categories

  describe "ios_categories/0" do
    test "returns one entry per known category" do
      identifiers = Categories.ios_categories() |> Enum.map(& &1.identifier)
      assert Enum.sort(identifiers) == Enum.sort(Categories.known_categories())
    end

    test "every category carries actions, intent_identifiers, options" do
      for category <- Categories.ios_categories() do
        assert is_binary(category.identifier)
        assert is_list(category.actions)
        assert is_list(category.intent_identifiers)
        assert is_list(category.options)
      end
    end

    test "raxol_chat category includes a text-input reply action" do
      chat = find_category("raxol_chat")
      reply = Enum.find(chat.actions, &(&1.identifier == "reply"))

      assert reply.title == "Reply"
      assert :foreground in reply.options
      assert %{button_title: "Send", placeholder: "Reply..."} = reply.text_input
    end

    test "raxol_chat category includes mute, pin, delete, dismiss" do
      chat = find_category("raxol_chat")
      ids = Enum.map(chat.actions, & &1.identifier)

      assert "mute" in ids
      assert "pin" in ids
      assert "delete" in ids
      assert "dismiss" in ids
    end

    test "destructive actions carry the :destructive option flag" do
      chat = find_category("raxol_chat")
      delete = Enum.find(chat.actions, &(&1.identifier == "delete"))

      assert :destructive in delete.options
    end

    test "non-chat categories use the simple action shape (no text_input)" do
      for id <- ["raxol_alert", "raxol_status"] do
        category = find_category(id)

        for action <- category.actions do
          refute Map.has_key?(action, :text_input),
                 "expected #{id} action #{action.identifier} to have no text_input"
        end
      end
    end
  end

  describe "android_actions/0 and /1" do
    test "returns a map keyed by category identifier" do
      actions = Categories.android_actions()
      assert Map.keys(actions) |> Enum.sort() == Enum.sort(Categories.known_categories())
    end

    test "android_actions/1 returns the per-category list" do
      assert is_list(Categories.android_actions("raxol_chat"))
      assert is_list(Categories.android_actions("raxol_alert"))
    end

    test "android_actions/1 returns nil for unknown category" do
      assert Categories.android_actions("nope") == nil
    end

    test "every action carries an id and title" do
      for {_category, actions} <- Categories.android_actions() do
        for action <- actions do
          assert is_binary(action.id)
          assert is_binary(action.title)
        end
      end
    end

    test "chat reply action carries remote_input data for Android RemoteInput" do
      reply = Categories.android_actions("raxol_chat") |> Enum.find(&(&1.id == "reply"))

      assert %{label: "Reply...", choices: []} = reply.remote_input
    end

    test "non-reply chat actions have no remote_input" do
      chat = Categories.android_actions("raxol_chat")
      non_reply = Enum.reject(chat, &(&1.id == "reply"))

      for action <- non_reply do
        refute Map.has_key?(action, :remote_input)
      end
    end
  end

  describe "known_categories/0" do
    test "lists the three documented categories" do
      assert Enum.sort(Categories.known_categories()) ==
               ["raxol_alert", "raxol_chat", "raxol_status"]
    end
  end

  defp find_category(id) do
    Enum.find(Categories.ios_categories(), &(&1.identifier == id)) ||
      raise "category #{id} not found"
  end
end
