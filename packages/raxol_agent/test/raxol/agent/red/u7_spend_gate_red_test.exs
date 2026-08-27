defmodule Raxol.Agent.Red.U7SpendGateRedTest do
  @moduledoc """
  U7-R — permanent failing-first RED suite for the SpendGate reserve-before-call
  law (AD-6a). Authored BEFORE the implementation exists (the red-first fan-out;
  part of the red-first fan-out authored against docs PR #569).

  ## What U7 is

  Every spend-bearing call (an LLM provider call, a paid tool) journals

      reserve → call → settle

  in that order, per call, correlated by an opaque `cost_ref`:

    * **No reserve ⇒ no call, EVER** (fail-closed). A refused reserve means the
      call does not happen and a typed `reserve_refused` record states why.
    * **Settle records actuals**; the refund of `estimate - actual` is internal,
      but the `settle` record is the authoritative post-hoc fact — the refund is
      derivable from the `(reserve, settle)` pair.
    * **The journal fold IS the accounting.** A crash between reserve and call
      leaves the reserve dangling but VISIBLE in the fold (never silently lost) —
      pinned here with a REAL process kill, not just an omitted settle.
    * **Concurrent calls under one budget never over-reserve past the cap** —
      atomic `try_spend` semantics, checked as PEAK concurrent reserved (not a
      cumulative sum), so a legitimate refund-and-reuse gate is not falsely
      flagged.
    * **A cost_ref reserves at most once, and settles at most once** — a
      repeated reserve or a replayed settle (double-refund / money inflation)
      is rejected, not silently accepted.

  These tests drive the real `Raxol.Agent.SpendGate`. U7 has landed, so the
  suite is now GREEN — the `:harness_red` exclusion tag has been removed and it
  runs in CI as the permanent contract.

  ## Mergeability discipline

  Authored failing-first under `@moduletag :harness_red` (excluded in
  `test_helper.exs` so CI stayed green while red); the tag was dropped when the
  U7 implementation turned it green. The negative controls (dead injectors) in
  `U7SpendGateControlsTest` below have always run in CI and prove the checkers
  are not vacuous.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Red.SpendGateProbe, as: P
  alias Raxol.Agent.SpendGate

  # Seed for the concurrent-schedule contour; overridable + dumped on failure
  # (m2). Read at RUNTIME (not a `@seed` module attribute) — a module
  # attribute captures `System.get_env/2` at COMPILE time, so `U7_SEED=...`
  # on an already-compiled module (e.g. `mix test --no-compile`, or a cached
  # `_build`) would silently have no effect.
  defp seed, do: String.to_integer(System.get_env("U7_SEED", "424242"))

  defp ctx(journal, budget),
    do: %{
      emit: P.emit_fun(journal),
      # The frozen context.try_reserve seam (see Raxol.Agent.SpendGate
      # moduledoc) — the real gate reserves through this SAME closure.
      try_reserve: P.try_reserve_fun(budget),
      budget: budget,
      agent_id: :u7_red
    }

  describe "positive contours — the real gate (red until U7 lands)" do
    test "reserve→call→settle, in order, per call (fold asserts; cost_ref correlation)" do
      j = P.new_journal()
      p = P.new_provider()
      ctx = ctx(j, P.new_budget(1000))

      # actual (80) < estimate (100): under-estimate, refund due.
      assert {:ok, {:result, "c1"}} =
               SpendGate.around(ctx, "c1", 100, P.call_fun(p, "c1", 80))

      recs = P.records(j)
      assert P.reserve_before_call(recs) == :ok
      assert P.kinds_for(recs, "c1") == [:reserve, :call, :settle]
      assert P.provider_calls(p) == 1
    end

    test "a refused reserve makes ZERO provider calls and records a typed refusal" do
      j = P.new_journal()
      p = P.new_provider()
      # Cap fits exactly one 100-token call: the second must be refused.
      ctx = ctx(j, P.new_budget(100))

      assert {:ok, _} = SpendGate.around(ctx, "c1", 100, P.call_fun(p, "c1", 100))

      assert {:error, {:reserve_refused, _reason}} =
               SpendGate.around(ctx, "c2", 100, P.call_fun(p, "c2", 100))

      recs = P.records(j)
      assert P.kinds_for(recs, "c1") == [:reserve, :call, :settle]
      # The typed refusal event is present; the call never happened.
      assert P.kinds_for(recs, "c2") == [:reserve_refused]
      assert P.provider_calls(p) == 1
      assert P.fail_closed(recs, P.provider_calls(p), 1) == :ok
    end

    test "settle records the actual; the refund (estimate - actual) is derivable from the pair" do
      j = P.new_journal()
      p = P.new_provider()
      ctx = ctx(j, P.new_budget(1000))

      # actual (70) < estimate (100): under-estimate, refund due.
      assert {:ok, _} = SpendGate.around(ctx, "c1", 100, P.call_fun(p, "c1", 70))

      recs = P.records(j)
      assert %{estimate: 100} = Enum.find(recs, &(&1.kind == :reserve and &1.cost_ref == "c1"))
      assert %{actual: 70} = Enum.find(recs, &(&1.kind == :settle and &1.cost_ref == "c1"))
      # Refund is a derived fact, not a separate record; the settle is authoritative.
      assert P.reserve_before_call(recs) == :ok
    end

    test "a crash between reserve and call leaves the reserve DANGLING but visible in the fold (real process kill)" do
      j = P.new_journal()
      ctx = ctx(j, P.new_budget(1000))
      parent = self()

      # A REAL crash, not just an omitted settle: a separate process reserves,
      # signals that the reserve returned, then is killed with :kill before it
      # can proceed to the call/settle step. The reserve must already be
      # durable (journaled synchronously, inside reserve/3, before it returns)
      # so the journal — a SEPARATE process from the one that died — still
      # shows it: durability survives the crash, and the stranded reserve is
      # visible/reclaimable in the fold, never silently lost.
      {pid, ref} =
        spawn_monitor(fn ->
          _ = SpendGate.reserve(ctx, "c1", 100)
          send(parent, :reserved)
          # Would call the provider next — but the crash happens first.
          Process.sleep(:infinity)
        end)

      assert_receive :reserved, 1_000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      recs = P.records(j)
      assert P.dangling_reserve_visible(recs, "c1") == :ok
      assert P.kinds_for(recs, "c1") == [:reserve]
    end

    test "concurrent calls under one budget never over-reserve past the cap (seed-reproducible)" do
      cap = 300
      est = 100
      n = 10
      expected = div(cap, est)

      j = P.new_journal()
      p = P.new_provider()
      ctx = ctx(j, P.new_budget(cap))

      seed = seed()

      # The BEAM scheduler itself interleaves these `max_concurrency: n` tasks
      # non-deterministically; no artificial jitter is needed to vary the
      # WINNERS run to run — the serialized atomic budget is what makes the
      # COUNT that fits the cap invariant regardless of interleaving. `seed`
      # is still threaded through the failure messages so a red run is
      # reproducible (m2) if a future scheduling-sensitive assertion is added.
      results =
        1..n
        |> Task.async_stream(
          fn i -> SpendGate.around(ctx, "c#{i}", est, P.call_fun(p, "c#{i}", est)) end,
          max_concurrency: n,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      recs = P.records(j)
      ok_count = Enum.count(results, &match?({:ok, _}, &1))

      # actual == estimate here, so no refund frees budget mid-storm: exactly
      # `expected` reservations fit, and the peak reserved never exceeds the cap.
      assert P.reserved_within_cap(recs, cap) == :ok,
             "seed=#{seed}: over-reserved past cap #{cap}; records=#{inspect(recs)}"

      assert ok_count == expected,
             "seed=#{seed}: expected #{expected} successful reserves, got #{ok_count}"

      assert P.provider_calls(p) == expected,
             "seed=#{seed}: provider called #{P.provider_calls(p)}x, expected #{expected}"

      assert P.call_count(recs) == expected, "seed=#{seed}"
    end

    test "reserving the same cost_ref twice is rejected (no double-spend via retry)" do
      j = P.new_journal()
      ctx = ctx(j, P.new_budget(1000))

      assert {:ok, _reservation} = SpendGate.reserve(ctx, "c1", 100)
      # A second reserve for the SAME cost_ref must be rejected, not silently
      # accepted as a second independent reservation.
      assert {:error, _reason} = SpendGate.reserve(ctx, "c1", 100)

      recs = P.records(j)
      assert P.kinds_for(recs, "c1") == [:reserve]
    end

    test "settling the same reservation twice does not double-refund (token replay)" do
      j = P.new_journal()
      ctx = ctx(j, P.new_budget(1000))

      assert {:ok, reservation} = SpendGate.reserve(ctx, "c1", 100)
      assert :ok = SpendGate.settle(ctx, reservation, 70)
      # Replaying the same reservation token a second time must be rejected —
      # not silently refund estimate - actual a second time (money inflation).
      assert {:error, _reason} = SpendGate.settle(ctx, reservation, 70)

      recs = P.records(j)
      assert P.no_double_settle(recs) == :ok
    end
  end
end

defmodule Raxol.Agent.Red.U7SpendGateControlsTest do
  @moduledoc """
  Negative controls for U7-R (meta-invariant m4). NO `:harness_red` tag — these
  RUN IN CI and must stay GREEN. Each dead injector is a one-mutation wrong
  SpendGate implementation; its matching checker MUST flag it. A last test
  proves the checkers pass a well-formed trace (the controls are not vacuously
  red), and another proves the m1 fired-counter itself catches a dead injector.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Red.SpendGateProbe, as: P

  alias Raxol.Agent.Red.SpendGateProbe.{
    CallOnRefusedInjector,
    CrashLosesReserveInjector,
    DoubleSettleInjector,
    DualTruthInjector,
    DuplicateReserveInjector,
    SettleOnlyInjector
  }

  test "DEAD INJECTOR (a): settle-only (post-hoc accounting) fails the ORDER red" do
    j = P.new_journal()
    p = P.new_provider()
    probe = P.new_probe() |> P.arm(:settle_only)
    ctx = %{emit: P.emit_fun(j), probe: probe, budget: P.new_budget(1000)}

    assert {:ok, _} = SettleOnlyInjector.around(ctx, "c1", 100, P.call_fun(p, "c1", 80))

    recs = P.records(j)
    assert P.kinds_for(recs, "c1") == [:settle]
    # The order checker flags the missing reserve — green-on-broken is impossible.
    assert {:error, {:bad_order, "c1", [:settle]}} = P.reserve_before_call(recs)
    P.assert_all_fired!(probe, [:settle_only])
  end

  test "DEAD INJECTOR (b): calling the provider on a refused reserve fails FAIL-CLOSED (stub counter)" do
    j = P.new_journal()
    p = P.new_provider()
    probe = P.new_probe() |> P.arm(:call_on_refused)
    # Cap 0 ⇒ every reserve is refused.
    budget = P.new_budget(0)

    ctx = %{
      emit: P.emit_fun(j),
      probe: probe,
      budget: budget,
      try_reserve: P.try_reserve_fun(budget)
    }

    assert {:error, {:reserve_refused, _}} =
             CallOnRefusedInjector.around(ctx, "c1", 100, P.call_fun(p, "c1", 100))

    recs = P.records(j)
    assert P.kinds_for(recs, "c1") == [:reserve_refused]
    # The stub call-counter caught the illegal provider call: 1 seen, 0 allowed.
    assert P.provider_calls(p) == 1
    assert {:error, {:provider_calls, 1, 0}} = P.fail_closed(recs, P.provider_calls(p), 0)
    P.assert_all_fired!(probe, [:call_on_refused])
  end

  test "DEAD INJECTOR (c): reserving against a stale/second counter (dual-truth) fails NO-OVER-RESERVE" do
    cap = 300
    est = 100
    n = 10
    j = P.new_journal()
    p = P.new_provider()
    probe = P.new_probe() |> P.arm(:dual_truth)
    ctx = %{emit: P.emit_fun(j), probe: probe, budget: P.new_budget(cap)}

    for i <- 1..n do
      assert {:ok, _} = DualTruthInjector.around(ctx, "c#{i}", est, P.call_fun(p, "c#{i}", est))
    end

    recs = P.records(j)
    # 10 reserves * 100 = 1000 tokens reserved against a 300 cap — over-reserve.
    assert {:error, {:over_reserve, 1000, 300}} = P.reserved_within_cap(recs, cap)
    assert P.provider_calls(p) == n
    P.assert_all_fired!(probe, [:dual_truth])
  end

  test "DEAD INJECTOR (crash): losing a reserve on crash fails DANGLING-RESERVE-VISIBLE" do
    j = P.new_journal()
    probe = P.new_probe() |> P.arm(:crash_loses_reserve)
    ctx = %{emit: P.emit_fun(j), probe: probe, budget: P.new_budget(1000)}

    assert {:ok, _} = CrashLosesReserveInjector.reserve(ctx, "c1", 100)

    recs = P.records(j)
    # The reserve was never journaled ⇒ silently lost on crash.
    assert recs == []
    assert P.dangling_reserve_visible(recs, "c1") == {:error, :reserve_lost}
    P.assert_all_fired!(probe, [:crash_loses_reserve])
  end

  test "DEAD INJECTOR (d): reserving the same cost_ref twice fails the ORDER red" do
    j = P.new_journal()
    p = P.new_provider()
    probe = P.new_probe() |> P.arm(:duplicate_reserve)
    budget = P.new_budget(1000)

    ctx = %{
      emit: P.emit_fun(j),
      probe: probe,
      budget: budget,
      try_reserve: P.try_reserve_fun(budget)
    }

    assert {:ok, _} = DuplicateReserveInjector.around(ctx, "c1", 100, P.call_fun(p, "c1", 80))

    recs = P.records(j)
    assert P.kinds_for(recs, "c1") == [:reserve, :reserve, :call, :settle]

    assert {:error, {:bad_order, "c1", [:reserve, :reserve, :call, :settle]}} =
             P.reserve_before_call(recs)

    P.assert_all_fired!(probe, [:duplicate_reserve])
  end

  test "DEAD INJECTOR (e): settling the same reservation twice fails DOUBLE-SETTLE (money inflation)" do
    j = P.new_journal()
    p = P.new_provider()
    probe = P.new_probe() |> P.arm(:double_settle)
    budget = P.new_budget(1000)

    ctx = %{
      emit: P.emit_fun(j),
      probe: probe,
      budget: budget,
      try_reserve: P.try_reserve_fun(budget)
    }

    assert {:ok, _} = DoubleSettleInjector.around(ctx, "c1", 100, P.call_fun(p, "c1", 70))

    recs = P.records(j)
    assert P.kinds_for(recs, "c1") == [:reserve, :call, :settle, :settle]
    assert {:error, {:double_settle, "c1", 2}} = P.no_double_settle(recs)
    # The generic order checker independently flags the same trace too.
    assert {:error, {:bad_order, "c1", [:reserve, :call, :settle, :settle]}} =
             P.reserve_before_call(recs)

    P.assert_all_fired!(probe, [:double_settle])
  end

  test "the ORDER checker already rejects a bare duplicate-reserve trace via bad_order" do
    j = P.new_journal()
    emit = P.emit_fun(j)
    emit.(%{kind: :reserve, cost_ref: "c1", estimate: 100})
    emit.(%{kind: :reserve, cost_ref: "c1", estimate: 100})
    recs = P.records(j)

    assert {:error, {:bad_order, "c1", [:reserve, :reserve]}} = P.reserve_before_call(recs)
  end

  test "the checkers PASS a well-formed trace (controls are not vacuously red)" do
    j = P.new_journal()
    emit = P.emit_fun(j)
    emit.(%{kind: :reserve, cost_ref: "c1", estimate: 100})
    emit.(%{kind: :call, cost_ref: "c1"})
    emit.(%{kind: :settle, cost_ref: "c1", actual: 70})
    recs = P.records(j)

    assert P.reserve_before_call(recs) == :ok
    assert P.fail_closed(recs, 1, 1) == :ok
    assert P.reserved_within_cap(recs, 300) == :ok
    assert P.no_double_settle(recs) == :ok
    # A settled reserve is not dangling — the crash contour's negative direction.
    assert P.dangling_reserve_visible(recs, "c1") == {:error, :not_dangling}
  end

  test "PEAK vs cumulative: a refund-and-reuse trace stays within cap under peak tracking" do
    # A legitimate reserve->settle->reserve sequence: c1 reserves 100 but only
    # spends 20 (settling early frees 80 back to the pool), then c2 reserves
    # 100 and spends 90. The two estimates sum to 200 > a 150 cap, but they
    # are never concurrently outstanding, so the PEAK concurrent reserved
    # never exceeds the cap.
    j = P.new_journal()
    emit = P.emit_fun(j)
    cap = 150

    emit.(%{kind: :reserve, cost_ref: "c1", estimate: 100})
    emit.(%{kind: :call, cost_ref: "c1"})
    emit.(%{kind: :settle, cost_ref: "c1", actual: 20})
    emit.(%{kind: :reserve, cost_ref: "c2", estimate: 100})
    emit.(%{kind: :call, cost_ref: "c2"})
    emit.(%{kind: :settle, cost_ref: "c2", actual: 90})
    recs = P.records(j)

    assert P.reserved_within_cap(recs, cap) == :ok

    # Pin that the PEAK fix (not a raised cap) is what makes this pass: the
    # naive cumulative sum of every :reserve estimate WOULD have wrongly
    # rejected this well-formed, budget-respecting trace.
    cumulative =
      recs |> Enum.filter(&(&1.kind == :reserve)) |> Enum.map(& &1.estimate) |> Enum.sum()

    assert cumulative > cap
  end

  test "m1: an armed injector that never fires fails assert_all_fired! and dumps the schedule (m2)" do
    probe = P.new_probe() |> P.arm(:settle_only) |> P.arm(:dual_truth)
    P.fire(probe, :settle_only)

    err =
      assert_raise ExUnit.AssertionError, fn ->
        P.assert_all_fired!(probe, [:the, :schedule])
      end

    assert err.message =~ "dead injector"
    assert err.message =~ "dual_truth"
    refute err.message =~ ~r/dead injector.*settle_only/
    assert err.message =~ "[:the, :schedule]"
  end
end
