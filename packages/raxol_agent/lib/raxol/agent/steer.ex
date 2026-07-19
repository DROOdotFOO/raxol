defmodule Raxol.Agent.Steer do
  @moduledoc """
  U6 — Steer: redirect a running turn with new user input WITHOUT killing it.

  Steer is the sibling of interrupt (U5): interrupt is *kill now*, steer is
  *inject at the next boundary*. The two are distinct signals (protocol §4;
  AD-2). This module owns the **decision core** of steer: the pure
  `expected_turn_id` CAS *decision* (AD-13) plus the `client_msg_id`
  idempotency check (freeze-contracts §5.1). Everything else — finding the live
  turn process, writing the durable event, letting the model see the steering
  text at the next boundary — is the session runtime's job; it drives this pure
  function.

  ## Not an atomic CAS — the caller's serialization obligation

  `resolve/2` is a **pure decision function**, not an atomic compare-and-swap:
  the "compare" (`expected != turn_id`) and the "swap" (issuing the next token)
  are a read and a return on the caller-supplied struct. **This module provides
  no atomicity.** The concurrent-steer guarantee holds only if the runtime
  serializes read-modify-write:

    * exactly ONE owner process holds the authoritative `TurnState` (the
      running turn's session process);
    * each steer is resolved AND its returned `next_state` installed within a
      single message handling of that process (its mailbox is the serializer);
    * a fetch → `resolve/2` → store cycle through shared storage (ETS, an
      Agent, a DB row) from more than one process is UNSOUND: two callers can
      observe the same `turn_id`, both pass the decision, and land two steer
      events in one turn — the exact misdirection this seam exists to prevent.

  That runtime read-modify-write atomicity is a SEPARATE, currently-unshipped
  obligation belonging to the session-runtime integration: the single-writer
  seam is `Agent.Session`'s turn process, which must own the
  `TurnState` and call `resolve/2` from its own `handle_*` only. See also
  `Raxol.Agent.Red.SteerContours` (its serialized-CAS checker documents the
  same boundary).

  ## The steer decision (the frozen seam)

  A steer command carries the `turn_id` it believes is running. `resolve/2` is
  the pure decision:

    * **Accept** — `request.expected_turn_id == state.turn_id`, AND a turn is
      actually running (`state.turn_id != nil`). A durable steer event is
      appended to the target turn (correct attribution), the CAS token is
      swapped forward, and the `client_msg_id` is memoised for idempotency.
      Returns `{:ok, {:accepted, ref}}`.
    * **Stale reject** — `request.expected_turn_id != state.turn_id` (the turn
      already ended, or another steer won the race). Returns
      `{:error, {:stale_turn, expected, actual}}`. **Nothing is journaled and
      the state is unchanged** — no silent misdirection of input into the wrong
      turn (zero model effect).
    * **No-live-turn reject** — `state.turn_id == nil` (an idle session with no
      running turn), regardless of what `expected_turn_id` the request carries.
      Returns `{:error, :no_live_turn}`, state unchanged. This is a DISTINCT
      case from stale reject, checked before the general CAS comparison: `nil
      == nil` must never read as "the CAS matched" — a steer landing on a
      nonexistent turn is the same silent-misdirection hazard the CAS exists to
      prevent, just at the boundary instead of mid-race.
    * **Duplicate** — the same `(session, client_msg_id)` re-delivered with the
      SAME payload (mobile retry over a flaky wire, §5.1). Returns
      `{:ok, {:duplicate, ref}}` referencing the ORIGINAL accept — one durable
      event, never a second turn.
    * **`client_msg_id` reuse reject** — the same `(session, client_msg_id)`
      re-delivered with a DIFFERENT payload (different `text`). This is never
      treated as a duplicate: a reused idempotency key carrying new content is
      a client bug or an attacker attempting to suppress new steering text
      under an old key. Returns `{:error, :client_msg_id_reuse}`, state
      unchanged — nothing is journaled, and the ORIGINAL accept is left
      untouched.

  ## CAS token uniqueness (ABA-safety)

  The token issued after every accept MUST be distinct from every previously
  observed token in that turn's history, not merely different from the current
  one — a cycling token space (boolean toggle, repeatable counter) would let a
  steer built against a stale earlier token wrongly pass once the token cycles
  back. `swap/1` satisfies this with `System.unique_integer/1` (unique within a
  BEAM run). Run-scoped uniqueness suffices because swap tokens are never
  persisted as CAS targets across restarts: `rebuild/1` sets `turn_id: nil` and
  on resume the `turn_id` comes from the journal's turn brackets. Corollary:
  implementers MUST NOT persist a swap token as a client-visible turn id — and
  structurally cannot journal one, since the token is a tuple, which the Jason
  FileStore Writer refuses to encode (pinned by the review-regression suite).

  ## Idempotency is journal-truth, not process memory (§5.1)

  The dedup window is the **session lifetime** (frozen, §5.1) and the **journal
  is the dedup truth**: an accepted steer records its `client_msg_id` in the
  durable event's payload, and the in-memory dedup index is REBUILT BY FOLD
  over the journal on restart/replay (`rebuild/1`). So a `client_msg_id`
  re-delivered after a BEAM restart still deduplicates — process-local dedup
  state that is lost on restart is a bug, not a shortcut. A duplicate is a live
  ack referencing the original; nothing new is journaled for it.

  Resource shape of the index: one entry per ACCEPTED steer — rejected requests
  never touch it — and each entry is CONSTANT-SIZE: the payload-match check
  keeps a SHA-256 fingerprint of the steering text, never the text itself, so a
  client cannot grow resident memory by the byte-size of what it sends. The
  index therefore grows 1:1 with durable journal appends; bounding THAT (ingest
  quota / backpressure on accepted steers) is the session runtime's concern.
  Evicting entries any earlier than session end would break the frozen §5.1
  window (a replayed `client_msg_id` past eviction would journal a second
  durable event).

  ## Contract references

  Section marks like "§5.1" refer to the frozen harness contract, described in
  `docs/harness/architecture.md`. "AD-13" is the ratified architecture decision
  for the steer CAS seam in the same document set. The session runtime is what
  integrates this decision core end to end (see "Not an atomic CAS" above).

  ## Status

  **Implemented (U6).** `resolve/2` and `rebuild/1` land the decision core
  above; the permanent suite in `test/raxol/agent/red/u6_steer_red_test.exs` —
  authored against this frozen shape — now runs GREEN in CI (the
  `@moduletag :harness_red` exclusion was dropped once the impl satisfied every
  contour). The negative controls (dead-injector detection) continue to run in
  CI against the reference oracle and injectors.
  """

  defmodule Request do
    @moduledoc """
    A steer request: the steering text, the CAS token the caller believes is
    running (`expected_turn_id`), and the client-supplied idempotency key
    (`client_msg_id`, §5.1 — generated client-side, never offset-derived).
    """

    @enforce_keys [:expected_turn_id]
    defstruct [:text, :expected_turn_id, :client_msg_id]

    @type t :: %__MODULE__{
            text: String.t() | nil,
            expected_turn_id: term(),
            client_msg_id: term() | nil
          }
  end

  defmodule TurnState do
    @moduledoc """
    The steer-relevant slice of a running turn's state, threaded through
    `Raxol.Agent.Steer.resolve/2`. The session runtime owns the authoritative
    copy (single writer, see the `Raxol.Agent.Steer` moduledoc).

      * `turn_id` — the current CAS token (the running turn).
      * `seen`    — idempotency index: `client_msg_id => %{ref, fingerprint}`.
        Constant-size per entry (payload fingerprint, never the text).
      * `log`     — the durable steer events this decision core has accepted,
        NEWEST FIRST (prepend; O(1) per accept). After `rebuild/1` the entries
        are journal records as scanned off disk (string-keyed); live accepts
        prepend atom-keyed events — consumers must read entries tolerantly
        (§0 reader-tolerance), never assume one key style.
      * `last_offset` — monotone per-session steer sequence counter; the next
        accept lands at `last_offset + 1`. This is the decision core's OWN
        sequence, NOT the journal Writer's record offset (`id`), which the
        offset law (§1.1) assigns at append time.
    """

    defstruct turn_id: nil, seen: %{}, log: [], last_offset: 0

    @type t :: %__MODULE__{
            turn_id: term(),
            seen: %{optional(term()) => term()},
            log: [map()],
            last_offset: non_neg_integer()
          }
  end

  @typedoc "A reference to an accepted steer — the turn it landed in and its position."
  @type accepted_ref :: %{
          turn_id: term(),
          offset: non_neg_integer(),
          client_msg_id: term() | nil
        }

  @typedoc "The typed outcome of a steer decision."
  @type result ::
          {:ok, {:accepted, accepted_ref()}}
          | {:ok, {:duplicate, accepted_ref()}}
          | {:error, {:stale_turn, term(), term()}}
          | {:error, :no_live_turn}
          | {:error, :client_msg_id_reuse}

  @doc """
  Resolve a steer request against the running turn's steer state.

  Returns `{result, next_state}`. See the moduledoc for the accept / stale-reject
  / duplicate semantics. Deterministic and side-effect-free: the session runtime
  supplies the state and consumes the returned state + result — and MUST do so
  from a single owner process (moduledoc: "Not an atomic CAS").
  """
  @callback resolve(TurnState.t(), Request.t()) :: {result(), TurnState.t()}

  @doc """
  Rebuild the steer dedup state by folding over the durable journal (§5.1).

  The journal is the dedup truth: each accepted steer recorded its
  `client_msg_id` in the durable event payload, so replaying the durable records
  reconstructs the `TurnState.seen` idempotency index. This is what makes a
  `client_msg_id` re-delivered after a BEAM restart still deduplicate — the
  in-memory index is derived from the log, never held only in process memory.

  `journal` is the durable records in offset order (any families; non-steer
  records are ignored).
  """
  @callback rebuild(journal :: [map()]) :: TurnState.t()

  @doc """
  Resolve a steer request (see the `resolve/2` callback).

  Decision order is load-bearing (freeze-contracts §5.1 + AD-13):

    1. **Idempotency first** — a re-delivered `client_msg_id` is resolved against
       the journal-derived dedup index BEFORE the CAS, so a duplicate still
       deduplicates after a restart even when a different turn is running. Same
       payload → `{:ok, {:duplicate, ref}}` (the ORIGINAL accept); different
       payload → `{:error, :client_msg_id_reuse}`. Both leave the state
       unchanged.
    2. **No live turn** — `turn_id == nil` → `{:error, :no_live_turn}`, state
       unchanged. Checked before the CAS so a `nil == nil` request can never be
       read as a real match.
    3. **CAS** — `expected_turn_id != turn_id` → `{:error, {:stale_turn, exp,
       act}}`, state unchanged (nothing journaled, zero model effect).
    4. **Accept** — append one durable steer event to the target turn, swap the
       CAS token forward to a run-unique (ABA-safe) value, memoise the
       `client_msg_id` + payload fingerprint.
  """
  @spec resolve(TurnState.t(), Request.t()) :: {result(), TurnState.t()}
  def resolve(
        %TurnState{turn_id: cur, seen: seen} = state,
        %Request{expected_turn_id: expected, client_msg_id: cmid, text: text}
      ) do
    cond do
      not is_nil(cmid) and Map.has_key?(seen, cmid) ->
        resolve_seen(state, Map.fetch!(seen, cmid), text)

      is_nil(cur) ->
        # No turn is running — a fresh steer has nowhere to land. `expected ==
        # nil` must NOT be read as a CAS match (silent-misdirection guard).
        {{:error, :no_live_turn}, state}

      expected != cur ->
        # Stale — the turn changed (ended, or another steer won the race). No
        # journaling, no token swap: zero model effect.
        {{:error, {:stale_turn, expected, cur}}, state}

      true ->
        accept(state, cmid, text)
    end
  end

  # (1) idempotency — same cmid seen before. The payload MUST match (by
  # fingerprint), or this is a reused key carrying new content (a client
  # bug/attack), never a retry (§5.1).
  defp resolve_seen(state, %{ref: ref, fingerprint: original_fp}, text) do
    if fingerprint(text) == original_fp do
      {{:ok, {:duplicate, ref}}, state}
    else
      {{:error, :client_msg_id_reuse}, state}
    end
  end

  # (4) accept — land a durable event in the TARGET turn, swap the token forward.
  # O(1) per accept: the offset is a monotone counter (never `length(log)`), the
  # event is PREPENDED (never `log ++ [event]`), and the dedup entry keeps a
  # constant-size fingerprint (never the client text).
  defp accept(%TurnState{turn_id: cur, seen: seen, log: log, last_offset: last}, cmid, text) do
    offset = last + 1
    ref = %{turn_id: cur, offset: offset, client_msg_id: cmid}

    # Frozen event shape (freeze-contracts §1 + §5.1): the envelope fields stay
    # at the top level, but the `client_msg_id` and steering `text` live INSIDE
    # `payload` — the same place they land on disk. Keeping the pure model's
    # event byte-aligned with the durable record is what lets `rebuild/1` fold
    # the real journal (§5.1: "carries its client_msg_id in the resulting durable
    # event's payload").
    event = %{
      type: :steer,
      tier: :durable,
      family: :loop,
      turn_id: cur,
      offset: offset,
      payload: %{client_msg_id: cmid, text: text}
    }

    seen2 =
      if is_nil(cmid),
        do: seen,
        else: Map.put(seen, cmid, %{ref: ref, fingerprint: fingerprint(text)})

    next = %TurnState{
      turn_id: swap(cur),
      seen: seen2,
      log: [event | log],
      last_offset: offset
    }

    {{:ok, {:accepted, ref}}, next}
  end

  @doc """
  Rebuild the dedup index from the durable journal (see the `rebuild/1`
  callback).

  The journal is the dedup truth (§5.1): each accepted steer stored its
  `client_msg_id` AND its `text`, so folding the durable steer records back into
  the idempotency index survives a BEAM restart with the payload-mismatch check
  intact (the index keeps the text's fingerprint, not the text). Non-steer
  records are dropped: `TurnState.log` holds STEER events only (newest first),
  and `last_offset` resumes from the highest steer offset found so post-restart
  accepts continue the same monotone sequence. `turn_id` is NOT reconstructed
  here — it comes from the loop's turn brackets on resume; dedup is checked
  before the CAS, so a duplicate is caught regardless of which turn is running
  after the restart.
  """
  @spec rebuild([map()]) :: TurnState.t()
  def rebuild(journal) when is_list(journal) do
    steer_records = Enum.filter(journal, &steer_record?/1)

    seen =
      steer_records
      |> Enum.filter(&(not is_nil(payload_field(&1, :client_msg_id))))
      |> Map.new(fn ev ->
        cmid = payload_field(ev, :client_msg_id)

        ref = %{
          turn_id: payload_field(ev, :turn_id),
          offset: payload_field(ev, :offset) || payload_field(ev, :id),
          client_msg_id: cmid
        }

        {cmid, %{ref: ref, fingerprint: fingerprint(payload_field(ev, :text))}}
      end)

    %TurnState{
      turn_id: nil,
      seen: seen,
      log: Enum.reverse(steer_records),
      last_offset: last_steer_offset(steer_records)
    }
  end

  # The highest steer sequence offset present in the scanned records (0 for
  # none) — the monotone counter resumes above every already-landed steer, so a
  # post-restart accept can never reuse an offset a rebuilt dedup ref holds.
  defp last_steer_offset(steer_records) do
    steer_records
    |> Enum.map(&(payload_field(&1, :offset) || payload_field(&1, :id)))
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  # A durable steer record — whether the atom-keyed in-memory event this module
  # builds, OR the STRING-keyed map the FileStore Reader round-trips off disk
  # (Jason decodes to string keys, `type` becomes "steer"). §0 reader-tolerance:
  # fold both shapes, never depend on one. Feeding rebuild only the in-memory log
  # (as the suite once did) hides the real production seam — the durable record
  # is string-keyed with client_msg_id nested in payload.
  defp steer_record?(ev) do
    case fetch_atom_or_string(ev, :type) do
      {:ok, type} -> type in [:steer, "steer"]
      :error -> false
    end
  end

  # `client_msg_id`/`text` are nested in `payload` (frozen shape, §5.1). Read the
  # field from the payload under either key style; only when the key is ABSENT
  # from the payload (not merely nil-valued) fall back to a top-level value so a
  # legacy flat record still folds (tolerant reader, never strict).
  defp payload_field(ev, key) do
    payload =
      case fetch_atom_or_string(ev, :payload) do
        {:ok, payload} when is_map(payload) -> payload
        _ -> %{}
      end

    with :error <- fetch_atom_or_string(payload, key),
         :error <- fetch_atom_or_string(ev, key) do
      nil
    else
      {:ok, value} -> value
    end
  end

  # Fetch `key` (an atom) from a map that may be atom-keyed (in-memory) or
  # string-keyed (Jason-decoded off disk). `{:ok, value} | :error` — presence,
  # not truthiness, so an explicit `nil` value is distinguishable from absence.
  defp fetch_atom_or_string(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp fetch_atom_or_string(_map, _key), do: :error

  # Constant-size stand-in for the steering text in the dedup index: the §5.1
  # payload-match check needs EQUALITY of the re-delivered text, not the text
  # itself, so the index stores a SHA-256 fingerprint — resident memory per
  # entry stays O(1) no matter how large the client's text is (the durable
  # record still carries the full text; only the index drops it).
  defp fingerprint(nil), do: nil
  defp fingerprint(text) when is_binary(text), do: :crypto.hash(:sha256, text)
  defp fingerprint(other), do: :crypto.hash(:sha256, :erlang.term_to_binary(other))

  # The CAS swap: a fresh token, distinct from every token this turn has held so
  # far (ABA-safety; see the moduledoc). Run-scoped uniqueness is sufficient
  # because swap tokens are never persisted as CAS targets across restarts —
  # and being tuples, they are unencodable by the Jason FileStore Writer, so
  # persisting one fails loudly rather than silently.
  defp swap(cur), do: {:steered, cur, System.unique_integer([:positive])}
end
