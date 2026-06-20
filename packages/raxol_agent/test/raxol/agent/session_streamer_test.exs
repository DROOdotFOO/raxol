defmodule Raxol.Agent.SessionStreamerTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.SessionStreamer

  setup do
    {:ok, streamer} = SessionStreamer.start_link(name: nil, max_history: 10)
    %{streamer: streamer}
  end

  describe "subscribe/unsubscribe" do
    test "receives events after subscribing", %{streamer: streamer} do
      SessionStreamer.subscribe(:agent_1, streamer)
      SessionStreamer.emit(:agent_1, {:text_delta, "hello"}, streamer)

      assert_receive {:session_event, :agent_1, {:text_delta, "hello"}}
    end

    test "does not receive events after unsubscribing", %{streamer: streamer} do
      SessionStreamer.subscribe(:agent_1, streamer)
      SessionStreamer.unsubscribe(:agent_1, streamer)

      SessionStreamer.emit(:agent_1, {:text_delta, "hello"}, streamer)

      refute_receive {:session_event, :agent_1, _}, 100
    end

    test "multiple subscribers receive the same event", %{streamer: streamer} do
      parent = self()

      pids =
        for i <- 1..3 do
          spawn_link(fn ->
            SessionStreamer.subscribe(:agent_1, streamer)
            send(parent, {:subscribed, i})

            receive do
              {:session_event, :agent_1, event} -> send(parent, {:got, i, event})
            end
          end)
        end

      # Wait for all to subscribe
      for i <- 1..3 do
        assert_receive {:subscribed, ^i}
      end

      SessionStreamer.emit(:agent_1, {:done, %{content: "hi"}}, streamer)

      for i <- 1..3 do
        assert_receive {:got, ^i, {:done, %{content: "hi"}}}
      end

      # Clean up spawned processes
      Enum.each(pids, fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)
    end

    test "events from different sessions are isolated", %{streamer: streamer} do
      SessionStreamer.subscribe(:agent_1, streamer)

      SessionStreamer.emit(:agent_2, {:text_delta, "wrong"}, streamer)
      SessionStreamer.emit(:agent_1, {:text_delta, "right"}, streamer)

      assert_receive {:session_event, :agent_1, {:text_delta, "right"}}
      refute_receive {:session_event, :agent_2, _}, 100
    end
  end

  describe "emit/3" do
    test "broadcasts various event types", %{streamer: streamer} do
      SessionStreamer.subscribe(:agent_1, streamer)

      events = [
        {:text_delta, "chunk"},
        {:tool_use, %{name: "read_file", arguments: %{}, id: "t1"}},
        {:tool_result, %{name: "read_file", result: %{content: "data"}}},
        {:state_change, %{from: :thinking, to: :acting}},
        {:turn_complete, %{iteration: 0}},
        {:done, %{content: "done"}},
        {:error, :timeout}
      ]

      Enum.each(events, fn event ->
        SessionStreamer.emit(:agent_1, event, streamer)
      end)

      for event <- events do
        assert_receive {:session_event, :agent_1, ^event}
      end
    end
  end

  describe "history/2" do
    test "returns empty list for unknown session", %{streamer: streamer} do
      assert SessionStreamer.history(:unknown, streamer) == []
    end

    test "returns emitted events in order", %{streamer: streamer} do
      SessionStreamer.emit(:agent_1, {:text_delta, "a"}, streamer)
      SessionStreamer.emit(:agent_1, {:text_delta, "b"}, streamer)
      SessionStreamer.emit(:agent_1, {:done, %{}}, streamer)

      # Give casts time to process
      Process.sleep(50)

      history = SessionStreamer.history(:agent_1, streamer)
      assert length(history) == 3
      assert Enum.at(history, 0) == {:text_delta, "a"}
      assert Enum.at(history, 1) == {:text_delta, "b"}
      assert Enum.at(history, 2) == {:done, %{}}
    end

    test "caps at max_history", %{streamer: streamer} do
      for i <- 1..15 do
        SessionStreamer.emit(:agent_1, {:text_delta, "msg#{i}"}, streamer)
      end

      Process.sleep(50)

      history = SessionStreamer.history(:agent_1, streamer)
      # max_history is 10 in setup
      assert length(history) == 10
      # Should have the 10 most recent (6..15)
      assert {:text_delta, "msg6"} = Enum.at(history, 0)
      assert {:text_delta, "msg15"} = Enum.at(history, 9)
    end
  end

  describe "list_sessions/1" do
    test "returns empty when no subscribers", %{streamer: streamer} do
      assert SessionStreamer.list_sessions(streamer) == []
    end

    test "returns sessions with active subscribers", %{streamer: streamer} do
      SessionStreamer.subscribe(:agent_1, streamer)
      SessionStreamer.subscribe(:agent_2, streamer)

      sessions = SessionStreamer.list_sessions(streamer)
      assert :agent_1 in sessions
      assert :agent_2 in sessions
    end
  end

  describe "process monitoring" do
    test "cleans up subscriptions when subscriber dies", %{streamer: streamer} do
      parent = self()

      pid =
        spawn(fn ->
          SessionStreamer.subscribe(:agent_1, streamer)
          send(parent, :subscribed)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :subscribed

      sessions = SessionStreamer.list_sessions(streamer)
      assert :agent_1 in sessions

      # Kill the subscriber
      Process.exit(pid, :kill)
      Process.sleep(50)

      # After cleanup, should be empty (MapSet empty but key remains)
      sessions = SessionStreamer.list_sessions(streamer)
      refute :agent_1 in sessions
    end
  end

  describe "cross-surface consistency" do
    test "every subscriber observes the identical ordered sequence", %{streamer: streamer} do
      parent = self()

      sequence = [
        {:text_delta, "thinking"},
        {:tool_use, %{name: "search", arguments: %{}, id: "t1"}},
        {:tool_result, %{name: "search", result: %{hits: 2}}},
        {:state_change, %{from: :thinking, to: :acting}},
        {:done, %{content: "answer"}}
      ]

      # Stand-ins for the surfaces that observe one agent: an SSE consumer, a
      # watch-style consumer, and an MCP consumer.
      surfaces = [:sse, :watch, :mcp]

      collectors =
        for surface <- surfaces do
          spawn_link(fn ->
            SessionStreamer.subscribe(:agent_x, streamer)
            send(parent, {:ready, surface})
            collected = collect_events(:agent_x, length(sequence), [])
            send(parent, {:collected, surface, collected})
          end)
        end

      for surface <- surfaces, do: assert_receive({:ready, ^surface})

      Enum.each(sequence, fn event ->
        SessionStreamer.emit(:agent_x, event, streamer)
      end)

      # Each surface receives the same events, in the same order, with none
      # dropped or reordered.
      for surface <- surfaces do
        assert_receive {:collected, ^surface, ^sequence}, 1_000
      end

      Enum.each(collectors, fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)
    end
  end

  defp collect_events(_session, 0, acc), do: Enum.reverse(acc)

  defp collect_events(session, remaining, acc) do
    receive do
      {:session_event, ^session, event} ->
        collect_events(session, remaining - 1, [event | acc])
    after
      1_000 -> Enum.reverse(acc)
    end
  end
end
