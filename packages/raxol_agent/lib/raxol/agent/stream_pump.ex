defmodule Raxol.Agent.StreamPump do
  @moduledoc """
  The v0 producer of the event contract: drains a `Raxol.Agent.Stream.run/2`
  or `Raxol.Agent.Stream.react/2` enumerable into `Raxol.Agent.Contract.Event`s.

  `pump/3` wraps each stream event in the contract envelope and publishes it
  through `Raxol.Agent.SessionStreamer`. Surfaces subscribe to the streamer
  and render; they never reach into the loop. `Raxol.Agent.EmitBridge` is the
  other producer and publishes behind the same `SessionStreamer` boundary.

  (Distinct from `Raxol.Agent.Protocol`, which is agent-to-agent cockpit
  messaging — this module is the core↔surface boundary.)

  ## Item lifecycle

  `Raxol.Agent.Contract` lists the vocabulary. What this producer adds:

    * `:item_started` is emitted at an item's first NON-BLANK delta (message
      and reasoning items are both lazily opened — blank-only text opens
      nothing, so a tool-call round whose assistant "message" is
      empty/whitespace seals no empty ❮ block) and before every tool_use /
      tool_result completion, so the live producer speaks the same item
      lifecycle the fixture corpus does — the projection's live tail
      (`Raxol.Harness.Projection.BlockBuilder.build_tail/2`) only surfaces
      deltas for an item with a started group, which is what makes mid-turn
      streaming render at all.
    * A `:reasoning` item carries the model's chain-of-thought (`content`)
      and seals as a durable, foldable/peekable ∴ block — reasoning is a
      first-class transcript fact once sealed, never silently dropped.
    * `item_id`s are turn-scoped (`"i1"`, `"i2"`, …) and distinct per item —
      without them every completion folds into one (nil-keyed) projection
      group and later completions are dropped as duplicates.

  ## Evidence marker

  On the closing `turn_completed{final: true}`, `gated_done_payload/4` stamps
  the `evidence` marker `Raxol.Agent.Contract` documents:

    * `:accepted` — stamped alongside `refs` (untouched: still the sole
      accepted-refs carrier).
    * `:absent` — the `{:error, :evidence_required}` gate arm: the turn
      offered no refs at all.
    * `:rejected` — the `{:error, reason}` gate arm: refs were offered and
      the gate refused them. `evidence_rejected` carries the
      `Raxol.Agent.DoneGate` verdict tuple flattened EXPLICITLY into string
      values — never handed to `Raxol.Agent.Contract.sanitize_payload/1` to
      `inspect/1`-stringify a raw tuple onto the wire. `DoneGate`'s
      `:unturned_done` reject is unreachable on this path (`pump/3` always
      mints a non-nil `turn_id`) and deliberately has no clause here — it
      stays out of the wire enum.

  The marker is written from the *same* `DoneGate.gate/3` verdict that decides
  the done — producer and decider are one call, they cannot disagree at write
  time. This is pinned by `Raxol.Agent.StreamPumpTest` ("the done gate is
  consulted on the real done path", "a mutation's own result echo is
  rejected", "a zero-tool turn closes ungated") and by
  `Raxol.Agent.Red.U21RealProducerRegressionTest`, which gates journals
  produced by the real `pump/3`, not synthetic ones.

  Both `[:raxol, :agent, :done_gate, :ungated_done]` and `[:raxol, :agent,
  :done_gate, :rejected_evidence]` telemetry are emitted on the same arms —
  the marker is the durable/replay view; telemetry is the live-ops view.
  """

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.DoneGate
  alias Raxol.Agent.SessionStreamer

  @doc """
  Drain a `Raxol.Agent.Stream` enumerable into the contract.

  Emits `turn_started` first, then maps each stream event onto the v0
  vocabulary and publishes it via `SessionStreamer.emit/2`. Returns
  `{:ok, %{content, usage}}` on completion or `{:error, reason}`.

  Blocks until the stream is done — run it in its own process (the CLI
  uses `Task.async/1`); subscribers receive events live.
  """
  @spec pump(String.t(), Enumerable.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def pump(session_id, stream, opts \\ []) do
    prompt = Keyword.get(opts, :prompt, "")
    turn_id = "turn-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [])

    started =
      emit_event(session_id, turn_id, counter, :turn_started, :durable, %{
        prompt: prompt
      })

    # The accumulator carries the run result, the durable journal emitted so
    # far this turn (so the done site can consult DoneGate.gate/3 over the
    # real journal — ephemeral `item_delta`s are never journaled), and the
    # item lifecycle bookkeeping: a turn-scoped item sequence plus the one
    # lazily-opened message item (id + its accumulated chunks). The item
    # lifecycle is what makes live streaming render: without `item_started`
    # + per-item `item_id`s the projection's live tail never materializes
    # and every completion collapses into one nil-keyed group.
    final_acc =
      Enum.reduce(
        stream,
        %{
          result: {:error, :no_result},
          journal: [started],
          item_seq: 0,
          msg_item: nil,
          msg_chunks: [],
          reasoning_item: nil,
          reasoning_chunks: []
        },
        fn stream_event, acc ->
          handle_stream_event(session_id, turn_id, counter, stream_event, acc)
        end
      )

    # A stream that halts without ever reaching a `{:done, _}` or
    # `{:error, _}` element (so `result` is still its `:no_result` init
    # value) leaves the reduce above with no terminal arm to seal whatever
    # was open. A no-op once `:done`/`:error` have already closed both (the
    # common case) — closing here too costs nothing, and it means the
    # producer never strands an item_started with no completion no matter
    # how the enumerable ends.
    final_acc = close_reasoning_item(session_id, turn_id, counter, final_acc)
    final_acc = close_message_item(session_id, turn_id, counter, final_acc)

    final_acc.result
  end

  # Seal any open reasoning-then-message item before a tool/approval
  # boundary, so pre-boundary text becomes its own block (ordered ahead of
  # the boundary item) and a LATER text_delta opens a FRESH message instead
  # of re-entering the still-open one and fusing across the boundary. Both
  # closes are no-ops when nothing is open (the common tool_use-then-result
  # path, where tool_use already sealed), so this is safe to apply at every
  # boundary arm and only changes behavior for a producer that reaches a
  # tool_result/approval/tool_unexecuted with a message still open.
  defp seal_open_items(session_id, turn_id, counter, acc) do
    acc = close_reasoning_item(session_id, turn_id, counter, acc)
    close_message_item(session_id, turn_id, counter, acc)
  end

  defp handle_stream_event(session_id, turn_id, counter, event, acc) do
    case event do
      # Chain-of-thought / thinking text. Reasoning gets the SAME item
      # lifecycle a message does (lazily-opened durable item, its own
      # turn-scoped item_id, ephemeral deltas streaming into the live
      # tail), so what the machine actually thought seals as a durable,
      # peekable ∴ block instead of evaporating from the live tail when
      # the answer's message item seals. See `stream_reasoning/5`.
      {:reasoning, chunk} when is_binary(chunk) ->
        stream_reasoning(session_id, turn_id, counter, acc, chunk)

      {:text_delta, chunk} ->
        # First delta of the answer: the reasoning→answer transition
        # seals the open reasoning item as its own durable block, ordered
        # before this message (its item_started was emitted first).
        acc = close_reasoning_item(session_id, turn_id, counter, acc)
        stream_message(session_id, turn_id, counter, acc, chunk)

      {:tool_use, %{name: name} = tool_use} ->
        # A text run interrupted by a tool call is a real assistant
        # message: seal it as its own item (ordered before the tool
        # items) rather than leaking it into the final answer's item.
        # Any open reasoning (think→tool, no intervening answer text)
        # seals first as its own ∴ block, ahead of the tool.
        acc = seal_open_items(session_id, turn_id, counter, acc)

        complete_item(session_id, turn_id, counter, acc, :tool_use, %{
          name: name,
          arguments: Map.get(tool_use, :arguments, %{}),
          call_id: Map.get(tool_use, :id)
        })

      {:tool_result, %{name: name} = tool_result} ->
        # Seal an open message/reasoning first (symmetric with :tool_use), so
        # a result arriving with a message still open does not later fuse
        # pre- and post-result text into one block across the boundary.
        acc = seal_open_items(session_id, turn_id, counter, acc)

        complete_item(
          session_id,
          turn_id,
          counter,
          acc,
          :tool_result,
          tool_result_extra(name, Map.get(tool_result, :result))
        )

      # A consequential tool is holding for a keyboard answer. Emitted
      # through pump (not out-of-band) so it shares the run's id sequence
      # and the surface's BlockBuilder folds it — with its later
      # `approval_decided` answer — into ONE approval block that holds the
      # seal frontier between the tool_use and its result (correct ordering).
      {:approval_requested, payload} when is_map(payload) ->
        acc = seal_open_items(session_id, turn_id, counter, acc)

        ev =
          emit_event(
            session_id,
            turn_id,
            counter,
            :approval_requested,
            :durable,
            payload
          )

        %{acc | journal: [ev | acc.journal]}

      {:approval_decided, payload} when is_map(payload) ->
        acc = seal_open_items(session_id, turn_id, counter, acc)

        ev =
          emit_event(
            session_id,
            turn_id,
            counter,
            :approval_decided,
            :durable,
            payload
          )

        %{acc | journal: [ev | acc.journal]}

      # The honesty marker: a tool call the model made that produced no
      # receipt. A claim of action with zero receipts is NEVER silent — it
      # seals a visible ⚠ message item into the transcript (full item
      # lifecycle, like every other completed item).
      {:tool_unexecuted, payload} when is_map(payload) ->
        acc = seal_open_items(session_id, turn_id, counter, acc)

        complete_item(session_id, turn_id, counter, acc, :message, %{
          content: tool_unexecuted_marker(payload)
        })

      # An honest wire-boundary marker: a length-truncated round that still
      # produced partial answer text (complete/2 loop), or an unparseable /
      # again-degraded chunk forwarded on the streaming path. A truncated or
      # unparseable marker seals as a durable ⚠ message so the notice is a
      # peekable transcript fact. Any OPEN reasoning seals FIRST (∴ ahead of
      # the warning); an open message is LEFT open, so its own `done` seal
      # keeps the partial answer a single, un-duplicated block that (by
      # pump's first-appearance order) renders BEFORE the marker qualifying
      # it. Blank marker → no-op.
      {:marker, text} when is_binary(text) ->
        if blank?(text) do
          acc
        else
          acc = close_reasoning_item(session_id, turn_id, counter, acc)

          complete_item(session_id, turn_id, counter, acc, :message, %{
            content: text
          })
        end

      {:turn_complete, info} ->
        # Close any reasoning that ran this round (think with no answer
        # text before the round boundary) so it seals as a durable block
        # rather than dangling in the live tail into the next round.
        acc = close_reasoning_item(session_id, turn_id, counter, acc)

        ev =
          emit_event(
            session_id,
            turn_id,
            counter,
            :turn_completed,
            :durable,
            put_model(
              %{
                iteration: Map.get(info, :iteration, 0),
                usage: Map.get(info, :usage, %{}),
                final: false
              },
              info
            )
          )

        %{acc | journal: [ev | acc.journal]}

      {:done, %{content: content} = info} ->
        # A pure-thinking tail (reasoning with no answer text) seals as
        # its own durable ∴ block before the final message closes.
        acc = close_reasoning_item(session_id, turn_id, counter, acc)

        # The final message closes the open (streamed) message item when
        # one exists — the SAME item the deltas accumulated into, so the
        # tail hands off to the sealed block. The done content is
        # authoritative for the sealed record. A turn ending with NO open
        # item and BLANK done content (a tool-only or answerless turn)
        # resolves to no item at all — sealing an empty message would
        # paint a blank ❮ block, and an empty message is not information.
        {item_id, acc} =
          done_message_item(session_id, turn_id, counter, acc, content)

        journal =
          case item_id do
            nil ->
              acc.journal

            item_id ->
              message_ev =
                emit_event(
                  session_id,
                  turn_id,
                  counter,
                  :item_completed,
                  :durable,
                  %{item_id: item_id, item_type: :message, content: content}
                )

              [message_ev | acc.journal]
          end

        # The journal accumulates newest-first (prepend); DoneGate consumes it
        # chronologically, so reverse ONCE here at the single read site. This
        # is the exact list the append form produced, so evidence offsets on
        # the wire are unchanged.
        chronological = Enum.reverse(journal)
        refs = DoneGate.evidence_refs(chronological, turn_id)

        final_ev =
          emit_event(
            session_id,
            turn_id,
            counter,
            :turn_completed,
            :durable,
            gated_done_payload(chronological, turn_id, refs, info)
          )

        %{
          acc
          | result: {:ok, %{content: content, usage: Map.get(info, :usage, %{})}},
            journal: [final_ev | journal]
        }

      {:error, reason} ->
        # A halted stream (backend error, timeout, dropped connection) must
        # not leave a dangling item_started with no completion: whatever
        # reasoning/answer text streamed before the halt is sealed FIRST
        # (reasoning ahead of the message, mirroring every other boundary
        # in this reduce), so the durable journal never loses an open item
        # and the partial content survives replay instead of evaporating.
        acc = close_reasoning_item(session_id, turn_id, counter, acc)
        acc = close_message_item(session_id, turn_id, counter, acc)

        error_ev =
          emit_event(session_id, turn_id, counter, :error, :durable, %{
            reason: reason
          })

        %{acc | journal: [error_ev | acc.journal], result: {:error, reason}}

      _other ->
        acc
    end
  end

  # -- item lifecycle bookkeeping -------------------------------------------

  # Turn-scoped item ids, mirroring the fixture corpus ("i1", "i2", …).
  # Uniqueness only matters within the turn: the projection keys its
  # live tail by `{turn_id, item_id}`.
  defp next_item_id(acc),
    do: {"i#{acc.item_seq + 1}", %{acc | item_seq: acc.item_seq + 1}}

  # -- message item lifecycle -------------------------------------------------
  #
  # The answer mirrors the reasoning lifecycle below, with the same
  # deliberate laziness: the item is opened at the first NON-BLANK
  # accumulated text — never at a whitespace-only delta. A provider round
  # that carries tool calls ships its assistant "message" with empty or
  # whitespace content next to the real tool_calls (the standard
  # OpenAI/Anthropic tool-round shape; LM Studio-served models stream a
  # bare "\n\n" between thinking and the tool call). Opening the item on
  # that blank delta made the tool_use boundary seal an EMPTY message
  # item, which rendered as a blank ❮ block in the transcript. An empty
  # message is not information — it gets no item, no event, no block (the
  # "empty thinking → no ∴ block" rule, applied to the answer channel).
  # Raw chunks still accumulate untouched while unopened, so leading
  # whitespace lands in the eventual sealed content when real text follows.

  # Buffer this chunk, then open-or-stream (mirrors `stream_reasoning/5`).
  defp stream_message(session_id, turn_id, counter, acc, chunk) do
    acc = %{acc | msg_chunks: [chunk | acc.msg_chunks]}
    open_or_stream_message(session_id, turn_id, counter, acc, chunk)
  end

  # Not yet opened: open on the FIRST non-blank accumulated content. The
  # opener's own `item_delta` carries the full accumulated-so-far text (so
  # the live tail is whole even if leading blank chunks preceded it);
  # every later delta carries just its own chunk.
  defp open_or_stream_message(
         session_id,
         turn_id,
         counter,
         %{msg_item: nil} = acc,
         _chunk
       ) do
    content = acc.msg_chunks |> Enum.reverse() |> Enum.join("")

    if blank?(content) do
      acc
    else
      {item_id, acc} = next_item_id(acc)

      started_ev =
        emit_event(session_id, turn_id, counter, :item_started, :durable, %{
          item_id: item_id,
          item_type: :message
        })

      emit_event(session_id, turn_id, counter, :item_delta, :ephemeral, %{
        item_id: item_id,
        chunk: content
      })

      %{acc | journal: [started_ev | acc.journal], msg_item: item_id}
    end
  end

  defp open_or_stream_message(session_id, turn_id, counter, acc, chunk) do
    emit_event(session_id, turn_id, counter, :item_delta, :ephemeral, %{
      item_id: acc.msg_item,
      chunk: chunk
    })

    acc
  end

  # Seals an open message item with its accumulated streamed text — the
  # mid-turn (pre-tool) close. When NO item is open (nothing streamed, or
  # only blank text that never opened one) there is nothing to seal — but
  # the buffer is always cleared, so a blank pre-tool run never leaks its
  # whitespace into a later round's message.
  defp close_message_item(
         _session_id,
         _turn_id,
         _counter,
         %{msg_item: nil} = acc
       ),
       do: %{acc | msg_chunks: []}

  defp close_message_item(session_id, turn_id, counter, acc) do
    content = acc.msg_chunks |> Enum.reverse() |> Enum.join("")

    ev =
      emit_event(session_id, turn_id, counter, :item_completed, :durable, %{
        item_id: acc.msg_item,
        item_type: :message,
        content: content
      })

    %{acc | journal: [ev | acc.journal], msg_item: nil, msg_chunks: []}
  end

  # -- reasoning item lifecycle ---------------------------------------------
  #
  # Reasoning mirrors the message lifecycle with one deliberate difference:
  # the item is opened LAZILY at the first NON-BLANK thought — a
  # whitespace-only reasoning stream opens no `item_started`, so it seals
  # no block (the "empty thinking → no ∴ block" rule). Until then the raw
  # chunks accumulate untouched, so leading whitespace still lands in the
  # eventual sealed content, just never as its own opener.

  # Buffer this chunk, then open-or-stream. The buffer is prepended (arrival
  # order restored on read) exactly like `msg_chunks`.
  defp stream_reasoning(session_id, turn_id, counter, acc, chunk) do
    acc = %{acc | reasoning_chunks: [chunk | acc.reasoning_chunks]}
    open_or_stream_reasoning(session_id, turn_id, counter, acc, chunk)
  end

  # Not yet opened: open on the FIRST non-blank accumulated content. The
  # opener's own `item_delta` carries the full accumulated-so-far text (so
  # the live tail is whole even if leading blank chunks preceded it); every
  # later delta carries just its own chunk. `thought: true` marks the
  # ephemeral delta as reasoning for the live tail.
  defp open_or_stream_reasoning(
         session_id,
         turn_id,
         counter,
         %{reasoning_item: nil} = acc,
         _chunk
       ) do
    content = acc.reasoning_chunks |> Enum.reverse() |> Enum.join("")

    if blank?(content) do
      acc
    else
      {item_id, acc} = next_item_id(acc)

      started_ev =
        emit_event(session_id, turn_id, counter, :item_started, :durable, %{
          item_id: item_id,
          item_type: :reasoning
        })

      emit_event(session_id, turn_id, counter, :item_delta, :ephemeral, %{
        item_id: item_id,
        chunk: content,
        thought: true
      })

      %{acc | journal: [started_ev | acc.journal], reasoning_item: item_id}
    end
  end

  defp open_or_stream_reasoning(session_id, turn_id, counter, acc, chunk) do
    emit_event(session_id, turn_id, counter, :item_delta, :ephemeral, %{
      item_id: acc.reasoning_item,
      chunk: chunk,
      thought: true
    })

    acc
  end

  # Seals an open reasoning item with its accumulated thought as a durable
  # ∴ block. A no-op when nothing is open — either the thought was blank
  # (never opened) or an earlier boundary already sealed it — but the
  # buffer is always cleared so a later reasoning segment starts fresh.
  defp close_reasoning_item(
         _session_id,
         _turn_id,
         _counter,
         %{reasoning_item: nil} = acc
       ),
       do: %{acc | reasoning_chunks: []}

  defp close_reasoning_item(session_id, turn_id, counter, acc) do
    content = acc.reasoning_chunks |> Enum.reverse() |> Enum.join("")

    ev =
      emit_event(session_id, turn_id, counter, :item_completed, :durable, %{
        item_id: acc.reasoning_item,
        item_type: :reasoning,
        content: content
      })

    %{
      acc
      | journal: [ev | acc.journal],
        reasoning_item: nil,
        reasoning_chunks: []
    }
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""

  # The done site's item resolution: reuse the open streamed item when
  # there is one (its deltas ARE this message); otherwise open a fresh
  # started pair for a NON-BLANK answer, so even a non-streamed answer
  # carries the full lifecycle the fixtures pin. Blank done content with
  # nothing open resolves to NO item (`nil` — the caller then emits no
  # item_completed): an answerless turn seals no empty ❮ message block.
  defp done_message_item(
         _session_id,
         _turn_id,
         _counter,
         %{msg_item: id} = acc,
         _content
       )
       when not is_nil(id),
       do: {id, %{acc | msg_item: nil, msg_chunks: []}}

  defp done_message_item(session_id, turn_id, counter, acc, content) do
    if blank_content?(content) do
      {nil, %{acc | msg_chunks: []}}
    else
      {item_id, acc} = next_item_id(acc)

      ev =
        emit_event(session_id, turn_id, counter, :item_started, :durable, %{
          item_id: item_id,
          item_type: :message
        })

      {item_id, %{acc | journal: [ev | acc.journal]}}
    end
  end

  # `nil` (a backend that produced no content field) counts as blank; any
  # other non-binary shape does NOT — an unexpected term stays visible in
  # the sealed record (fail-visible) rather than being silently dropped.
  defp blank_content?(nil), do: true
  defp blank_content?(text) when is_binary(text), do: blank?(text)
  defp blank_content?(_other), do: false

  # One completed item (tool_use / tool_result): a fresh id, its
  # `item_started` sibling, then the completion carrying `extra`.
  defp complete_item(session_id, turn_id, counter, acc, item_type, extra) do
    {item_id, acc} = next_item_id(acc)

    started_ev =
      emit_event(session_id, turn_id, counter, :item_started, :durable, %{
        item_id: item_id,
        item_type: item_type
      })

    completed_ev =
      emit_event(
        session_id,
        turn_id,
        counter,
        :item_completed,
        :durable,
        Map.merge(%{item_id: item_id, item_type: item_type}, extra)
      )

    # Prepend newest-first: completed follows started chronologically, so it
    # sits ahead of started in the reverse-ordered journal.
    %{acc | journal: [completed_ev, started_ev | acc.journal]}
  end

  # Consult the evidence gate on the real done path in observe-only mode (see
  # DoneGate's "Wiring status"). Completion stays fail-open: the turn always
  # closes with `final: true`, carrying its accepted `refs` when the gate
  # accepts, and emitting a telemetry signal for a non-accepting verdict so the
  # boundary is measurable without blocking every done on a v0 journal.
  # The model the provider BILLED, which is not always the one configured: with
  # no :model the backend substitutes its own default. Only a real string is
  # recorded, so a backend that reports none does not grow a null in the
  # durable payload.
  defp put_model(payload, info) do
    case Map.get(info, :model) do
      model when is_binary(model) and model != "" -> Map.put(payload, :model, model)
      _ -> payload
    end
  end

  defp gated_done_payload(journal, turn_id, refs, info) do
    base =
      put_model(%{usage: Map.get(info, :usage, %{}), final: true}, info)

    case DoneGate.gate(journal, turn_id, refs) do
      {:ok, _done} ->
        base
        |> Map.put(:refs, refs)
        |> Map.put(:evidence, :accepted)

      {:error, :evidence_required} ->
        :telemetry.execute(
          [:raxol, :agent, :done_gate, :ungated_done],
          %{},
          %{turn_id: turn_id}
        )

        Map.put(base, :evidence, :absent)

      {:error, reason} ->
        :telemetry.execute(
          [:raxol, :agent, :done_gate, :rejected_evidence],
          %{},
          %{turn_id: turn_id, reason: reason}
        )

        base
        |> Map.put(:evidence, :rejected)
        |> Map.put(:evidence_rejected, evidence_rejected_detail(refs, reason))
    end
  end

  # Flatten the DoneGate verdict tuple onto the wire EXPLICITLY — this must
  # never be handed to `Contract.sanitize_payload/1` to `inspect/1`-stringify (that
  # would render `"{:mutation_echo, 3}"` instead of a JSON-shaped detail).
  # Every `DoneGate.gate/3` rejection reaching this arm (i.e. everything but
  # `:evidence_required`, matched separately above) is a `{reason, offset}`
  # pair per `DoneGate.verdict/0`. `:unturned_done` is the one bare-atom
  # reject and is unreachable here — `pump/3` always mints a non-nil
  # `turn_id` — so it deliberately has no clause and stays out of the wire
  # enum; a value there would be a real invariant violation worth crashing
  # loudly on rather than silently coercing.
  @spec evidence_rejected_detail([DoneGate.offset()], {atom(), DoneGate.offset()}) ::
          %{String.t() => term()}
  defp evidence_rejected_detail(refs, {reason, offset}) when is_atom(reason) do
    %{"refs" => refs, "reason" => Atom.to_string(reason), "ref" => offset}
  end

  # A tool result whose payload carries a before/after image of a file
  # is flattened so the surface renders it as a
  # foldable ± DIFF block, not an opaque tool row: `path`/`old`/`new`/
  # `language` are lifted to the payload top level (where
  # `Raxol.UI.Components.Harness.Block.extract_diff_content/1` reads them)
  # and a `diff: true` marker tells the projection's BlockBuilder to resolve
  # this block's kind to `:diff`. A non-diff result is unchanged.
  # The `extra` fields `complete_item/6` merges onto a tool_result item.
  # `item_id`/`item_type` are added by `complete_item` itself.
  defp tool_result_extra(name, %{path: path, old: old, new: new} = result)
       when is_binary(path) and is_binary(old) and is_binary(new) do
    %{
      name: name,
      result: result,
      diff: true,
      path: path,
      old: old,
      new: new,
      language: Map.get(result, :language)
    }
  end

  # A non-diff tool result: lift a human-readable `content` SUMMARY so the
  # harness block renders a real receipt (entries count / bytes / matches /
  # excerpt) instead of an empty row -- the structured result sits nested
  # under `result`, where the block's `[:content]` extraction never looked.
  defp tool_result_extra(name, result) do
    base = %{name: name, result: result}

    case result_summary(result) do
      nil -> base
      summary -> Map.put(base, :content, summary)
    end
  end

  # Per-tool result receipts. Read defensively (a tool may return an error
  # tuple or an unexpected shape); an unrecognised result gets no summary
  # (the block falls back to its own honest empty rendering rather than
  # inspecting an arbitrary term into the transcript).
  defp result_summary(%{entries: entries}) when is_list(entries) do
    n = length(entries)
    preview = entries |> Enum.take(20) |> Enum.map_join(", ", &display_entry/1)
    count = "#{n} #{plural(n, "entry", "entries")}"
    if preview == "", do: count, else: count <> ": " <> preview
  end

  defp result_summary(%{content: content, truncated: truncated})
       when is_binary(content) do
    "#{byte_size(content)} bytes" <>
      if(truncated, do: " (truncated)", else: "") <> result_excerpt(content)
  end

  defp result_summary(%{count: count}) when is_integer(count),
    do: "#{count} #{plural(count, "match", "matches")}"

  defp result_summary(%{matches: matches}) when is_list(matches),
    do: "#{length(matches)} #{plural(length(matches), "match", "matches")}"

  defp result_summary(%{type: type, size: size}) when is_integer(size),
    do: "#{type}, #{size} bytes"

  defp result_summary(%{stdout: out}) when is_binary(out),
    do: "#{byte_size(out)} bytes" <> result_excerpt(out)

  defp result_summary(_result), do: nil

  # A list entry may be any term. `to_string/1` raises Protocol.UndefinedError
  # on a map/tuple/keyword -- inside pump's reduce that crashes the whole turn
  # rather than degrading to an honest summary. Stringify scalars directly and
  # `inspect/1` everything else.
  defp display_entry(e) when is_binary(e), do: e
  defp display_entry(e) when is_atom(e) or is_number(e), do: to_string(e)
  defp display_entry(e), do: inspect(e)

  defp result_excerpt(""), do: ""

  defp result_excerpt(text) when is_binary(text) do
    first = text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 80)
    if first == "", do: "", else: " · " <> first
  end

  defp plural(1, singular, _plural), do: singular
  defp plural(_n, _singular, plural), do: plural

  defp tool_unexecuted_marker(payload) do
    name = Map.get(payload, :name) || Map.get(payload, "name") || "unknown"
    reason = Map.get(payload, :reason) || Map.get(payload, "reason") || :unknown

    "⚠ tool call `#{name}` was recognized but never executed (#{inspect(reason)})"
  end

  defp emit_event(session_id, turn_id, counter, type, tier, payload) do
    :counters.add(counter, 1, 1)

    event = %Event{
      id: :counters.get(counter, 1),
      session_id: session_id,
      turn_id: turn_id,
      ts: System.system_time(:microsecond),
      family: :loop,
      type: type,
      tier: tier,
      payload: payload
    }

    SessionStreamer.emit(session_id, event)
    event
  end
end
