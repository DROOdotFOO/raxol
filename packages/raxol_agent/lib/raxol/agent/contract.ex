defmodule Raxol.Agent.Contract do
  @moduledoc """
  Harness contract v0 — the typed event contract between the agent core and
  any surface (CLI, TUI, LiveView, remote).

  This is the minimal loop-family slice of the contract in
  `docs/proposals/in-flight/harness-spec-protocol.md`: every observable step
  of an agent run becomes a `Raxol.Agent.Contract.Event` and is published
  through `Raxol.Agent.SessionStreamer`. Surfaces subscribe to the streamer
  and render; they never reach into the loop.

  (Distinct from `Raxol.Agent.Protocol`, which is agent-to-agent cockpit
  messaging — this module is the core↔surface boundary.)

  ## v0 vocabulary (family `:loop` only)

    * `:turn_started`   — a prompt was accepted; payload `%{prompt}`
    * `:item_delta`     — streaming text chunk; payload `%{chunk}`;
      the one **ephemeral** event (live render only, never for replay)
    * `:item_completed` — a finished item; payload
      `%{item_type: :message | :tool_use | :tool_result, ...}`
    * `:turn_completed` — a turn boundary; payload
      `%{usage, iteration, final}` (`final: true` closes the run)
    * `:error`          — fault; payload `%{reason}`

  The meta family (probe swarm), `steer`/`approval` commands, and the
  durable journal sink attach behind this same boundary in later steps —
  producers change, the contract does not.

  ## U21 evidence tri-state wire marker (#619 residual)

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
  1.0.0 -> 1.1.0 (`Raxol.Agent.Journal.FileStore.Writer`, additive per AD-11
  upcast-on-read) alongside this payload growth; the pinned `v1.0.0` golden
  corpus stays literal "1.0.0" and unrewritten (an old journal's records are
  never rewritten in place, only decoded — covered by the grandfather rule
  above).

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
              # --- U11 envelope growth (harness-freeze-contracts.md §2.1) -----
              # All defaulted; every landed v0 event and every journal record
              # without these keys decodes to these values — the grandfather
              # clause. The I9 "contract only grows" rule is honored: new fields
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

    # The accumulator carries the run result plus the durable journal emitted
    # so far this turn, so the done site can consult DoneGate.gate/3 over the
    # real journal (ephemeral `item_delta`s are never journaled).
    {result, _journal} =
      Enum.reduce(stream, {{:error, :no_result}, [started]}, fn stream_event, acc ->
        handle_stream_event(session_id, turn_id, counter, stream_event, acc)
      end)

    result
  end

  defp handle_stream_event(session_id, turn_id, counter, event, {result, journal}) do
    case event do
      {:text_delta, chunk} ->
        emit_event(session_id, turn_id, counter, :item_delta, :ephemeral, %{
          chunk: chunk
        })

        {result, journal}

      {:tool_use, %{name: name} = tool_use} ->
        ev =
          emit_event(session_id, turn_id, counter, :item_completed, :durable, %{
            item_type: :tool_use,
            name: name,
            arguments: Map.get(tool_use, :arguments, %{}),
            call_id: Map.get(tool_use, :id)
          })

        {result, journal ++ [ev]}

      {:tool_result, %{name: name} = tool_result} ->
        ev =
          emit_event(session_id, turn_id, counter, :item_completed, :durable, %{
            item_type: :tool_result,
            name: name,
            result: Map.get(tool_result, :result)
          })

        {result, journal ++ [ev]}

      {:turn_complete, info} ->
        ev =
          emit_event(session_id, turn_id, counter, :turn_completed, :durable, %{
            iteration: Map.get(info, :iteration, 0),
            usage: Map.get(info, :usage, %{}),
            final: false
          })

        {result, journal ++ [ev]}

      {:done, %{content: content} = info} ->
        message_ev =
          emit_event(session_id, turn_id, counter, :item_completed, :durable, %{
            item_type: :message,
            content: content
          })

        journal = journal ++ [message_ev]
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

        {{:ok, %{content: content, usage: Map.get(info, :usage, %{})}}, journal ++ [final_ev]}

      {:error, reason} ->
        emit_event(session_id, turn_id, counter, :error, :durable, %{
          reason: reason
        })

        {{:error, reason}, journal}

      _other ->
        {result, journal}
    end
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

  defp fetch_either(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
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
