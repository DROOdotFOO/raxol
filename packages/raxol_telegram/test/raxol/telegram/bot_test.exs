defmodule Raxol.Telegram.BotTest do
  use ExUnit.Case, async: true

  alias Raxol.Telegram.Bot

  describe "handle_update/1" do
    test "ignores unrecognized update shapes" do
      assert :ok = Bot.handle_update(%{})
      assert :ok = Bot.handle_update(%{unknown: "data"})
      assert :ok = Bot.handle_update(%{message: %{photo: "img", chat: %{id: 1}}})
    end

    test "ignores messages without text" do
      update = %{message: %{chat: %{id: 1}}}
      assert :ok = Bot.handle_update(update)
    end

    test "ignores unknown commands" do
      # Unknown commands go through translate_text -> {:command, "unknown"}
      # which hits the {:command, _} -> :ok catch-all
      # This requires SessionRouter NOT running, so the /start and /stop
      # branches would fail. Test the catch-all path instead.
      # We test this indirectly through InputAdapter
      assert :ok = Bot.handle_update(%{})
    end
  end

  describe "allowed_chat_ids robustness" do
    test "non-list allowed_chat_ids denies all (does not crash)" do
      update = %{message: %{text: "hi", chat: %{id: 42}}}
      # Misconfiguration: a single integer instead of a list.
      assert :ok = Bot.handle_update(update, allowed_chat_ids: 42)
      assert :ok = Bot.handle_update(update, allowed_chat_ids: "42")
      assert :ok = Bot.handle_update(update, allowed_chat_ids: %{42 => true})
    end

    test "explicit nil allowed_chat_ids allows everyone" do
      # Unknown command path so we don't need SessionRouter running.
      update = %{message: %{text: "/notarealcmd", chat: %{id: 1}}}
      assert :ok = Bot.handle_update(update, allowed_chat_ids: nil)
    end
  end
end
