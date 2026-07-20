defmodule Raxol.Agent.Contract do
  @moduledoc """
  Harness contract v0 — the typed event contract between the agent core and
  any surface (CLI, TUI, LiveView, remote).

  This is the minimal loop-family slice of the contract described in
  `docs/harness/architecture.md` ("The event contract"): every observable
  step of an agent run becomes a `Raxol.Agent.Contract.Event` and is
  published through `Raxol.Agent.SessionStreamer`. Surfaces subscribe to the
  streamer and render; they never reach into the loop.

  (Distinct from `Raxol.Agent.Protocol`, which is agent-to-agent cockpit
  messaging — this module is the core↔surface boundary.)

  ## v0 vocabulary (family `:loop` only)

    * `:turn_started`   — a prompt was accepted; payload `%{prompt}`
    * `:item_started`   — an item opened; payload `%{item_id, item_type}`.
      Emitted at an item's first NON-BLANK delta (message and reasoning
      items are both lazily opened — blank-only text opens nothing, so a
      tool-call round whose assistant "message" is empty/whitespace seals
      no empty ❮ block) and before every tool_use / tool_result
      completion, so the live producer speaks the same item lifecycle the
      fixture corpus does — the projection's live tail
      (`Raxol.Harness.Projection.BlockBuilder.build_tail/2`) only
      surfaces deltas for an item with a started group, which is what
      makes mid-turn streaming render at all.
    * `:item_delta`     — streaming text chunk; payload `%{item_id, chunk}`;
      the one **ephemeral** event (live render only, never for replay)
    * `:item_completed` — a finished item; payload
      `%{item_id, item_type: :message | :reasoning | :tool_use | :tool_result, ...}`.
      A `:reasoning` item carries the model's chain-of-thought (`content`)
      and seals as a durable, foldable/peekable ∴ block — reasoning is a
      first-class transcript fact once sealed, never silently dropped.
      `item_id`s are turn-scoped (`"i1"`, `"i2"`, …) and distinct per
      item — without them every completion folds into one (nil-keyed)
      projection group and later completions are dropped as duplicates.
    * `:turn_completed` — a turn boundary; payload
      `%{usage, iteration, final}` (`final: true` closes the run)
    * `:error`          — fault; payload `%{reason}`

  Growth note (the contract only grows): `:item_started` and the
  `item_id` payload keys are additive — both were already in the frozen
  loop vocabulary and the fixture wire shape.

  The meta family (probe swarm), `steer`/`approval` commands, and the
  durable journal sink attach behind this same boundary in later steps —
  producers change, the contract does not.

  ## U21 evidence tri-state wire marker

  On a `turn_completed{final: true}` produced by `gated_done_payload/4`, the
  payload grows one optional discriminator plus one optional detail —
  additive, grow-only, mirrors the Q1 `context`-field growth pattern:

    * `evidence: :accepted | :rejected | :absent` — grow-only enum (atom
      in-memory, JSON string on the wire, same convention as every other
      enum on this surface).
      - `:accepted` — stamped alongside `refs` (untouched: still the sole
        accepted-refs carrier, no rename, no move).
      - `:absent` — the `{:error, :evidence_required}` gate arm: the turn
        offered no refs at all.
      - `:rejected` — the `{:error, reason}` gate arm: refs were offered and
        the gate refused them.
    * `evidence_rejected` (present only when `evidence: :rejected`) —
      `%{"refs" => offered_refs, "reason" => reason_name, "ref" =>
      offset_or_nil}`, the `Raxol.Agent.DoneGate` verdict tuple flattened
      EXPLICITLY into these string values — never handed to
      `sanitize_payload/1` to `inspect/1`-stringify a raw tuple onto the
      wire. `reason_name` is one of `"missing_ref"`, `"not_evidence"`,
      `"foreign_turn"`, `"stale_evidence"`, `"mutation_echo"`.
      `DoneGate`'s `:unturned_done` reject is unreachable on this path
      (`pump/3` always mints a non-nil `turn_id`) and deliberately has no
      clause here — it stays out of the wire enum.

  Before this marker, a rejected done and a never-offered done were
  byte-identical on the wire (`%{usage, final: true}`, no `refs`) — the two
  gate-telemetry signals distinguished them live, but telemetry is not
  journaled, so a replayed surface could not tell "offered but refused" from
  "never offered". `evidence_status/1` decodes the field with the
  grandfather rule this gap requires: an `evidence` key present is
  authoritative; a **legacy** record (key absent) with `refs` present
  grandfathers to `:accepted` (the `refs` carrier never lied); a legacy
  record with neither key present is genuinely `:unknown` — it must NEVER
  be guessed as `:absent`, which would launder a historical rejection into
  a false "never offered" claim.

  Both `[:raxol, :agent, :done_gate, :ungated_done]` and `[:raxol, :agent,
  :done_gate, :rejected_evidence]` telemetry stay exactly as they were —
  this marker is the durable/replay view; telemetry remains the live-ops
  view. `refs` is untouched. The journal `schema_version` default bumps
  1.0.0 -> 1.1.0 (`Raxol.Agent.Journal.FileStore.Writer`, additive per
  upcast-on-read) alongside this payload growth; the pinned `v1.0.0` golden
  corpus stays literal "1.0.0" and unrewritten (an old journal's records are
  never rewritten in place, only decoded — covered by the grandfather rule
  above).

  ## Trust boundary — producer-stamped, journal-trusted

  `evidence_status/1` is a **decode**, not a **re-derivation**. It reports the
  enum the producer stamped; it does NOT re-run `DoneGate.gate/3` over the
  journal at read time. The soundness of the marker therefore rests on two
  explicit assumptions, stated here so a reader wiring it to a surface knows
  exactly what it does and does not defend against:

    1. **Producer honesty is stamped, not asserted.** The marker is written by
       `gated_done_payload/4` from the *same* `DoneGate.gate/3` verdict that
       decides the done — producer and decider are one call, they cannot
       disagree at write time. This producer half is pinned by
       `Raxol.Agent.ContractTest` ("the done gate is consulted on the real done
       path", "a mutation's own result echo is rejected", "a zero-tool turn
       closes ungated") and by `Raxol.Agent.Red.U21RealProducerRegressionTest`,
       which gates journals produced by the real `pump/3`, not synthetic ones.

    2. **The reader trusts the journal.** A hand-forged or replayed line that
       stamps `evidence: :accepted` — or a legacy-shaped forged line that omits
       the marker but carries a `refs` list, which the grandfather arm blesses
       `:accepted` — will decode as proven-done. This is the **identical**
       threat model as `refs` themselves and every other durable field: a
       journal that can be forged can fabricate tool results, refs, and verdicts
       directly. The marker adds no trust surface the journal did not already
       assume (append-only, single-writer integrity). It is sound only on a
       trusted, append-only journal.

  What the decoder *does* defend: an `evidence` value it cannot understand —
  a forged string, a future enum value, a garbage type — fails safe to
  `:unknown`, never `:accepted` (see `normalize_evidence/1`). A forged
  non-legacy line thus cannot launder a bogus marker into acceptance.

  **Read-side re-derivation was considered and deliberately rejected.**
  Re-running `DoneGate.gate/3` at decode time would (a) require the whole
  journal + turn + refs, coupling a pure single-record decode to journal state
  it does not carry, and (b) resurrect exactly the display-side re-evaluation of
  *open* gate predicates (staleness relative to *later* mutations) that must
  NOT be frozen or recomputed at the display surface. Documenting the
  append-only trust assumption is the honest close; a hostile-journal re-check
  is out of scope for a producer-stamped durable marker.

  ## Producers

  The v0 producer is `pump/3`: it drains a `Raxol.Agent.Stream.run/2` or
  `Raxol.Agent.Stream.react/2` enumerable, wraps each event in the contract
  envelope, and emits it into the streamer. The Dispatcher fold-site emit
  (the keystone) is the next producer and plugs in behind the same
  `SessionStreamer` boundary without surfaces changing.
  """

  alias Raxol.Agent.DoneGate
  alias Raxol.Agent.SessionStreamer

  defmodule Event do
    @moduledoc """
    The contract envelope. One struct per observable step; `id` is a
    per-run monotonic sequence (the future journal offset).
    """

    @derive Jason.Encoder
    defstruct v: 0,
              id: 0,
              session_id: nil,
              turn_id: nil,
              ts: 0,
              family: :loop,
              type: nil,
              tier: :durable,
              payload: %{},
              # --- U11 envelope growth (see docs/harness/architecture.md, "The
              # event contract") -----------------------------------------------
              # All defaulted; every landed v0 event and every journal record
              # without these keys decodes to these values — the grandfather
              # clause. The contract-only-grows rule is honored: new fields
              # are optional-with-default, never required (removal / rename /
              # optional→required is forbidden). The EmitBridge / Writer / Reader
              # carry-through of these fields (`durable_record/1` AND
              # `map_event/3`, plus the Reader decode) is **U11-I implementation
              # work** — this enabler grows the struct only so the U11-R red
              # suite compiles against the frozen shape.
              scope: :session,
              provenance: %{source: :primary, trust: :trusted},
              actor: nil,
              # The speculation branch this record belongs to (freeze §1.1).
              # Optional-with-default "main"; a non-default branch is written to
              # (and now read back from) the journal, "main" stays implicit on the
              # wire (grandfather-safe, byte-identical for default records — I2).
              branch_id: "main"

    @typedoc "FI-5 provenance — grow-only; later keys (e.g. :model_family) are additive."
    @type provenance :: %{
            required(:source) => atom(),
            required(:trust) => :trusted | :tainted
          }

    @typedoc "Who emitted the event; absent (`nil`) folds as `%{kind: :system}` by rule."
    @type actor :: %{kind: :human | :agent | :system, id: String.t()} | nil

    @type t :: %__MODULE__{
            v: non_neg_integer(),
            id: non_neg_integer(),
            session_id: String.t(),
            turn_id: String.t() | nil,
            ts: integer(),
            family: :loop | :meta,
            type: atom(),
            tier: :ephemeral | :durable,
            payload: map(),
            scope: :session | :global | atom(),
            provenance: provenance(),
            actor: actor(),
            branch_id: String.t()
          }
  end

  @doc """
  Encode an event as a JSON line (newline-terminated) for wire surfaces
  (the CLI's stderr event feed, SSE bodies). Decoding arrives with the
  command channel; v0 is emit-only.
  """
  @spec encode_line(Event.t()) :: iodata()
  def encode_line(%Event{} = event) do
    [Jason.encode!(sanitize(event)), "\n"]
  end

  @doc """
  Coerce a payload map into a JSON-encodable one.

  Same boundary sanitization `encode_line/1` applies, exposed for the durable
  journal sink: an event whose payload carries non-encodable terms (message
  tuples, structs, pids) must not crash `Jason.encode!` when appended. Anything
  Jason can't take becomes `inspect/1` text.
  """
  @spec sanitize_payload(map()) :: map()
  def sanitize_payload(payload) when is_map(payload),
    do: sanitize_value(payload)

  # Payloads may carry non-JSON-encodable terms (error reasons, tuples,
  # arbitrary tool results). Sanitize at the boundary rather than crash
  # the feed: anything Jason can't take becomes `inspect/1` text.
  defp sanitize(%Event{payload: payload} = event) do
    %{event | payload: sanitize_value(payload)}
  end

  defp sanitize_value(%_struct{} = struct),
    do: struct |> Map.from_struct() |> sanitize_value()

  defp sanitize_value(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {sanitize_key(k), sanitize_value(v)} end)
  end

  defp sanitize_value(list) when is_list(list) do
    if List.improper?(list) do
      inspect(list)
    else
      Enum.map(list, &sanitize_value/1)
    end
  end

  defp sanitize_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or
              is_atom(value),
       do: value

  defp sanitize_value(other), do: inspect(other)

  defp sanitize_key(key) when is_atom(key) or is_binary(key), do: key
  defp sanitize_key(key), do: inspect(key)

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
        acc = close_reasoning_item(session_id, turn_id, counter, acc)
        acc = close_message_item(session_id, turn_id, counter, acc)

        complete_item(session_id, turn_id, counter, acc, :tool_use, %{
          name: name,
          arguments: Map.get(tool_use, :arguments, %{}),
          call_id: Map.get(tool_use, :id)
        })

      {:tool_result, %{name: name} = tool_result} ->
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
        ev =
          emit_event(
            session_id,
            turn_id,
            counter,
            :approval_requested,
            :durable,
            payload
          )

        %{acc | journal: acc.journal ++ [ev]}

      {:approval_decided, payload} when is_map(payload) ->
        ev =
          emit_event(
            session_id,
            turn_id,
            counter,
            :approval_decided,
            :durable,
            payload
          )

        %{acc | journal: acc.journal ++ [ev]}

      # The honesty marker: a tool call the model made that produced no
      # receipt. A claim of action with zero receipts is NEVER silent — it
      # seals a visible ⚠ message item into the transcript (full item
      # lifecycle, like every other completed item).
      {:tool_unexecuted, payload} when is_map(payload) ->
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
          emit_event(session_id, turn_id, counter, :turn_completed, :durable, %{
            iteration: Map.get(info, :iteration, 0),
            usage: Map.get(info, :usage, %{}),
            final: false
          })

        %{acc | journal: acc.journal ++ [ev]}

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

              acc.journal ++ [message_ev]
          end

        refs = DoneGate.evidence_refs(journal, turn_id)

        final_ev =
          emit_event(
            session_id,
            turn_id,
            counter,
            :turn_completed,
            :durable,
            gated_done_payload(journal, turn_id, refs, info)
          )

        %{
          acc
          | result: {:ok, %{content: content, usage: Map.get(info, :usage, %{})}},
            journal: journal ++ [final_ev]
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

        %{acc | journal: acc.journal ++ [error_ev], result: {:error, reason}}

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

      %{acc | journal: acc.journal ++ [started_ev], msg_item: item_id}
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

    %{acc | journal: acc.journal ++ [ev], msg_item: nil, msg_chunks: []}
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

      %{acc | journal: acc.journal ++ [started_ev], reasoning_item: item_id}
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
      | journal: acc.journal ++ [ev],
        reasoning_item: nil,
        reasoning_chunks: []
    }
  end

  defp blank?(text), do: String.trim(text) == ""

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

      {item_id, %{acc | journal: acc.journal ++ [ev]}}
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

    %{acc | journal: acc.journal ++ [started_ev, completed_ev]}
  end

  # Consult the evidence gate on the real done path in observe-only mode (see
  # DoneGate's "Wiring status"). Completion stays fail-open: the turn always
  # closes with `final: true`, carrying its accepted `refs` when the gate
  # accepts, and emitting a telemetry signal for a non-accepting verdict so the
  # boundary is measurable without blocking every done on a v0 journal.
  defp gated_done_payload(journal, turn_id, refs, info) do
    base = %{usage: Map.get(info, :usage, %{}), final: true}

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
  # never be handed to `sanitize_payload/1` to `inspect/1`-stringify (that
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

  @doc """
  Decode a `turn_completed{final: true}` payload's evidence status.

  Tolerant of both atom- and string-keyed payloads and both atom- and
  string-valued enums (live in-memory events vs. journal-replayed JSON —
  same convention as `Raxol.Agent.DoneGate`'s accessors).

  Implements the grandfather rule for records written before this marker
  existed (see moduledoc): an `evidence` key present is authoritative and
  wins outright. A legacy record (key absent) with `refs` present
  grandfathers to `:accepted` — the `refs` carrier never lied about
  acceptance. A legacy record with **neither** key present is genuinely
  `:unknown`: before this marker, a rejected done and a never-offered done
  were wire-identical, so there is no way to tell them apart after the
  fact. This case must NEVER decode as `:absent` — that would launder a
  historical rejection into a false "never offered" claim.

  Totality (S1): the decoder never crashes. An `evidence` value it does not
  recognize — a future grow-only enum value, a forged string, a garbage type —
  degrades to `:unknown` (fail-safe, never `:accepted`); see
  `normalize_evidence/1`. The decode is quaternary — `:accepted | :rejected |
  :absent | :unknown` — even though the wire enum a producer stamps is
  tri-state; `:unknown` is the decode-only bucket for legacy/unrecognized
  records, so a consumer's `case` over this must handle four outcomes.

  Trust: this reports the stamped enum, it does not re-derive the verdict from
  the journal — see the "Trust boundary" section in the moduledoc for what that
  does and does not defend (S2).
  """
  @spec evidence_status(map()) :: :accepted | :rejected | :absent | :unknown
  def evidence_status(payload) when is_map(payload) do
    case fetch_either(payload, :evidence) do
      {:ok, value} ->
        normalize_evidence(value)

      :error ->
        case fetch_either(payload, :refs) do
          {:ok, _refs} -> :accepted
          :error -> :unknown
        end
    end
  end

  defp normalize_evidence(value) when value in [:accepted, "accepted"], do: :accepted
  defp normalize_evidence(value) when value in [:rejected, "rejected"], do: :rejected
  defp normalize_evidence(value) when value in [:absent, "absent"], do: :absent

  # Total fallthrough. The `evidence` enum is grow-only (upcast-on-read): a
  # reader on 1.1.0 WILL meet a future 1.2.0 journal carrying
  # a 4th value — exactly the grow-forward case the enum promises — and must
  # degrade, not `FunctionClauseError` on the replay surface. A corrupt or
  # forged line (`evidence: "bogus"`, a number, nil) lands here too. Every
  # unrecognized value fails safe to `:unknown` — never `:accepted` — the same
  # safe direction the grandfather rule already takes absence: an authoritative
  # marker that cannot be understood is treated as "cannot vouch", never as
  # proven-done. This also means a forged non-legacy line whose bogus `evidence`
  # value sits atop a `refs` list decodes `:unknown` (the key is present, so the
  # refs-grandfather arm is never consulted), not laundered to `:accepted`.
  defp normalize_evidence(_), do: :unknown

  defp fetch_either(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
  end

  # A tool result whose payload carries a before/after image of a file
  # (write_file / edit_file) is flattened so the surface renders it as a
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
    preview = entries |> Enum.take(20) |> Enum.map_join(", ", &to_string/1)
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
