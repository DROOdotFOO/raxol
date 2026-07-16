defmodule Raxol.Agent.ContractTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.SessionStreamer

  setup do
    start_supervised!({SessionStreamer, []})
    :ok
  end

  defp mock_stream(response) do
    Raxol.Agent.Stream.run("prompt",
      backend: Raxol.Agent.Backend.Mock,
      backend_opts: [response: response]
    )
  end

  describe "pump/3" do
    test "maps a completed run onto the v0 vocabulary, in order" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      assert {:ok, %{content: content}} =
               Contract.pump(session_id, mock_stream("Hello!"), prompt: "hi")

      assert content =~ "Hello"

      events = drain_events(session_id)
      types = Enum.map(events, & &1.type)

      assert List.first(types) == :turn_started
      assert List.last(types) == :turn_completed
      assert :item_completed in types

      # the final turn_completed closes the run
      assert %Event{payload: %{final: true}} = List.last(events)

      # ids are monotonic from 1
      assert Enum.map(events, & &1.id) == Enum.to_list(1..length(events))

      # one turn: every event shares session and turn ids
      assert Enum.uniq(Enum.map(events, & &1.session_id)) == [session_id]
      assert [_turn_id] = Enum.uniq(Enum.map(events, & &1.turn_id))
    end

    test "text deltas are ephemeral; completed items are durable" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      {:ok, _} = Contract.pump(session_id, mock_stream("chunky"), prompt: "hi")

      events = drain_events(session_id)

      for %Event{type: :item_delta} = event <- events do
        assert event.tier == :ephemeral
      end

      for %Event{type: type} = event <- events, type != :item_delta do
        assert event.tier == :durable
      end
    end

    test "the done gate is consulted on the real done path: independent postdating evidence closes gated with refs" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      # A tool_use (mutation) followed by a tool_result of a DIFFERENT tool
      # name — an independent verification output that postdates the mutation
      # and is not its own echo. The gate accepts, so the final turn_completed
      # carries the evidence ref (offset 3: turn_started=1, tool_use=2, result=3).
      stream = [
        {:tool_use, %{name: "fs_write", arguments: %{path: "/x"}, id: "call-1"}},
        {:tool_result, %{name: "run_tests", result: "tests: 12 passed"}},
        {:done, %{content: "done", usage: %{output_tokens: 1}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "p")

      final = session_id |> drain_events() |> List.last()
      assert final.type == :turn_completed
      assert final.payload.final == true
      assert final.payload.refs == [3]
    end

    test "a mutation's own result echo is rejected: done closes fail-open with rejected_evidence telemetry" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      handler = "u21-rejected-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:raxol, :agent, :done_gate, :rejected_evidence],
        fn _e, _m, metadata, _c -> send(test_pid, {:rejected_evidence, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # The only tool_result postdating the mutation is that same call's echo
      # (same tool name) — the gate rejects it as :mutation_echo. Completion
      # stays fail-open: still final: true, no refs, plus telemetry.
      stream = [
        {:tool_use, %{name: "fs_write", arguments: %{}, id: "call-1"}},
        {:tool_result, %{name: "fs_write", result: "wrote"}},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "p")

      final = session_id |> drain_events() |> List.last()
      assert final.payload.final == true
      refute Map.has_key?(final.payload, :refs)

      assert_receive {:rejected_evidence, %{reason: {:mutation_echo, _}}}
    end

    test "a zero-tool turn closes ungated (parked policy) and emits done-gate telemetry" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      handler = "u21-ungated-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:raxol, :agent, :done_gate, :ungated_done],
        fn _e, _m, metadata, _c -> send(test_pid, {:ungated_done, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _} = Contract.pump(session_id, mock_stream("plain answer"), prompt: "hi")

      final = session_id |> drain_events() |> List.last()

      # Parked zero-tool policy preserved: still final: true, no refs attached.
      assert final.payload.final == true
      refute Map.has_key?(final.payload, :refs)

      assert_receive {:ungated_done, %{turn_id: turn_id}}
      assert is_binary(turn_id)
    end

    test "an error stream yields an :error event and error return" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      error_stream = [{:error, {:http, 500, "boom"}}]

      assert {:error, {:http, 500, "boom"}} =
               Contract.pump(session_id, error_stream, prompt: "hi")

      events = drain_events(session_id)
      assert Enum.any?(events, &(&1.type == :error))
    end
  end

  describe "encode_line/1" do
    test "produces one decodable JSON line per event" do
      event = %Event{
        id: 1,
        session_id: "s",
        turn_id: "t",
        ts: 123,
        type: :turn_started,
        payload: %{prompt: "hi"}
      }

      line = event |> Contract.encode_line() |> IO.iodata_to_binary()
      assert String.ends_with?(line, "\n")

      assert {:ok, decoded} = Jason.decode(String.trim_trailing(line))
      assert decoded["type"] == "turn_started"
      assert decoded["payload"]["prompt"] == "hi"
      assert decoded["tier"] == "durable"
    end

    test "sanitizes non-JSON payload terms instead of crashing" do
      event = %Event{
        id: 1,
        session_id: "s",
        turn_id: "t",
        ts: 123,
        type: :error,
        payload: %{reason: {:http, 500, {:nested, :tuple}}}
      }

      line = event |> Contract.encode_line() |> IO.iodata_to_binary()
      assert {:ok, decoded} = Jason.decode(String.trim_trailing(line))
      assert is_binary(decoded["payload"]["reason"])
      assert decoded["payload"]["reason"] =~ "http"
    end
  end

  defp drain_events(session_id, acc \\ []) do
    receive do
      {:session_event, ^session_id, %Event{} = event} ->
        drain_events(session_id, [event | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
