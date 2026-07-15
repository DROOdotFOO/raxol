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

    * accept    → `{:ok, {:accepted, %{turn_id, offset, client_msg_id}}}`
    * duplicate → `{:ok, {:duplicate, ref}}` (ref == the original accept)
    * stale     → `{:error, {:stale_turn, expected, actual}}`
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
    assert event.text == "go left", "the durable event must carry the steering text"
    assert event.client_msg_id == "m-land", "the durable event must carry the client_msg_id"
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
  POSITIVE: two concurrent steers built against the same observed turn resolve so
  that EXACTLY ONE wins the CAS and the other gets a typed stale reject. The
  schedule (application order) is chosen from `seed`, reproducibly. Returns the
  winning `client_msg_id`.
  """
  def assert_one_winner(impl, seed) when is_integer(seed) do
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
end
