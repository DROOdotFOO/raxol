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
      # carries the evidence ref (offset 5: turn_started=1, the tool_use's
      # item_started=2 / item_completed=3, the tool_result's item_started=4 /
      # item_completed=5).
      stream = [
        {:tool_use,
         %{name: "fs_write", arguments: %{path: "/x"}, id: "call-1"}},
        {:tool_result, %{name: "run_tests", result: "tests: 12 passed"}},
        {:done, %{content: "done", usage: %{output_tokens: 1}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "p")

      final = session_id |> drain_events() |> List.last()
      assert final.type == :turn_completed
      assert final.payload.final == true
      assert final.payload.refs == [5]
    end

    test "a mutation's own result echo is rejected: done closes fail-open with rejected_evidence telemetry" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      handler = "u21-rejected-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:raxol, :agent, :done_gate, :rejected_evidence],
        fn _e, _m, metadata, _c ->
          send(test_pid, {:rejected_evidence, metadata})
        end,
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
        fn _e, _m, metadata, _c ->
          send(test_pid, {:ungated_done, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _} =
        Contract.pump(session_id, mock_stream("plain answer"), prompt: "hi")

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

  describe "streaming item lifecycle (item_started + item_id)" do
    # RED-FIRST (live-session defect: streaming output not rendering
    # incrementally). The projection's live tail
    # (`Raxol.Harness.Projection.BlockBuilder.build_tail/2`) only
    # surfaces `item_delta` chunks for an item that has an
    # `item_started` group and an `item_id` -- the fixture corpus
    # always carries both, but pump/3 emitted neither, so a REAL
    # session's streamed answer never entered the tail and only
    # appeared all-at-once at `item_completed`. These tests pin the
    # producer to the same wire shape the fixtures (and the projection)
    # already speak.

    test "a streamed message opens with item_started and every delta carries its item_id" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:text_delta, "Hel"},
        {:text_delta, "lo!"},
        {:done, %{content: "Hello!", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "hi")

      events = drain_events(session_id)

      started =
        Enum.find(events, &(&1.type == :item_started))

      assert started != nil, "pump must emit item_started before the first delta"
      assert started.tier == :durable
      assert %{item_id: item_id, item_type: :message} = started.payload
      assert is_binary(item_id) and item_id != ""

      deltas = Enum.filter(events, &(&1.type == :item_delta))
      assert length(deltas) == 2

      for delta <- deltas do
        assert delta.payload.item_id == item_id
      end

      # item_started precedes the first delta in emit order.
      first_delta = List.first(deltas)
      assert started.id < first_delta.id

      # The message's item_completed closes the SAME item.
      completed =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :message)
        )

      assert completed.payload.item_id == item_id
      assert completed.payload.content == "Hello!"
    end

    test "tool_use and tool_result complete as DISTINCT items, each with a started sibling" do
      # Without distinct item_ids every item_completed shares the same
      # (nil) id, so the projection folds them into ONE group and drops
      # the tool_result completion as a duplicate -- a live multi-item
      # turn silently loses blocks the fixture path renders.
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "list_dir", arguments: %{path: "."}, id: "call-1"}},
        {:tool_result, %{name: "list_dir", result: "mix.exs"}},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "p")

      events = drain_events(session_id)

      completed_ids =
        for %Event{type: :item_completed, payload: payload} <- events do
          assert is_binary(payload.item_id) and payload.item_id != ""
          payload.item_id
        end

      # tool_use, tool_result, and the done message: three distinct items.
      assert length(completed_ids) == 3
      assert length(Enum.uniq(completed_ids)) == 3

      started_ids =
        for %Event{type: :item_started, payload: payload} <- events,
            do: payload.item_id

      # Every completed item has a started sibling with the same id.
      assert Enum.sort(started_ids) == Enum.sort(completed_ids)
    end

    test "a message item open when a tool_use arrives seals with its accumulated text" do
      # The pre-tool text run is a real assistant message: it must seal
      # as its own item (ordered BEFORE the tool items) rather than
      # leak into the final answer's item or vanish.
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:text_delta, "let me check"},
        {:tool_use, %{name: "list_dir", arguments: %{}, id: "call-1"}},
        {:tool_result, %{name: "list_dir", result: "mix.exs"}},
        {:done, %{content: "final answer", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "p")

      events = drain_events(session_id)

      messages =
        for %Event{type: :item_completed, payload: %{item_type: :message} = p} <-
              events,
            do: p

      assert Enum.map(messages, & &1.content) == [
               "let me check",
               "final answer"
             ]
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

  describe "pump/3 — tool-execution vocabulary (ToolExecutor events)" do
    test "approval events sequence into the run's id stream between tool_use and result" do
      session_id = "contract-appr-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "edit_file", arguments: %{}, id: "e1"}},
        {:approval_requested,
         %{request_id: "r1", tool_name: "edit_file", options: []}},
        {:approval_decided,
         %{request_id: "r1", option_id: "allow", decision: :allow}},
        {:tool_result, %{name: "edit_file", result: %{ok: true}}},
        {:done, %{content: "done", usage: %{}}}
      ]

      {:ok, _} = Contract.pump(session_id, stream, prompt: "p")
      events = drain_events(session_id)
      types = Enum.map(events, & &1.type)

      assert :approval_requested in types
      assert :approval_decided in types

      req_i = Enum.find_index(types, &(&1 == :approval_requested))
      dec_i = Enum.find_index(types, &(&1 == :approval_decided))
      assert req_i < dec_i

      # ids are strictly monotonic across the whole run (single id source).
      ids = Enum.map(events, & &1.id)
      assert ids == Enum.sort(ids)
      assert ids == Enum.uniq(ids)
    end

    test "a diff-shaped tool_result flattens path/old/new + a diff marker onto the payload" do
      session_id = "contract-diff-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_result,
         %{
           name: "edit_file",
           result: %{path: "a.ex", old: "x", new: "y", language: "elixir"}
         }},
        {:done, %{content: "done", usage: %{}}}
      ]

      {:ok, _} = Contract.pump(session_id, stream, prompt: "p")
      events = drain_events(session_id)

      tr =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :tool_result)
        )

      assert tr.payload.diff == true
      assert tr.payload.path == "a.ex"
      assert tr.payload.old == "x"
      assert tr.payload.new == "y"
    end

    test "a tool_unexecuted event seals a visible ⚠ marker message" do
      session_id = "contract-unexec-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_unexecuted, %{name: "write_file", reason: :dropped}},
        {:done, %{content: "done", usage: %{}}}
      ]

      {:ok, _} = Contract.pump(session_id, stream, prompt: "p")
      events = drain_events(session_id)

      marker =
        Enum.find(events, fn e ->
          e.payload[:item_type] == :message and is_binary(e.payload[:content]) and
            e.payload.content =~ "never executed"
        end)

      assert marker, "expected a ⚠ unexecuted marker message"
      assert marker.payload.content =~ "write_file"
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
