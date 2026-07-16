defmodule Raxol.Agent.Red.SteerContours do
  @moduledoc """
  The U6 steer contract, as executable contours — the single source of truth
  both the red suite and the negative controls run.

  Each `assert_*/1` takes an implementation module (the `Raxol.Agent.Steer`
  behaviour) and asserts one frozen property. Running a contour against:

    * `Raxol.Agent.Steer` (the real skeleton) → raises `:not_implemented` → the
      **red** fails (it is a permanent failing-first test until U6 lands);
    * `Raxol.Agent.Red.SteerReference` (correct oracle) → **passes** (the contour
      is not vacuous);
    * a `Raxol.Agent.Red.SteerInjectors` dead injector → **fails** with an
      `ExUnit.AssertionError` (the contour catches the specific breakage).

  Sharing one checker across reds and controls is what makes "this dead injector
  fails this red" airtight — the control runs the identical assertion the red
  runs, never a paraphrase that could drift.

  Frozen shapes (AD-13 + freeze-contracts §5.1):

    * accept          → `{:ok, {:accepted, %{turn_id, offset, client_msg_id}}}`
    * duplicate       → `{:ok, {:duplicate, ref}}` (ref == the original accept)
    * stale           → `{:error, {:stale_turn, expected, actual}}`
    * no live turn    → `{:error, :no_live_turn}`
    * cmid reuse      → `{:error, :client_msg_id_reuse}` (same cmid, different payload)

  ## A note on `assert_serialized_cas_order/2` (was `assert_one_winner/2`)

  This checker drives two steer requests through `impl.resolve/2` via a plain
  `Enum.map_reduce/3` in a seed-chosen order — it is a **pure sequential CAS
  ordering** property, NOT a test of concurrent execution. It proves the CAS
  semantics are order-independent (whichever request resolves first wins,
  deterministically, for any schedule), which is exactly what a running turn's
  real mailbox reduces genuinely concurrent callers to. What this checker does
  NOT cover: an actual read-then-write race inside the session runtime's
  process (two callers observing the same `state.turn_id` before either
  resolves). That runtime-level race is a SEPARATE, currently-uncovered
  obligation belonging to U6-I (the implementation unit), not this red suite.
  """

  import ExUnit.Assertions

  alias Raxol.Agent.Steer.{Request, TurnState}

  @target "turn-A"
  @other "turn-B"

  @doc "A fresh single-turn steer state whose running turn is `turn_id`."
  @spec initial(term()) :: TurnState.t()
  def initial(turn_id \\ @target), do: %TurnState{turn_id: turn_id, seen: %{}, log: []}

  @doc """
  POSITIVE: a steer whose `expected_turn_id` matches the running turn LANDS — a
  durable event attributed to the target turn, carrying the steering text and
  the client message id.
  """
  def assert_lands(impl) do
    state = initial(@target)
    req = %Request{expected_turn_id: @target, client_msg_id: "m-land", text: "go left"}

    {result, next} = impl.resolve(state, req)

    assert {:ok, {:accepted, ref}} = result,
           "steer with a matching expected_turn_id must be accepted, got: #{inspect(result)}"

    assert ref.turn_id == @target,
           "accepted steer must be attributed to the target turn #{inspect(@target)}, got: #{inspect(ref.turn_id)}"

    assert length(next.log) == 1,
           "exactly one durable steer event must land, got #{length(next.log)}"

    event = hd(next.log)
    assert event.tier == :durable, "the steer event must be durable"
    assert event.turn_id == @target, "the durable event must be attributed to the target turn"

    # Frozen event shape (§1 + §5.1): the steering text and client_msg_id are
    # nested in `payload` — the same place they land on disk — not at the top
    # level. This pins the durable layout, not the accept OUTCOME (the returned
    # `ref` still carries client_msg_id at its top level, asserted above).
    assert event.payload.text == "go left",
           "the durable event's payload must carry the steering text"

    assert event.payload.client_msg_id == "m-land",
           "the durable event's payload must carry the client_msg_id"
  end

  @doc """
  POSITIVE: a steer whose `expected_turn_id` is stale (the running turn differs)
  is rejected with the typed `{:error, {:stale_turn, expected, actual}}` — no
  silent misdirection into the wrong turn.
  """
  def assert_stale_reject(impl) do
    state = initial(@other)
    req = %Request{expected_turn_id: @target, client_msg_id: "m-stale", text: "too late"}

    {result, _next} = impl.resolve(state, req)

    assert result == {:error, {:stale_turn, @target, @other}},
           "a stale steer must reject with {:error, {:stale_turn, #{inspect(@target)}, #{inspect(@other)}}}, got: #{inspect(result)}"
  end

  @doc """
  POSITIVE: a rejected steer journals NOTHING and has zero model effect — the
  returned state is byte-for-byte the input state (no phantom durable event, no
  token swap, no dedup memory).
  """
  def assert_nothing_on_reject(impl) do
    state = initial(@other)
    req = %Request{expected_turn_id: @target, client_msg_id: "m-noop", text: "too late"}

    {result, next} = impl.resolve(state, req)

    assert {:error, {:stale_turn, _, _}} = result,
           "precondition: the steer must be rejected, got: #{inspect(result)}"

    assert next.log == state.log,
           "a reject must journal nothing — log changed from #{inspect(state.log)} to #{inspect(next.log)}"

    assert next == state,
           "a reject must have zero model effect — state changed:\n  before: #{inspect(state)}\n  after:  #{inspect(next)}"
  end

  @doc """
  POSITIVE: two steers built against the same observed turn, resolved in a
  seed-determined SERIAL order, land so that EXACTLY ONE wins the CAS and the
  other gets a typed stale reject. This is a serialized-CAS-ordering property
  (a sequential `Enum.map_reduce`, see moduledoc) — it stands in for what a
  running turn's real mailbox does to genuinely concurrent callers, but does
  not itself exercise concurrency; the runtime-level race is U6-I's separate
  obligation. The schedule (application order) is chosen from `seed`,
  reproducibly. Returns the winning `client_msg_id`.
  """
  def assert_serialized_cas_order(impl, seed) when is_integer(seed) do
    state = initial(@target)
    r1 = %Request{expected_turn_id: @target, client_msg_id: "m1", text: "steer-1"}
    r2 = %Request{expected_turn_id: @target, client_msg_id: "m2", text: "steer-2"}

    # Seed-reproducible schedule: the two racing steers are serialised in a
    # seed-determined order (the running turn's mailbox serialises them for real).
    order = if rem(seed, 2) == 0, do: [r1, r2], else: [r2, r1]

    {results, _final} =
      Enum.map_reduce(order, state, fn req, s ->
        {res, s2} = impl.resolve(s, req)
        {{req.client_msg_id, res}, s2}
      end)

    accepts = for {cmid, {:ok, {:accepted, _}}} <- results, do: cmid
    stales = for {cmid, {:error, {:stale_turn, _, _}}} <- results, do: cmid

    assert length(accepts) == 1,
           "exactly one racing steer must win the CAS (seed #{seed}); accepts=#{inspect(accepts)} results=#{inspect(results)}"

    assert length(stales) == 1,
           "the losing racing steer must get a typed stale reject (seed #{seed}); stales=#{inspect(stales)} results=#{inspect(results)}"

    hd(accepts)
  end

  @doc """
  The winning `client_msg_id` for a racing-steer schedule seed (no assertions) —
  for the seed-reproducibility control.
  """
  def winner(impl, seed) when is_integer(seed) do
    state = initial(@target)
    r1 = %Request{expected_turn_id: @target, client_msg_id: "m1", text: "steer-1"}
    r2 = %Request{expected_turn_id: @target, client_msg_id: "m2", text: "steer-2"}
    order = if rem(seed, 2) == 0, do: [r1, r2], else: [r2, r1]

    {results, _final} =
      Enum.map_reduce(order, state, fn req, s ->
        {res, s2} = impl.resolve(s, req)
        {{req.client_msg_id, res}, s2}
      end)

    case for {cmid, {:ok, {:accepted, _}}} <- results, do: cmid do
      [cmid] -> cmid
      other -> other
    end
  end

  @doc """
  POSITIVE: a duplicate delivery of the same `client_msg_id` is deduplicated —
  the second delivery is acked as `{:ok, {:duplicate, ref}}` referencing the
  ORIGINAL accept, and produces NO second durable event (one turn, not two;
  §5.1 mobile-retry idempotency).
  """
  def assert_dedup(impl) do
    state = initial(@target)
    req = %Request{expected_turn_id: @target, client_msg_id: "m-dup", text: "once"}

    {first, after_first} = impl.resolve(state, req)

    assert {:ok, {:accepted, ref}} = first,
           "precondition: the first delivery must be accepted, got: #{inspect(first)}"

    assert length(after_first.log) == 1,
           "precondition: the first delivery must land one durable event"

    # Re-deliver the IDENTICAL command (same expected_turn_id + client_msg_id).
    {second, after_second} = impl.resolve(after_first, req)

    assert second == {:ok, {:duplicate, ref}},
           "a duplicate client_msg_id must be acked as {:ok, {:duplicate, ref}} referencing the original accept, got: #{inspect(second)}"

    assert length(after_second.log) == 1,
           "a duplicate must NOT append a second durable event — log grew to #{length(after_second.log)}"
  end

  @doc """
  POSITIVE (§5.1, the load-bearing case): idempotency survives a BEAM restart.

  The journal is the dedup truth and the dedup window is the SESSION LIFETIME, so
  the in-memory dedup index is rebuilt by FOLD over the durable journal
  (`rebuild/1`), not held only in process memory. A `client_msg_id` re-delivered
  after a restart still deduplicates — even though a different turn is running by
  then (dedup is checked before the CAS). Nothing new is journaled.
  """
  def assert_dedup_survives_restart(impl) do
    state = initial(@target)
    req = %Request{expected_turn_id: @target, client_msg_id: "m-restart", text: "once"}

    {first, after_first} = impl.resolve(state, req)

    assert {:ok, {:accepted, ref}} = first,
           "precondition: the first delivery must be accepted, got: #{inspect(first)}"

    assert length(after_first.log) == 1,
           "precondition: the first delivery must land one durable event"

    # Simulate the BEAM going away and coming back: the durable journal survives,
    # and the dedup index must be REBUILT FROM IT (not from lost process memory).
    # By the time the retry arrives a different turn is running — dedup must still
    # fire, because it is checked before the CAS.
    restarted = %{impl.rebuild(after_first.log) | turn_id: @other}

    assert restarted.log == after_first.log,
           "rebuild must preserve the durable journal, got: #{inspect(restarted.log)}"

    {second, after_second} = impl.resolve(restarted, req)

    assert second == {:ok, {:duplicate, ref}},
           "a client_msg_id re-delivered after restart must STILL deduplicate to the original accept (index rebuilt by journal fold, §5.1), got: #{inspect(second)}"

    assert length(after_second.log) == length(after_first.log),
           "a post-restart duplicate must NOT append a second durable event — log grew from #{length(after_first.log)} to #{length(after_second.log)}"
  end

  @doc """
  POSITIVE (AD-13, the ABA hazard): the CAS token issued after every accept is
  DISTINCT FROM EVERY PREVIOUSLY OBSERVED TOKEN in the turn's history, not
  merely different from the immediately-current one. Drives three consecutive
  accepts (each against the turn's own just-returned token) and asserts the
  full sequence of four observed tokens (initial + after each accept) contains
  no repeats — a token space that cycles back to an earlier value (a boolean
  toggle, a repeatable counter) would fail this even though every individual
  `swap(cur) != cur` check trivially passes.
  """
  def assert_token_uniqueness(impl) do
    state = initial(@target)

    {r1, s1} =
      impl.resolve(state, %Request{
        expected_turn_id: @target,
        client_msg_id: "m-aba-1",
        text: "one"
      })

    assert {:ok, {:accepted, _}} = r1,
           "precondition: the first steer must be accepted, got: #{inspect(r1)}"

    {r2, s2} =
      impl.resolve(s1, %Request{
        expected_turn_id: s1.turn_id,
        client_msg_id: "m-aba-2",
        text: "two"
      })

    assert {:ok, {:accepted, _}} = r2,
           "precondition: the second steer (against the freshly swapped token) must be accepted, got: #{inspect(r2)}"

    {r3, s3} =
      impl.resolve(s2, %Request{
        expected_turn_id: s2.turn_id,
        client_msg_id: "m-aba-3",
        text: "three"
      })

    assert {:ok, {:accepted, _}} = r3,
           "precondition: the third steer (against the freshly swapped token) must be accepted, got: #{inspect(r3)}"

    tokens = [state.turn_id, s1.turn_id, s2.turn_id, s3.turn_id]

    assert length(Enum.uniq(tokens)) == length(tokens),
           "every post-accept CAS token must be distinct from every previously observed token " <>
             "(ABA hazard, AD-13) — observed tokens: #{inspect(tokens)}"
  end

  @doc """
  NEGATIVE: a steer against a session with NO running turn (`state.turn_id ==
  nil`) is REJECTED with `{:error, :no_live_turn}`, regardless of what
  `expected_turn_id` the request carries — a `nil == nil` "match" must never
  read as a real CAS accept, which would land a durable steer event on a
  nonexistent turn. Zero model effect: state is unchanged.
  """
  def assert_no_live_turn_reject(impl) do
    state = %TurnState{turn_id: nil, seen: %{}, log: []}
    req = %Request{expected_turn_id: nil, client_msg_id: "m-idle", text: "hello?"}

    {result, next} = impl.resolve(state, req)

    assert result == {:error, :no_live_turn},
           "a steer against a session with no running turn must reject {:error, :no_live_turn}, got: #{inspect(result)}"

    assert next == state,
           "a no-live-turn reject must have zero model effect — state changed:\n  before: #{inspect(state)}\n  after:  #{inspect(next)}"
  end

  @doc """
  NEGATIVE (§5.1, the suppression vector): a `client_msg_id` re-delivered with
  a DIFFERENT payload (`text`) than its original accept is NEVER treated as a
  duplicate — it is REJECTED with `{:error, :client_msg_id_reuse}`. A reused
  idempotency key carrying new content is a client bug or an attempt to
  silently suppress new steering text under an old key; the original accept is
  left untouched (zero model effect, nothing newly journaled).
  """
  def assert_dedup_payload_mismatch_rejected(impl) do
    state = initial(@target)
    req1 = %Request{expected_turn_id: @target, client_msg_id: "m-mismatch", text: "go left"}
    {first, after_first} = impl.resolve(state, req1)

    assert {:ok, {:accepted, _ref}} = first,
           "precondition: the first delivery must be accepted, got: #{inspect(first)}"

    req2 = %Request{
      expected_turn_id: @target,
      client_msg_id: "m-mismatch",
      text: "go RIGHT instead"
    }

    {second, after_second} = impl.resolve(after_first, req2)

    assert second == {:error, :client_msg_id_reuse},
           "a re-delivered client_msg_id carrying a DIFFERENT payload must reject {:error, :client_msg_id_reuse} " <>
             "(a reused cmid with new content is a client bug/attack, never a duplicate), got: #{inspect(second)}"

    assert after_second == after_first,
           "a client_msg_id_reuse reject must have zero model effect — state changed:\n  before: #{inspect(after_first)}\n  after:  #{inspect(after_second)}"
  end

  @doc """
  POSITIVE: two steers each carrying a `nil` `client_msg_id` are NEVER deduped
  against each other — `nil` is not a memoised idempotency key (there is no
  client-supplied key to dedup on), so both land as distinct durable events.
  Pins the current correct behavior against a future regression that treats
  `nil` as an ordinary (colliding) dedup key.
  """
  def assert_nil_client_msg_id_not_deduped(impl) do
    state = initial(@target)
    req1 = %Request{expected_turn_id: @target, client_msg_id: nil, text: "first, no id"}
    {first, after_first} = impl.resolve(state, req1)

    assert {:ok, {:accepted, ref1}} = first,
           "precondition: a nil client_msg_id steer must still be accepted, got: #{inspect(first)}"

    req2 = %Request{
      expected_turn_id: after_first.turn_id,
      client_msg_id: nil,
      text: "second, no id"
    }

    {second, after_second} = impl.resolve(after_first, req2)

    assert {:ok, {:accepted, ref2}} = second,
           "a SECOND nil client_msg_id steer against the (now current) turn must ALSO be accepted " <>
             "— nil is never memoised for dedup, got: #{inspect(second)}"

    assert ref1.offset != ref2.offset,
           "two nil-client_msg_id steers must land as two DISTINCT durable events, got the same ref: #{inspect(ref1)}"

    assert length(after_second.log) == 2,
           "two nil-client_msg_id steers must both journal (no dedup on nil), got #{length(after_second.log)} events"
  end
end
