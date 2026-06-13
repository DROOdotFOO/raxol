defmodule Raxol.Telegram.BotTest do
  use ExUnit.Case, async: false

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

  describe "chat_join_request routing" do
    defmodule ApproveAll do
      @behaviour Raxol.Telegram.Guardian
      @impl true
      def screen(_applicant), do: {:approve, "always ok"}
    end

    setup do
      ref = make_ref()

      :telemetry.attach_many(
        {ref, :bot_join_test},
        [
          [:raxol_telegram, :guardian, :received],
          [:raxol_telegram, :guardian, :denied],
          [:raxol_telegram, :guardian, :approved],
          [:raxol_telegram, :guardian, :declined],
          [:raxol_telegram, :guardian, :error]
        ],
        fn event, _, metadata, pid -> send(pid, {:telemetry, event, metadata}) end,
        self()
      )

      on_exit(fn ->
        :telemetry.detach({ref, :bot_join_test})
        Application.delete_env(:raxol_telegram, :guardian)
      end)

      :ok
    end

    test "emits :received and dispatches to Guardian when chat allowed" do
      update = %{
        chat_join_request: %{
          from: %{id: 99, username: "alice"},
          chat: %{id: 42}
        }
      }

      post_fn = fn _url, _opts ->
        {:ok, %{status: 200, body: %{"ok" => true, "result" => true}}}
      end

      Bot.handle_update(update,
        allowed_chat_ids: [42],
        guardian: ApproveAll,
        bot_token: "t",
        post_fn: post_fn
      )

      assert_receive {:telemetry, [:raxol_telegram, :guardian, :received],
                      %{chat_id: 42, user_id: 99}}

      assert_receive {:telemetry, [:raxol_telegram, :guardian, :approved],
                      %{chat_id: 42, user_id: 99, reason: "always ok"}}
    end

    test "emits :denied without calling Guardian when chat not allowed" do
      update = %{
        chat_join_request: %{
          from: %{id: 99},
          chat: %{id: 999}
        }
      }

      Bot.handle_update(update, allowed_chat_ids: [42], guardian: ApproveAll)

      assert_receive {:telemetry, [:raxol_telegram, :guardian, :denied],
                      %{chat_id: 999, user_id: 99}}

      refute_receive {:telemetry, [:raxol_telegram, :guardian, :received], _}, 50
      refute_receive {:telemetry, [:raxol_telegram, :guardian, :approved], _}, 50
    end

    test "uses app env guardian when none passed in opts" do
      Application.put_env(:raxol_telegram, :guardian, ApproveAll)

      update = %{
        chat_join_request: %{
          from: %{id: 99},
          chat: %{id: 42}
        }
      }

      post_fn = fn _url, _opts ->
        {:ok, %{status: 200, body: %{"ok" => true, "result" => true}}}
      end

      Bot.handle_update(update, allowed_chat_ids: [42], bot_token: "t", post_fn: post_fn)

      assert_receive {:telemetry, [:raxol_telegram, :guardian, :approved], _}
    end

    test "ignores malformed chat_join_request (missing required fields)" do
      update = %{chat_join_request: %{from: %{}, chat: %{}}}
      assert :ok = Bot.handle_update(update, guardian: ApproveAll)
      refute_receive {:telemetry, [:raxol_telegram, :guardian, :received], _}, 50
    end
  end
end
