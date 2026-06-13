defmodule Raxol.Telegram.TelemetryTest do
  use ExUnit.Case, async: false

  alias Raxol.Telegram.{Bot, SessionRouter}

  setup do
    start_supervised!({SessionRouter, app_module: FakeApp, max_sessions: 1})

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:raxol_telegram, :bot, :received],
        [:raxol_telegram, :bot, :denied],
        [:raxol_telegram, :session, :rejected],
        [:raxol_telegram, :session, :started],
        [:raxol_telegram, :session, :stopped]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    :ok
  end

  describe "Bot events" do
    test "received fires for an allowed text message" do
      Bot.handle_update(%{message: %{text: "hi", chat: %{id: 42}}})

      assert_receive {[:raxol_telegram, :bot, :received], _ref, _,
                      %{chat_id: 42, kind: :message, byte_size: 2}}
    end

    test "denied fires when chat is not in allowed_chat_ids" do
      Bot.handle_update(%{message: %{text: "hi", chat: %{id: 42}}},
        allowed_chat_ids: [99]
      )

      assert_receive {[:raxol_telegram, :bot, :denied], _ref, _, %{chat_id: 42, kind: :message}}
    end

    test "received fires for an allowed callback query" do
      update = %{
        callback_query: %{
          id: "x",
          data: "key:q",
          message: %{chat: %{id: 7}}
        }
      }

      Bot.handle_update(update)

      assert_receive {[:raxol_telegram, :bot, :received], _ref, _,
                      %{chat_id: 7, kind: :callback, data: "key:q"}}
    end

    test "denied fires for non-list allowed_chat_ids (graceful denial)" do
      Bot.handle_update(%{message: %{text: "hi", chat: %{id: 42}}},
        allowed_chat_ids: "bad-config"
      )

      assert_receive {[:raxol_telegram, :bot, :denied], _ref, _, %{chat_id: 42}}
    end
  end

  describe "SessionRouter events" do
    test "rejected fires when max_sessions is reached" do
      # max_sessions is 1 from setup. First request hits do_start_session
      # (which will fail because FakeApp isn't a real TEA app), and no slot
      # is taken. To exercise :max_sessions_reached deterministically,
      # poke a fake session pid into the state map.
      :sys.replace_state(SessionRouter, fn state ->
        %{state | sessions: %{1 => self()}}
      end)

      assert {:error, :max_sessions_reached} = SessionRouter.start_session(2)

      assert_receive {[:raxol_telegram, :session, :rejected], _ref, _,
                      %{chat_id: 2, reason: :max_sessions_reached}}
    end

    test "rejected fires with reason :rate_limited" do
      now = System.monotonic_time(:millisecond)

      :sys.replace_state(SessionRouter, fn state ->
        %{state | last_start: %{99 => now}}
      end)

      assert {:error, :rate_limited} = SessionRouter.start_session(99)

      assert_receive {[:raxol_telegram, :session, :rejected], _ref, _,
                      %{chat_id: 99, reason: :rate_limited}}
    end

    test "stopped fires when stop_session removes a tracked session" do
      :sys.replace_state(SessionRouter, fn state ->
        %{state | sessions: Map.put(state.sessions, 33, self())}
      end)

      SessionRouter.stop_session(33)

      assert_receive {[:raxol_telegram, :session, :stopped], _ref, _,
                      %{chat_id: 33, reason: :explicit}}
    end
  end
end

defmodule FakeApp do
  @moduledoc false
end
