defmodule Raxol.Telegram.SessionRouterTest do
  use ExUnit.Case

  alias Raxol.Telegram.SessionRouter

  # SessionRouter requires a running GenServer. These tests verify
  # the public API works correctly with a mock app module.

  setup do
    # Start a fresh SessionRouter for each test
    start_supervised!({SessionRouter, app_module: FakeApp})
    :ok
  end

  describe "session_count/0" do
    test "starts with zero sessions" do
      assert SessionRouter.session_count() == 0
    end
  end

  describe "get_session/1" do
    test "returns nil for unknown chat_id" do
      assert SessionRouter.get_session(999) == nil
    end
  end

  describe "stop_session/1" do
    test "stopping non-existent session is a no-op" do
      assert SessionRouter.stop_session(999) == :ok
    end
  end

  describe "cooldown map (memory safety)" do
    test "stats/0 exposes the cooldown map size" do
      assert %{sessions: 0, last_start_entries: 0} = SessionRouter.stats()
    end

    test "purge_stale_cooldowns/0 drops entries older than the cooldown window" do
      cooldown_ms = 5_000
      now = System.monotonic_time(:millisecond)

      stale_entries =
        for i <- 1..50, into: %{}, do: {i, now - cooldown_ms - 1_000}

      fresh_entries =
        for i <- 100..103, into: %{}, do: {i, now}

      :sys.replace_state(SessionRouter, fn state ->
        %{state | last_start: Map.merge(stale_entries, fresh_entries)}
      end)

      assert %{last_start_entries: 54} = SessionRouter.stats()

      dropped = SessionRouter.purge_stale_cooldowns()
      assert dropped == 50

      assert %{last_start_entries: 4} = SessionRouter.stats()
    end

    test "purge_stale_cooldowns/0 returns 0 when nothing to drop" do
      assert SessionRouter.purge_stale_cooldowns() == 0
    end
  end
end

defmodule FakeApp do
  @moduledoc false
  # Minimal module to satisfy app_module requirement
end
