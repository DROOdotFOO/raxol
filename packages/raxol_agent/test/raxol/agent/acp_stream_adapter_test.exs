defmodule Raxol.Agent.AcpStreamAdapterTest do
  @moduledoc """
  Acceptance suite for `Raxol.Agent.AcpStreamAdapter` — the ACP
  `session/update` -> harness-contract producer.

  ## Doc guarantee -> test mapping

    1. Mapping table: begin_turn -> turn_started; message/thought chunks ->
       ephemeral item_delta; terminal tool frames -> the tool_use/tool_result
       item_completed pair; plan -> item_completed.
    2. Stop-reason honesty: end_turn/max_tokens/max_turn_requests complete;
       refusal completes DISCLOSED; cancelled emits the canceled bracket;
       a forged stop reason is disclosed as :unknown and never coerced.
    3. Refs ride `_meta`, decoded tolerantly and fail-safe (malformed = none).
    4. Unknown variants: skipped, counted, one honest durable marker per kind.
    5. Every emitted event passes `Raxol.Harness.EventBoundary.normalize/1`
       (the driver's security seam) — the adapter can never poison the
       live pipeline with a shape the boundary rejects.

  Hostile-frame coverage (the generator/oracle audit): unknown variants,
  `{:raw, map}` feeds, garbage terms, malformed `_meta`, forged stop
  reasons, non-text content blocks, updates for tools never announced.
  """

  use ExUnit.Case, async: false

  alias Raxol.Agent.AcpStreamAdapter
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Harness.EventBoundary

  setup do
    start_supervised!({SessionStreamer, []})

    session_id = "acp-adapter-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(session_id)

    {:ok, adapter} = AcpStreamAdapter.start_link(session_id: session_id)
    %{adapter: adapter, session_id: session_id}
  end

  defp update!(adapter, update) do
    send(adapter, {:acp_session_update, "acp-sess", update})
  end

  defp next_event(session_id) do
    assert_receive {:session_event, ^session_id, %Event{} = event}, 1_000
    event
  end

  defp refute_event(session_id) do
    refute_receive {:session_event, ^session_id, _event}, 100
  end

  # The boundary oracle: an adapter event must survive the driver's
  # security seam, or it would never render at all.
  defp assert_boundary_clean(event) do
    assert {:ok, _map} = EventBoundary.normalize(event)
    event
  end

  defp text_chunk(text), do: %{content: {:text, %{text: text}}}

  # -- 1. mapping table ---------------------------------------------------

  # begin_turn emits turn_started AND (non-empty prompt) the user echo;
  # this consumes both so a test can get straight to the frames under test.
  defp begin!(ctx, prompt) do
    {:ok, turn_id} = AcpStreamAdapter.begin_turn(ctx.adapter, prompt)
    assert %{type: :turn_started} = next_event(ctx.session_id)

    unless prompt == "" do
      assert %{type: :item_started} = next_event(ctx.session_id)

      assert %{type: :item_completed, payload: %{role: :user}} =
               next_event(ctx.session_id)
    end

    turn_id
  end

  describe "mapping table" do
    test "begin_turn emits a durable turn_started, then the user echo item",
         ctx do
      {:ok, turn_id} = AcpStreamAdapter.begin_turn(ctx.adapter, "do the thing")

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :turn_started, tier: :durable, turn_id: ^turn_id} = event
      assert event.payload == %{prompt: "do the thing"}
      assert event.id == 1

      # The speaker-separation producer half: one durable :message item
      # (a well-formed item_started/item_completed bracket, the
      # speaker-roles fixture's own paired shape) with the EXACT user
      # role marker, before any agent chunk can flow.
      opener = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :item_started, tier: :durable, turn_id: ^turn_id} = opener
      assert %{item_type: :message, item_id: item_id} = opener.payload
      assert opener.id == 2

      echo = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :item_completed, tier: :durable, turn_id: ^turn_id} = echo

      assert echo.payload == %{
               item_type: :message,
               item_id: item_id,
               role: :user,
               content: "do the thing"
             }

      assert echo.id == 3
    end

    test "an empty prompt emits no user echo (never an empty chevron line)",
         ctx do
      {:ok, _turn_id} = AcpStreamAdapter.begin_turn(ctx.adapter, "")

      assert %{type: :turn_started} = next_event(ctx.session_id)
      refute_event(ctx.session_id)
    end

    test "agent_message_chunk maps to an ephemeral item_delta", ctx do
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("hel")})

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :item_delta, tier: :ephemeral} = event
      assert event.payload == %{chunk: "hel"}
    end

    test "agent_thought_chunk opens a durable reasoning item + ephemeral thought delta",
         ctx do
      begin!(ctx, "q")
      update!(ctx.adapter, {:agent_thought_chunk, text_chunk("hmm")})

      opener = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :item_started, tier: :durable} = opener
      assert %{item_type: :reasoning, item_id: item_id} = opener.payload

      delta = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :item_delta, tier: :ephemeral} = delta
      assert delta.payload == %{chunk: "hmm", thought: true, item_id: item_id}
    end

    test "a non-text content block degrades to an honest placeholder, never a crash",
         ctx do
      update!(
        ctx.adapter,
        {:agent_message_chunk, %{content: {:image, %{data: "..."}}}}
      )

      assert %{payload: %{chunk: "[image]"}} = next_event(ctx.session_id)

      update!(
        ctx.adapter,
        {:agent_message_chunk, %{content: {:bogus_variant, nil}}}
      )

      assert %{payload: %{chunk: chunk}} = next_event(ctx.session_id)
      assert chunk =~ "bogus_variant"
    end

    test "a pending tool_call emits nothing; the terminal update emits the pair",
         ctx do
      update!(
        ctx.adapter,
        {:tool_call,
         %{
           tool_call_id: "call-1",
           title: "grep",
           status: :pending,
           raw_input: %{pattern: "x"}
         }}
      )

      refute_event(ctx.session_id)

      update!(
        ctx.adapter,
        {:tool_call_update,
         %{
           tool_call_id: "call-1",
           fields: %{status: :completed, raw_output: "3 matches"}
         }}
      )

      tool_use = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :item_completed, tier: :durable} = tool_use

      assert tool_use.payload == %{
               item_type: :tool_use,
               name: "grep",
               arguments: %{pattern: "x"},
               call_id: "call-1"
             }

      tool_result = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :item_completed, tier: :durable} = tool_result

      assert tool_result.payload == %{
               item_type: :tool_result,
               name: "grep",
               result: "3 matches",
               call_id: "call-1",
               status: :completed
             }

      # ids are monotonic across the pair
      assert tool_result.id == tool_use.id + 1
    end

    test "a tool_call already terminal emits the pair immediately", ctx do
      update!(
        ctx.adapter,
        {:tool_call, %{tool_call_id: "call-2", title: "rm", status: :failed, raw_input: %{}}}
      )

      assert %{payload: %{item_type: :tool_use, name: "rm"}} =
               next_event(ctx.session_id)

      assert %{payload: %{item_type: :tool_result, status: :failed}} =
               next_event(ctx.session_id)
    end

    test "a terminal update for a tool never announced still emits an honest pair",
         ctx do
      update!(
        ctx.adapter,
        {:tool_call_update, %{tool_call_id: "ghost-1", fields: %{status: :completed}}}
      )

      # Name falls back to the id; nothing crashes, nothing is silently lost.
      assert %{payload: %{item_type: :tool_use, name: "ghost-1"}} =
               next_event(ctx.session_id)

      assert %{payload: %{item_type: :tool_result, result: nil}} =
               next_event(ctx.session_id)
    end

    test "plan maps to a durable item_completed", ctx do
      entries = [
        %{content: "read the file", priority: :high, status: :pending},
        %{content: "edit it", priority: :low, status: :pending}
      ]

      update!(ctx.adapter, {:plan, %{entries: entries}})

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :item_completed, tier: :durable} = event
      assert %{item_type: :plan, entries: ^entries} = event.payload
    end
  end

  # -- 2. stop-reason honesty ----------------------------------------------

  describe "stop-reason honesty" do
    test "end_turn closes the turn with turn_completed final: true", ctx do
      turn_id = begin!(ctx, "p")

      :ok =
        AcpStreamAdapter.finish_turn(ctx.adapter, %{
          stop_reason: :end_turn,
          _meta: %{}
        })

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :turn_completed, tier: :durable, turn_id: ^turn_id} = event
      assert %{final: true, stop_reason: :end_turn} = event.payload
      refute Map.has_key?(event.payload, :refs)
    end

    test "max_tokens / max_turn_requests carry their stop_reason through",
         ctx do
      for reason <- [:max_tokens, :max_turn_requests] do
        _turn_id = begin!(ctx, "p")

        :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: reason})

        assert %{
                 type: :turn_completed,
                 payload: %{stop_reason: ^reason, final: true}
               } =
                 next_event(ctx.session_id)
      end
    end

    test "refusal completes the turn DISCLOSED, never painted as a normal end",
         ctx do
      _turn_id = begin!(ctx, "p")

      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :refusal})

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :turn_completed} = event

      assert %{final: true, stop_reason: :refusal, refused: true} =
               event.payload
    end

    test "cancelled emits the canceled bracket, not a completed one", ctx do
      turn_id = begin!(ctx, "p")

      :ok =
        AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :cancelled})

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :turn_canceled, tier: :durable, turn_id: ^turn_id} = event
      assert %{reason: :cancelled, stop_reason: :cancelled} = event.payload
    end

    test "a forged stop reason is disclosed as :unknown, never coerced, never granted refs",
         ctx do
      _turn_id = begin!(ctx, "p")

      :ok =
        AcpStreamAdapter.finish_turn(ctx.adapter, %{
          stop_reason: :become_root,
          _meta: %{"refs" => [1, 2]}
        })

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :turn_completed} = event
      assert %{stop_reason: :unknown, final: true} = event.payload
      assert event.payload.raw_stop_reason =~ "become_root"
      refute Map.has_key?(event.payload, :refs)
    end

    test "a string stop reason (wire value smuggled past decode) is treated as forged",
         ctx do
      :ok =
        AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: "end_turn"})

      assert %{payload: %{stop_reason: :unknown}} = next_event(ctx.session_id)
    end

    test "{:error, reason} emits a durable :error event", ctx do
      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, {:error, :timeout})

      event = ctx.session_id |> next_event() |> assert_boundary_clean()

      assert %{type: :error, tier: :durable, payload: %{reason: :timeout}} =
               event
    end

    test "a garbage outcome is an honest :error, never a crash", ctx do
      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, :nonsense)

      assert %{type: :error, payload: %{reason: :invalid_prompt_outcome}} =
               next_event(ctx.session_id)
    end
  end

  # -- 3. refs ride _meta, fail-safe ----------------------------------------

  describe "evidence refs" do
    test "well-formed _meta refs are attached to turn_completed", ctx do
      :ok =
        AcpStreamAdapter.finish_turn(ctx.adapter, %{
          stop_reason: :end_turn,
          _meta: %{"refs" => [3, 7]}
        })

      assert %{payload: %{refs: [3, 7]}} = next_event(ctx.session_id)
    end

    test "malformed refs decode as NO refs — never partially honored" do
      malformed = [
        %{stop_reason: :end_turn, _meta: %{"refs" => "3,7"}},
        %{stop_reason: :end_turn, _meta: %{"refs" => [3, -1]}},
        %{stop_reason: :end_turn, _meta: %{"refs" => [3, "7"]}},
        %{stop_reason: :end_turn, _meta: %{"refs" => %{"a" => 1}}},
        %{stop_reason: :end_turn, _meta: nil},
        %{stop_reason: :end_turn}
      ]

      for response <- malformed do
        assert AcpStreamAdapter.decode_refs(response) == [],
               "expected no refs for #{inspect(response)}"
      end
    end
  end

  # -- 4. unknown-variant honesty --------------------------------------------

  describe "unknown-variant honesty" do
    test "an unmapped variant is skipped, counted, and disclosed exactly once per kind",
         ctx do
      update!(ctx.adapter, {:usage_update, %{used: 10, size: 100}})

      marker = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :error, tier: :durable} = marker

      assert marker.payload == %{
               reason: :unmapped_acp_update,
               kind: "usage_update"
             }

      # Second occurrence: counted, but no second marker.
      update!(ctx.adapter, {:usage_update, %{used: 20, size: 100}})
      refute_event(ctx.session_id)

      # A different kind gets its own first-occurrence marker.
      update!(ctx.adapter, {:current_mode_update, %{current_mode_id: "yolo"}})

      assert %{
               payload: %{
                 reason: :unmapped_acp_update,
                 kind: "current_mode_update"
               }
             } =
               next_event(ctx.session_id)

      assert AcpStreamAdapter.unmapped_counts(ctx.adapter) == %{
               "usage_update" => 2,
               "current_mode_update" => 1
             }
    end

    test "a {:raw, map} manual feed and outright garbage are both survived and disclosed",
         ctx do
      update!(
        ctx.adapter,
        {:raw, %{"sessionUpdate" => "quantum_update", "x" => 1}}
      )

      assert %{payload: %{kind: "raw:quantum_update"}} =
               next_event(ctx.session_id)

      update!(ctx.adapter, %{"not" => "a tuple"})
      assert %{payload: %{kind: "unrecognized"}} = next_event(ctx.session_id)

      update!(ctx.adapter, {:raw, "not a map"})
      # {:raw, binary} hits the atom-tag clause: counted under its tag.
      assert %{payload: %{kind: "raw"}} = next_event(ctx.session_id)

      # The adapter is still alive and translating after all of it.
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("still here")})
      assert %{payload: %{chunk: "still here"}} = next_event(ctx.session_id)
    end

    test "user_message_chunk stays unmapped (the prompt echo already sealed at begin_turn — mapping it would double-echo)",
         ctx do
      update!(ctx.adapter, {:user_message_chunk, text_chunk("me")})

      assert %{
               payload: %{
                 reason: :unmapped_acp_update,
                 kind: "user_message_chunk"
               }
             } =
               next_event(ctx.session_id)
    end
  end

  # -- 5. assistant message accumulation --------------------------------------

  describe "assistant message accumulation" do
    test "chunks accumulate and seal as ONE durable message before the bracket",
         ctx do
      _turn_id = begin!(ctx, "p")

      update!(ctx.adapter, {:agent_message_chunk, text_chunk("it is ")})
      assert %{type: :item_delta} = next_event(ctx.session_id)
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("4")})
      assert %{type: :item_delta} = next_event(ctx.session_id)

      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :end_turn})

      assert %{type: :item_started} = next_event(ctx.session_id)
      message = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :item_completed, tier: :durable} = message
      assert %{item_type: :message, content: "it is 4"} = message.payload

      # The bracket follows the sealed message (pump/3's done-site order).
      assert %{type: :turn_completed, payload: %{final: true}} =
               next_event(ctx.session_id)
    end

    test "a canceled turn seals NO trailing message (Interrupt's no-trailing-output contract)",
         ctx do
      _turn_id = begin!(ctx, "p")

      update!(ctx.adapter, {:agent_message_chunk, text_chunk("half an ans")})
      assert %{type: :item_delta} = next_event(ctx.session_id)

      :ok =
        AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :cancelled})

      assert %{type: :turn_canceled} = next_event(ctx.session_id)
      refute_event(ctx.session_id)
    end

    test "the buffer resets between turns — no bleed into the next turn's message",
         ctx do
      _t1 = begin!(ctx, "p1")
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("stale")})
      assert %{type: :item_delta} = next_event(ctx.session_id)

      :ok =
        AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :cancelled})

      assert %{type: :turn_canceled} = next_event(ctx.session_id)

      _t2 = begin!(ctx, "p2")
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("fresh")})
      assert %{type: :item_delta} = next_event(ctx.session_id)
      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :end_turn})

      assert %{type: :item_started} = next_event(ctx.session_id)

      assert %{payload: %{item_type: :message, content: "fresh"}} =
               next_event(ctx.session_id)
    end
  end

  # -- 5a. turn-bracket discipline (out-of-bracket / overlapping frames) -------

  describe "turn-bracket discipline" do
    test "a second begin_turn while a turn is open closes the abandoned turn with turn_canceled{reason: superseded}, not a silent overwrite",
         ctx do
      turn_1 = begin!(ctx, "p1")

      # Accumulate some unsealed message text into turn 1's buffer — the
      # exact state the prior code silently discarded with no bracket.
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("half")})
      assert %{type: :item_delta} = next_event(ctx.session_id)

      # A second session/prompt dispatched before finish_turn/2 closed the
      # first — the overlapping-turn race the review flagged.
      {:ok, turn_2} = AcpStreamAdapter.begin_turn(ctx.adapter, "p2")
      refute turn_2 == turn_1

      abandoned = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :turn_canceled, tier: :durable, turn_id: ^turn_1} = abandoned
      assert abandoned.payload == %{reason: :superseded}

      # Turn 2 opens clean: turn_started, then its own user echo — no bleed
      # from turn 1's abandoned "half" buffer.
      assert %{type: :turn_started, turn_id: ^turn_2} = next_event(ctx.session_id)
      assert %{type: :item_started} = next_event(ctx.session_id)

      assert %{type: :item_completed, payload: %{role: :user, content: "p2"}} =
               next_event(ctx.session_id)

      update!(ctx.adapter, {:agent_message_chunk, text_chunk("fresh")})
      assert %{payload: %{chunk: "fresh"}} = next_event(ctx.session_id)

      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :end_turn})
      assert %{type: :item_started} = next_event(ctx.session_id)

      # Turn 1's "half" never resurfaces — only turn 2's own text seals.
      assert %{payload: %{item_type: :message, content: "fresh"}} =
               next_event(ctx.session_id)
    end

    test "an update arriving after finish_turn (turn_id already reset) is dropped, never attributed to no turn",
         ctx do
      _turn_id = begin!(ctx, "p1")
      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :end_turn})
      assert %{type: :turn_completed} = next_event(ctx.session_id)

      # A trailing/reordered frame for the already-closed turn: dropped, not
      # processed as an ephemeral item_delta attributed to turn_id: nil.
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("late")})
      refute_event(ctx.session_id)

      # The adapter is still alive and correctly resumes on the NEXT turn.
      _turn_2 = begin!(ctx, "p2")
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("on time")})
      assert %{payload: %{chunk: "on time"}} = next_event(ctx.session_id)
    end

    test "an update before the very first begin_turn is still processed (the mapping-table tests' standalone convention)",
         ctx do
      # Documents the deliberate scope boundary: pre-first-turn processing
      # stays permissive because the mapping-table suite (see the tests
      # above, e.g. "agent_message_chunk maps to an ephemeral item_delta")
      # exercises the ACP->contract mapping standalone, with no begin_turn
      # at all.
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("standalone")})
      assert %{payload: %{chunk: "standalone"}} = next_event(ctx.session_id)
    end
  end

  # -- 5b. reasoning item lifecycle --------------------------------------------

  describe "reasoning item lifecycle" do
    # The projected history through the exact live path: the driver's own
    # security seam (EventBoundary) followed by the shipped projection.
    defp projected_blocks(ctx) do
      ctx.session_id
      |> drain_events()
      |> Enum.map(fn event ->
        {:ok, map} = EventBoundary.normalize(event)
        map
      end)
      |> Raxol.Harness.Projection.project()
      |> Map.get(:blocks)
    end

    test "a thought then an answer seals a folded ∴ reasoning block BEFORE the message",
         ctx do
      # Projection-only: drive the whole turn, then project the FULL event
      # stream (consuming events first would hand the projection a partial
      # stream missing turn_started + the reasoning items).
      {:ok, _turn_id} = AcpStreamAdapter.begin_turn(ctx.adapter, "q")

      update!(
        ctx.adapter,
        {:agent_thought_chunk, text_chunk("weigh\nboth options")}
      )

      update!(ctx.adapter, {:agent_message_chunk, text_chunk("the answer")})
      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :end_turn})

      blocks = projected_blocks(ctx)

      reasoning = Enum.find(blocks, &(&1.kind == :reasoning))
      # The assistant message (NOT the user echo, which is also a :message).
      assistant =
        Enum.find(
          blocks,
          &(&1.kind == :message and Map.get(&1.content, :text) == "the answer")
        )

      assert reasoning != nil,
             "the sealed thought must render as a ∴ reasoning block"

      # Folded (peekable) and low-prominence by default.
      assert reasoning.fold == :folded
      assert reasoning.content.text == "weigh\nboth options"

      r_index = Enum.find_index(blocks, &(&1 == reasoning))
      a_index = Enum.find_index(blocks, &(&1 == assistant))
      assert r_index < a_index
    end

    test "think→tool→think→answer yields TWO reasoning blocks in true order",
         ctx do
      {:ok, _turn_id} = AcpStreamAdapter.begin_turn(ctx.adapter, "q")

      update!(ctx.adapter, {:agent_thought_chunk, text_chunk("first plan")})
      update!(ctx.adapter, {:agent_thought_chunk, text_chunk(" more")})

      update!(
        ctx.adapter,
        {:tool_call,
         %{
           tool_call_id: "c1",
           title: "grep",
           status: :completed,
           raw_output: "hit"
         }}
      )

      update!(ctx.adapter, {:agent_thought_chunk, text_chunk("now conclude")})
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("done")})
      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :end_turn})

      reasoning_texts =
        ctx
        |> projected_blocks()
        |> Enum.filter(&(&1.kind == :reasoning))
        |> Enum.map(& &1.content.text)

      assert reasoning_texts == ["first plan more", "now conclude"]
    end

    test "whitespace-only thinking seals no reasoning block", ctx do
      _turn_id = begin!(ctx, "q")

      update!(ctx.adapter, {:agent_thought_chunk, text_chunk("   ")})
      update!(ctx.adapter, {:agent_thought_chunk, text_chunk("\n")})
      # Nothing emitted for blank thoughts (no item_started, no delta).
      refute_event(ctx.session_id)

      update!(ctx.adapter, {:agent_message_chunk, text_chunk("hi")})
      assert %{type: :item_delta} = next_event(ctx.session_id)
      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :end_turn})

      refute Enum.any?(projected_blocks(ctx), &(&1.kind == :reasoning))
    end

    test "a pure-thinking turn seals its reasoning at finish_turn", ctx do
      _turn_id = begin!(ctx, "q")

      update!(ctx.adapter, {:agent_thought_chunk, text_chunk("only thinking")})

      assert %{type: :item_started, payload: %{item_type: :reasoning}} =
               next_event(ctx.session_id)

      assert %{type: :item_delta} = next_event(ctx.session_id)

      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :end_turn})

      # The reasoning seals (thought happened, it is a transcript fact)
      # before the turn bracket.
      assert %{
               type: :item_completed,
               payload: %{item_type: :reasoning, content: "only thinking"}
             } =
               next_event(ctx.session_id)

      assert %{type: :turn_completed} = next_event(ctx.session_id)
    end

    test "reasoning state resets between turns (no bleed)", ctx do
      _t1 = begin!(ctx, "p1")
      update!(ctx.adapter, {:agent_thought_chunk, text_chunk("stale thought")})
      assert %{type: :item_started} = next_event(ctx.session_id)
      assert %{type: :item_delta} = next_event(ctx.session_id)
      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :end_turn})

      assert %{type: :item_completed, payload: %{item_type: :reasoning}} =
               next_event(ctx.session_id)

      assert %{type: :turn_completed} = next_event(ctx.session_id)

      _t2 = begin!(ctx, "p2")
      update!(ctx.adapter, {:agent_thought_chunk, text_chunk("fresh")})

      assert %{type: :item_started, payload: %{item_id: id2}} =
               next_event(ctx.session_id)

      # A fresh turn's reasoning id never reuses the prior turn's.
      assert id2 =~ "-reasoning-1"
    end
  end

  describe "speaker separation pin" do
    test "projected history: the user block (role user, prompt text) precedes the first assistant block",
         ctx do
      {:ok, _turn_id} = AcpStreamAdapter.begin_turn(ctx.adapter, "what is 2+2")
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("it is ")})
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("4")})
      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :end_turn})

      # The full adapter stream, through the driver's own security seam
      # (EventBoundary) and the shipped projection — the exact live path.
      projection =
        ctx.session_id
        |> drain_events()
        |> Enum.map(fn event ->
          {:ok, map} = EventBoundary.normalize(event)
          map
        end)
        |> Raxol.Harness.Projection.project()

      message_blocks = Enum.filter(projection.blocks, &(&1.kind == :message))

      assert [user_block, assistant_block] = message_blocks
      assert Raxol.UI.Components.Harness.Block.role(user_block) == :user
      assert user_block.content.text == "what is 2+2"

      assert Raxol.UI.Components.Harness.Block.role(assistant_block) ==
               :assistant

      assert assistant_block.content.text == "it is 4"

      # BEFORE: the user block's position in the full block list is
      # strictly ahead of the first assistant message block.
      user_index = Enum.find_index(projection.blocks, &(&1 == user_block))

      assistant_index =
        Enum.find_index(projection.blocks, &(&1 == assistant_block))

      assert user_index < assistant_index
    end
  end

  defp drain_events(session_id, acc \\ []) do
    receive do
      {:session_event, ^session_id, event} ->
        drain_events(session_id, [event | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  # -- 6. start options -------------------------------------------------------

  describe "start options" do
    test "a malformed :subscribe option fails the start honestly" do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_subscribe_option, :nope}} =
               AcpStreamAdapter.start_link(session_id: "s", subscribe: :nope)
    end
  end
end
