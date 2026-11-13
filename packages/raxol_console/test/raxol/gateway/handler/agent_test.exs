defmodule Raxol.Gateway.Handler.AgentTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Gateway.Handler
  alias Raxol.Gateway.Route

  @route Route.new(%{platform: :in_memory, chat_type: :dm, chat_id: "1"})

  defp init!(opts) do
    {:ok, state} = Handler.Agent.init(@route, opts)
    state
  end

  defp mock_opts(backend_opts) do
    [
      agent_opts: [
        backend: Raxol.Agent.Backend.Mock,
        backend_opts: backend_opts
      ]
    ]
  end

  # Tests that leave auto_provider on inject :resolve_probe so init never
  # touches real credential resolution (which may shell out to op).
  defp resolved_probe, do: [resolve_probe: fn _opts -> :resolved end]

  # Deterministic clock: the test owns time via an :atomics cell.
  defp throttled_state(clock, backend_opts, throttle_opts) do
    opts =
      mock_opts(backend_opts) ++
        [now_fn: fn -> :atomics.get(clock, 1) end] ++ throttle_opts

    init!(opts)
  end

  describe "init/2" do
    test "defaults: empty history, max_history 40, no system prompt" do
      state = init!(resolved_probe())

      assert state.messages == []
      assert state.max_history == 40
      assert state.system_prompt == nil
    end

    test "adds auto_provider: true when no backend or executor is pinned" do
      state =
        init!(Keyword.put(resolved_probe(), :agent_opts, model: "some-model"))

      assert Keyword.get(state.agent_opts, :auto_provider) == true
    end

    test "warns when auto_provider resolves nothing (Mock fallback is loud)" do
      log =
        capture_log(fn ->
          init!(resolve_probe: fn _opts -> nil end)
        end)

      assert log =~ "no agent provider resolved"
      assert log =~ "Mock backend"
    end

    test "does not warn when a provider resolves" do
      log = capture_log(fn -> init!(resolved_probe()) end)

      refute log =~ "no agent provider resolved"
    end

    test "does not probe at all when a backend is pinned" do
      state =
        init!(
          Keyword.put(mock_opts(response: "x"), :resolve_probe, fn _opts ->
            flunk("probe must not run for a pinned backend")
          end)
        )

      refute Keyword.has_key?(state.agent_opts, :auto_provider)
    end

    test "does not add auto_provider when a backend is pinned" do
      state = init!(mock_opts(response: "x"))

      refute Keyword.has_key?(state.agent_opts, :auto_provider)
    end

    test "does not add auto_provider when an executor is pinned" do
      state = init!(agent_opts: [executor: :fake_executor])

      refute Keyword.has_key?(state.agent_opts, :auto_provider)
    end
  end

  describe "handle_event/2 with text" do
    test "replies with the agent's answer and records both turns" do
      state = init!(mock_opts(response: "pong"))

      assert {:reply, "pong", state} =
               Handler.Agent.handle_event(%{text: "ping"}, state)

      assert state.messages == [
               %{role: :user, content: "ping"},
               %{role: :assistant, content: "pong"}
             ]
    end

    test "multi-turn: history accumulates in order" do
      counter = :counters.new(1, [])

      response_fn = fn ->
        :counters.add(counter, 1, 1)
        "answer-#{:counters.get(counter, 1)}"
      end

      state = init!(mock_opts(response_fn: response_fn))

      {:reply, "answer-1", state} =
        Handler.Agent.handle_event(%{text: "one"}, state)

      {:reply, "answer-2", state} =
        Handler.Agent.handle_event(%{text: "two"}, state)

      assert state.messages == [
               %{role: :user, content: "one"},
               %{role: :assistant, content: "answer-1"},
               %{role: :user, content: "two"},
               %{role: :assistant, content: "answer-2"}
             ]
    end

    test "caps history at max_history, dropping the oldest" do
      state = init!(Keyword.put(mock_opts(response: "r"), :max_history, 4))

      state =
        Enum.reduce(1..3, state, fn n, acc ->
          {:reply, "r", acc} =
            Handler.Agent.handle_event(%{text: "msg-#{n}"}, acc)

          acc
        end)

      assert length(state.messages) == 4

      assert state.messages == [
               %{role: :user, content: "msg-2"},
               %{role: :assistant, content: "r"},
               %{role: :user, content: "msg-3"},
               %{role: :assistant, content: "r"}
             ]
    end

    test "a raising backend is converted to the error reply, not a crash" do
      state = init!(mock_opts(response_fn: fn -> raise "backend exploded" end))

      log =
        capture_log(fn ->
          assert {:reply, reply, state} =
                   Handler.Agent.handle_event(%{text: "hi"}, state)

          assert reply =~ "Agent error"
          assert state.messages == [%{role: :user, content: "hi"}]
        end)

      assert log =~ "backend exploded"
    end

    test "history trim never leaves a leading assistant message" do
      # max_history 2: after the second turn a naive tail-trim would keep
      # [assistant, user]; the trim must drop the leading assistant.
      state = init!(Keyword.put(mock_opts(response: "r"), :max_history, 2))

      {:reply, "r", state} = Handler.Agent.handle_event(%{text: "one"}, state)
      {:reply, "r", state} = Handler.Agent.handle_event(%{text: "two"}, state)

      assert [%{role: :user} | _rest] = state.messages

      assert state.messages == [
               %{role: :user, content: "two"},
               %{role: :assistant, content: "r"}
             ]
    end

    test "backend error replies with a short message and keeps the user turn" do
      state = init!(mock_opts(error: :boom))

      log =
        capture_log(fn ->
          assert {:reply, reply, state} =
                   Handler.Agent.handle_event(%{text: "hi"}, state)

          assert reply =~ "Agent error"
          assert state.messages == [%{role: :user, content: "hi"}]
        end)

      assert log =~ "boom"
    end
  end

  describe "per-chat turn throttle" do
    test "no throttle by default" do
      state = init!(mock_opts(response: "r"))
      assert state.throttle == nil
    end

    test "denies over-cap turns without a backend call or history writes" do
      clock = :atomics.new(1, [])
      calls = :counters.new(1, [])

      response_fn = fn ->
        :counters.add(calls, 1, 1)
        "ok"
      end

      state =
        throttled_state(clock, [response_fn: response_fn],
          max_turns_per_window: 2,
          window_ms: 1_000
        )

      {:reply, "ok", state} = Handler.Agent.handle_event(%{text: "one"}, state)
      {:reply, "ok", state} = Handler.Agent.handle_event(%{text: "two"}, state)

      assert {:reply, denied, denied_state} =
               Handler.Agent.handle_event(%{text: "three"}, state)

      assert denied =~ "Rate limited"
      assert :counters.get(calls, 1) == 2
      assert denied_state.messages == state.messages
    end

    test "a new window resets the counter" do
      clock = :atomics.new(1, [])

      state =
        throttled_state(clock, [response: "ok"],
          max_turns_per_window: 1,
          window_ms: 1_000
        )

      {:reply, "ok", state} = Handler.Agent.handle_event(%{text: "one"}, state)

      {:reply, denied, state} =
        Handler.Agent.handle_event(%{text: "two"}, state)

      assert denied =~ "Rate limited"

      :atomics.put(clock, 1, 1_000)

      assert {:reply, "ok", _state} =
               Handler.Agent.handle_event(%{text: "three"}, state)
    end

    test "a failed backend turn still counts against the window" do
      clock = :atomics.new(1, [])

      state =
        throttled_state(clock, [error: :boom],
          max_turns_per_window: 1,
          window_ms: 1_000
        )

      capture_log(fn ->
        {:reply, first, state} =
          Handler.Agent.handle_event(%{text: "one"}, state)

        assert first =~ "Agent error"

        {:reply, denied, _state} =
          Handler.Agent.handle_event(%{text: "two"}, state)

        assert denied =~ "Rate limited"
      end)
    end
  end

  describe "handle_event/2 with non-text events" do
    test "ignores events without usable text" do
      state = init!(mock_opts(response: "never"))

      for event <- [%{text: ""}, %{text: nil}, %{}, {:say, "x"}, :ping, "raw"] do
        assert {:noreply, ^state} = Handler.Agent.handle_event(event, state)
      end
    end
  end
end
