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
        {:tool_use, %{name: "fs_write", arguments: %{path: "/x"}, id: "call-1"}},
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

      assert started != nil,
             "pump must emit item_started before the first delta"

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

    test "a non-diff tool_result lifts a human :content summary (never an empty row)" do
      session_id = "contract-summary-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "list_dir", arguments: %{path: "."}, id: "call-1"}},
        {:tool_result,
         %{
           name: "list_dir",
           result: %{path: ".", entries: ["a.ex", "b/", "c.md"]}
         }},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "p")

      completed =
        session_id
        |> drain_events()
        |> Enum.find(
          &(&1.type == :item_completed and
              &1.payload[:item_type] == :tool_result)
        )

      # The structured result nests under :result; the summary is lifted to
      # :content, exactly where the harness block's body extraction reads it.
      assert completed.payload[:content] =~ "3 entries"
      assert completed.payload[:content] =~ "a.ex"
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

  describe "empty message suppression (no empty ❮ block, ever)" do
    # RED-FIRST (live harness defect, real LLM backend): a provider round
    # that carries tool calls ships its assistant "message" with empty or
    # whitespace content next to the real tool_calls (LM Studio-served
    # models stream a bare "\n\n" between thinking and the tool call).
    # pump/3 opened a message item on that blank delta, and the tool_use
    # boundary then SEALED it empty — an empty ❮ block in the transcript.
    # The message lifecycle now mirrors the reasoning lifecycle: lazily
    # opened at the first NON-BLANK text, so a blank run emits NO item at
    # all (no item_started, no item_completed, no block).

    defp completed_messages(events) do
      for %Event{type: :item_completed, payload: %{item_type: :message} = p} <-
            events,
          do: p
    end

    defp message_starteds(events) do
      Enum.filter(
        events,
        &(&1.type == :item_started and &1.payload[:item_type] == :message)
      )
    end

    test "a tool-call-only round emits NO message item for its blank pre-tool text" do
      session_id = "contract-empty-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      # The reported live shape: thinking, a whitespace-only text delta,
      # then the tool round, then the real final answer.
      stream = [
        {:reasoning, "let me look at the project"},
        {:text_delta, "\n\n"},
        {:tool_use, %{name: "read_file", arguments: %{"path" => "mix.exs"}, id: "c1"}},
        {:tool_result, %{name: "read_file", result: "defmodule..."}},
        {:text_delta, "the answer"},
        {:done, %{content: "the answer", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      # Exactly ONE sealed message — the real answer. The blank pre-tool
      # run sealed nothing (no empty ❮ block between the ∴ and the tool).
      assert [%{content: "the answer"}] = completed_messages(events)
      assert [_one] = message_starteds(events)

      # The reasoning block still seals ahead of the tool_use.
      reasoning_seal =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :reasoning)
        )

      tool_use =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :tool_use)
        )

      assert reasoning_seal.id < tool_use.id
    end

    test "a whitespace-only answer stream seals NO message item" do
      session_id = "contract-empty-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:text_delta, " "},
        {:text_delta, "\n\t"},
        {:done, %{content: " \n\t", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      assert completed_messages(events) == []
      assert message_starteds(events) == []

      # The turn still closes honestly.
      final = List.last(events)
      assert final.type == :turn_completed
      assert final.payload.final == true
    end

    test "a blank done after a tool round emits no empty final message item" do
      session_id = "contract-empty-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "list_dir", arguments: %{}, id: "c1"}},
        {:tool_result, %{name: "list_dir", result: "mix.exs"}},
        {:done, %{content: "", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      assert completed_messages(events) == []

      # The tool items and the final turn_completed are untouched.
      assert Enum.any?(
               events,
               &(&1.type == :item_completed and
                   &1.payload[:item_type] == :tool_result)
             )

      assert %Event{type: :turn_completed, payload: %{final: true}} =
               List.last(events)
    end

    test "leading blank text still lands in the pre-tool sealed message when real text follows" do
      session_id = "contract-empty-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:text_delta, "\n"},
        {:text_delta, "checking"},
        {:tool_use, %{name: "list_dir", arguments: %{}, id: "c1"}},
        {:tool_result, %{name: "list_dir", result: "mix.exs"}},
        {:done, %{content: "final", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      # The lazily-opened item's sealed content keeps the leading blank
      # chunk (accumulated untouched before the open), mirroring the
      # reasoning lifecycle's documented behavior.
      assert Enum.map(completed_messages(events), & &1.content) == [
               "\nchecking",
               "final"
             ]

      # The opener's own delta carries the full accumulated-so-far text.
      [opener | _] =
        Enum.filter(
          events,
          &(&1.type == :item_delta and &1.payload[:chunk] != nil and
              &1.payload[:thought] == nil)
        )

      assert opener.payload.chunk == "\nchecking"
    end
  end

  describe "reasoning item lifecycle (durable ∴ blocks)" do
    # RED-FIRST (Grok-Build-style peekable thinking): reasoning/thought
    # deltas used to stream into the live tail and evaporate when the
    # message item sealed — nothing durable to peek. Now reasoning gets
    # the SAME item lifecycle a message does: a lazily-opened durable
    # `item_type: :reasoning` item, ephemeral deltas carrying its id, and
    # a seal at the reasoning→answer transition (or turn end).

    defp reasoning_items(events) do
      for %Event{type: :item_completed, payload: %{item_type: :reasoning} = p} <-
            events,
          do: p
    end

    test "a thought stream opens a durable reasoning item, sealed before the message" do
      session_id = "contract-reason-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:reasoning, "let me think"},
        {:reasoning, " harder"},
        {:text_delta, "the answer"},
        {:done, %{content: "the answer", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "q")

      events = drain_events(session_id)

      started =
        Enum.find(
          events,
          &(&1.type == :item_started and &1.payload[:item_type] == :reasoning)
        )

      assert started != nil,
             "a thought must open a durable reasoning item_started"

      assert started.tier == :durable
      assert %{item_id: reasoning_id} = started.payload

      # The sealed reasoning block carries the full accumulated thought.
      [reasoning] = reasoning_items(events)
      assert reasoning.item_id == reasoning_id
      assert reasoning.content == "let me think harder"

      # Reasoning seals BEFORE the message item (its ∴ block renders first).
      msg =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :message)
        )

      reasoning_seal =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :reasoning)
        )

      assert reasoning_seal.id < msg.id
      assert msg.payload.content == "the answer"
    end

    test "reasoning deltas are ephemeral, marked thought:true, and carry the item_id" do
      session_id = "contract-reason-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:reasoning, "aa"},
        {:reasoning, "bb"},
        {:text_delta, "x"},
        {:done, %{content: "x", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      started =
        Enum.find(
          events,
          &(&1.type == :item_started and &1.payload[:item_type] == :reasoning)
        )

      reasoning_deltas =
        for %Event{type: :item_delta, payload: %{thought: true} = p} <- events,
            do: p

      assert length(reasoning_deltas) == 2

      for delta <- reasoning_deltas do
        assert delta.item_id == started.payload.item_id
      end

      for %Event{type: :item_delta} = e <- events,
          do: assert(e.tier == :ephemeral)
    end

    test "whitespace-only thinking seals NO reasoning block" do
      session_id = "contract-reason-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:reasoning, "  "},
        {:reasoning, "\n\t"},
        {:text_delta, "hi"},
        {:done, %{content: "hi", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      assert reasoning_items(events) == []

      refute Enum.any?(
               events,
               &(&1.type == :item_started and
                   &1.payload[:item_type] == :reasoning)
             )
    end

    test "think→tool→think→answer produces TWO reasoning blocks in true order" do
      session_id = "contract-reason-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:reasoning, "first I plan"},
        {:tool_use, %{name: "list_dir", arguments: %{}, id: "c1"}},
        {:tool_result, %{name: "list_dir", result: "mix.exs"}},
        {:reasoning, "now I conclude"},
        {:text_delta, "final"},
        {:done, %{content: "final", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      contents = reasoning_items(events) |> Enum.map(& &1.content)
      assert contents == ["first I plan", "now I conclude"]

      # The first reasoning seals BEFORE the tool_use (∴ block ahead of tool).
      first_reasoning =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :reasoning)
        )

      tool_use =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :tool_use)
        )

      assert first_reasoning.id < tool_use.id
    end

    test "a pure-thinking turn seals its reasoning at done (no answer text)" do
      session_id = "contract-reason-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:reasoning, "just thinking, no words"},
        {:done, %{content: "", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      assert [%{content: "just thinking, no words"}] = reasoning_items(events)
    end
  end

  describe "wire-boundary markers (durable ⚠ blocks)" do
    # RED-FIRST: an honest wire marker (length truncation / unparseable
    # chunk) was dropped by pump's catch-all `_other` clause — the LongCat
    # note flagged "no :marker sealing clause yet". A marker must seal as a
    # durable ⚠ message block so a truncated turn is never silent, and it
    # must COMPOSE with reasoning (∴ first, marker after the partial answer).

    defp message_items(events) do
      for %Event{type: :item_completed, payload: %{item_type: :message} = p} <-
            events,
          do: p
    end

    test "a {:marker, text} event seals a durable ⚠ message item" do
      session_id = "contract-marker-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:marker, "⚠ response truncated — hit token limit"},
        {:done, %{content: "", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      marker =
        Enum.find(events, fn e ->
          e.type == :item_completed and e.payload[:item_type] == :message and
            is_binary(e.payload[:content]) and e.payload.content =~ "truncated"
        end)

      assert marker, "expected a ⚠ truncation marker message"
      assert marker.tier == :durable
    end

    test "a blank marker seals nothing" do
      session_id = "contract-marker-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:marker, "   "},
        {:done, %{content: "hi", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      # Only the real answer message seals; no empty marker block.
      assert [%{content: "hi"}] = message_items(events)
    end

    test "reasoning seals as ∴ BEFORE a partial answer, which precedes the truncation marker" do
      session_id = "contract-marker-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      # The producer order for a non-empty length-truncated round:
      # reasoning → partial content → marker → done.
      stream = [
        {:reasoning, "deep thought"},
        {:text_delta, "partial"},
        {:marker, "⚠ truncated"},
        {:done, %{content: "partial", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      reasoning_started =
        Enum.find(
          events,
          &(&1.type == :item_started and &1.payload[:item_type] == :reasoning)
        )

      answer_started =
        Enum.find(
          events,
          &(&1.type == :item_started and &1.payload[:item_type] == :message and
              &1.payload[:item_id] != marker_item_id(events))
        )

      marker_started =
        Enum.find(
          events,
          &(&1.type == :item_started and &1.payload[:item_type] == :message and
              &1.payload[:item_id] == marker_item_id(events))
        )

      # Render order is first-appearance (item_started): ∴, answer, ⚠.
      assert reasoning_started.id < answer_started.id
      assert answer_started.id < marker_started.id

      # The partial answer and the marker are DISTINCT durable messages
      # (the answer is not double-sealed, the marker is not folded in).
      contents = message_items(events) |> Enum.map(& &1.content)
      assert "partial" in contents
      assert Enum.any?(contents, &(&1 =~ "truncated"))
    end

    # The marker's message item_id is the one whose sealed content carries
    # the ⚠ text; used to tell the answer message from the marker message.
    defp marker_item_id(events) do
      Enum.find_value(events, fn
        %Event{type: :item_completed, payload: %{item_type: :message} = p} ->
          if is_binary(p[:content]) and p.content =~ "truncated",
            do: p[:item_id],
            else: nil

        _ ->
          nil
      end)
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
        {:approval_requested, %{request_id: "r1", tool_name: "edit_file", options: []}},
        {:approval_decided, %{request_id: "r1", option_id: "allow", decision: :allow}},
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
          &(&1.type == :item_completed and
              &1.payload[:item_type] == :tool_result)
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
