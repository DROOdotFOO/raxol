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

  describe "mapping table" do
    test "begin_turn emits a durable turn_started with the prompt", ctx do
      {:ok, turn_id} = AcpStreamAdapter.begin_turn(ctx.adapter, "do the thing")

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :turn_started, tier: :durable, turn_id: ^turn_id} = event
      assert event.payload == %{prompt: "do the thing"}
      assert event.id == 1
    end

    test "agent_message_chunk maps to an ephemeral item_delta", ctx do
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("hel")})

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :item_delta, tier: :ephemeral} = event
      assert event.payload == %{chunk: "hel"}
    end

    test "agent_thought_chunk maps to an ephemeral item_delta marked as thought", ctx do
      update!(ctx.adapter, {:agent_thought_chunk, text_chunk("hmm")})

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :item_delta, tier: :ephemeral} = event
      assert event.payload == %{chunk: "hmm", thought: true}
    end

    test "a non-text content block degrades to an honest placeholder, never a crash", ctx do
      update!(ctx.adapter, {:agent_message_chunk, %{content: {:image, %{data: "..."}}}})
      assert %{payload: %{chunk: "[image]"}} = next_event(ctx.session_id)

      update!(ctx.adapter, {:agent_message_chunk, %{content: {:bogus_variant, nil}}})
      assert %{payload: %{chunk: chunk}} = next_event(ctx.session_id)
      assert chunk =~ "bogus_variant"
    end

    test "a pending tool_call emits nothing; the terminal update emits the pair", ctx do
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
         %{tool_call_id: "call-1", fields: %{status: :completed, raw_output: "3 matches"}}}
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

      assert %{payload: %{item_type: :tool_use, name: "rm"}} = next_event(ctx.session_id)

      assert %{payload: %{item_type: :tool_result, status: :failed}} =
               next_event(ctx.session_id)
    end

    test "a terminal update for a tool never announced still emits an honest pair", ctx do
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
      {:ok, turn_id} = AcpStreamAdapter.begin_turn(ctx.adapter, "p")
      assert %{type: :turn_started} = next_event(ctx.session_id)

      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :end_turn, _meta: %{}})

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :turn_completed, tier: :durable, turn_id: ^turn_id} = event
      assert %{final: true, stop_reason: :end_turn} = event.payload
      refute Map.has_key?(event.payload, :refs)
    end

    test "max_tokens / max_turn_requests carry their stop_reason through", ctx do
      for reason <- [:max_tokens, :max_turn_requests] do
        {:ok, _} = AcpStreamAdapter.begin_turn(ctx.adapter, "p")
        assert %{type: :turn_started} = next_event(ctx.session_id)

        :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: reason})

        assert %{type: :turn_completed, payload: %{stop_reason: ^reason, final: true}} =
                 next_event(ctx.session_id)
      end
    end

    test "refusal completes the turn DISCLOSED, never painted as a normal end", ctx do
      {:ok, _} = AcpStreamAdapter.begin_turn(ctx.adapter, "p")
      assert %{type: :turn_started} = next_event(ctx.session_id)

      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :refusal})

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :turn_completed} = event
      assert %{final: true, stop_reason: :refusal, refused: true} = event.payload
    end

    test "cancelled emits the canceled bracket, not a completed one", ctx do
      {:ok, turn_id} = AcpStreamAdapter.begin_turn(ctx.adapter, "p")
      assert %{type: :turn_started} = next_event(ctx.session_id)

      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: :cancelled})

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :turn_canceled, tier: :durable, turn_id: ^turn_id} = event
      assert %{reason: :cancelled, stop_reason: :cancelled} = event.payload
    end

    test "a forged stop reason is disclosed as :unknown, never coerced, never granted refs",
         ctx do
      {:ok, _} = AcpStreamAdapter.begin_turn(ctx.adapter, "p")
      assert %{type: :turn_started} = next_event(ctx.session_id)

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

    test "a string stop reason (wire value smuggled past decode) is treated as forged", ctx do
      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, %{stop_reason: "end_turn"})

      assert %{payload: %{stop_reason: :unknown}} = next_event(ctx.session_id)
    end

    test "{:error, reason} emits a durable :error event", ctx do
      :ok = AcpStreamAdapter.finish_turn(ctx.adapter, {:error, :timeout})

      event = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :error, tier: :durable, payload: %{reason: :timeout}} = event
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
    test "an unmapped variant is skipped, counted, and disclosed exactly once per kind", ctx do
      update!(ctx.adapter, {:usage_update, %{used: 10, size: 100}})

      marker = ctx.session_id |> next_event() |> assert_boundary_clean()
      assert %{type: :error, tier: :durable} = marker
      assert marker.payload == %{reason: :unmapped_acp_update, kind: "usage_update"}

      # Second occurrence: counted, but no second marker.
      update!(ctx.adapter, {:usage_update, %{used: 20, size: 100}})
      refute_event(ctx.session_id)

      # A different kind gets its own first-occurrence marker.
      update!(ctx.adapter, {:current_mode_update, %{current_mode_id: "yolo"}})

      assert %{payload: %{reason: :unmapped_acp_update, kind: "current_mode_update"}} =
               next_event(ctx.session_id)

      assert AcpStreamAdapter.unmapped_counts(ctx.adapter) == %{
               "usage_update" => 2,
               "current_mode_update" => 1
             }
    end

    test "a {:raw, map} manual feed and outright garbage are both survived and disclosed", ctx do
      update!(ctx.adapter, {:raw, %{"sessionUpdate" => "quantum_update", "x" => 1}})

      assert %{payload: %{kind: "raw:quantum_update"}} = next_event(ctx.session_id)

      update!(ctx.adapter, %{"not" => "a tuple"})
      assert %{payload: %{kind: "unrecognized"}} = next_event(ctx.session_id)

      update!(ctx.adapter, {:raw, "not a map"})
      # {:raw, binary} hits the atom-tag clause: counted under its tag.
      assert %{payload: %{kind: "raw"}} = next_event(ctx.session_id)

      # The adapter is still alive and translating after all of it.
      update!(ctx.adapter, {:agent_message_chunk, text_chunk("still here")})
      assert %{payload: %{chunk: "still here"}} = next_event(ctx.session_id)
    end

    test "user_message_chunk is deliberately unmapped (echoing the user is the surface's job)",
         ctx do
      update!(ctx.adapter, {:user_message_chunk, text_chunk("me")})

      assert %{payload: %{reason: :unmapped_acp_update, kind: "user_message_chunk"}} =
               next_event(ctx.session_id)
    end
  end

  # -- 5. start options -------------------------------------------------------

  describe "start options" do
    test "a malformed :subscribe option fails the start honestly" do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_subscribe_option, :nope}} =
               AcpStreamAdapter.start_link(session_id: "s", subscribe: :nope)
    end
  end
end
