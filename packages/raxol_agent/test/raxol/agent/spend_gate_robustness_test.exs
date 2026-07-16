defmodule Raxol.Agent.SpendGateRobustnessTest do
  @moduledoc """
  Regression suite for the U7-I SpendGate adversarial-review findings (money-critical
  exception-safety + registry durability). These are NOT the reserve-before-call
  *law* reds (that is `U7SpendGateRedTest`) — they pin that a RAISE in the frozen
  seams (`try_reserve` / `emit` / `call_fun`) or a stray message to the registry
  owner can never wedge a cost_ref or destroy the dedup table, and — the HIGH
  finding — that a REAL journal-write failure on irreversible spend state is
  never swallowed: it surfaces as `JournalWriteError` (only the ephemeral
  `:noproc` dead-test-bus exit is tolerated), so charge and record cannot
  silently diverge.

  `async: false`: several tests poke the shared VM-global `SpendGate.Reservations`
  singleton (unexpected messages, scope sweeps), so they must not run concurrently
  with the async law suite that also drives the real gate through that registry.
  """
  use ExUnit.Case, async: false

  alias Raxol.Agent.SpendGate
  alias Raxol.Agent.SpendGate.JournalWriteError
  alias Raxol.Agent.SpendGate.Reservations

  # A minimal context. `budget_id` is the STABLE dedup scope (finding #4); an
  # explicit id makes two freshly-built `try_reserve` closures for one budget
  # share a reservation namespace. Callers that omit it fall back (documented).
  defp ctx(opts) do
    %{
      emit: Keyword.get(opts, :emit, fn _record -> :ok end),
      try_reserve: Keyword.get(opts, :try_reserve, fn _amount -> {:ok, 999} end),
      budget_id: Keyword.get(opts, :budget_id, make_ref())
    }
  end

  describe "finding #1 — a raise in the reserve/call window releases the claim" do
    test "try_reserve raising releases the claim (cost_ref retryable after)" do
      cost_ref = "f1-#{System.unique_integer([:positive])}"

      # One stable context (⇒ one stable dedup scope): the seam raises the FIRST
      # time, then succeeds. If the claim leaked on the raise, the retry would be
      # refused :duplicate_reserve instead of taking a fresh claim.
      {:ok, flag} = Agent.start_link(fn -> :raise end)

      tr = fn _amount ->
        case Agent.get_and_update(flag, fn s -> {s, :ok_mode} end) do
          :raise -> raise "budget boom"
          :ok_mode -> {:ok, 900}
        end
      end

      c = ctx(try_reserve: tr)

      assert_raise RuntimeError, "budget boom", fn ->
        SpendGate.reserve(c, cost_ref, 100)
      end

      assert {:ok, %{cost_ref: ^cost_ref}} = SpendGate.reserve(c, cost_ref, 100)
    end

    test "call_fun raising in around/4 releases the claim (cost_ref retryable after)" do
      cost_ref = "f1b-#{System.unique_integer([:positive])}"
      c = ctx([])

      assert_raise RuntimeError, "provider boom", fn ->
        SpendGate.around(c, cost_ref, 100, fn -> raise "provider boom" end)
      end

      # Claim released ⇒ the same cost_ref can be reserved again.
      assert {:ok, %{cost_ref: ^cost_ref}} = SpendGate.reserve(c, cost_ref, 100)
    end
  end

  describe "finding #2v2 (HIGH) — a real emit(:reserve) failure never yields a charged-but-unrecorded reserve" do
    test "a real (non-noproc) journal failure surfaces as JournalWriteError the budget owner can reconcile" do
      cost_ref = "f2-#{System.unique_integer([:positive])}"
      budget_id = make_ref()

      # A tiny budget the test OWNS (the same shape a real caller composes into
      # `try_reserve`): charge on reserve, refundable on reconciliation.
      {:ok, budget} = Agent.start_link(fn -> 1000 end)
      charge = fn amt -> Agent.get_and_update(budget, fn r -> {{:ok, r - amt}, r - amt} end) end
      refund = fn amt -> Agent.update(budget, &(&1 + amt)) end

      # try_reserve succeeds (budget charged) but the durable journal write for
      # the `:reserve` record fails for REAL (disk full / DB timeout class).
      c =
        ctx(
          budget_id: budget_id,
          try_reserve: charge,
          emit: fn
            %{kind: :reserve} -> raise "journal boom"
            _record -> :ok
          end
        )

      # NEVER swallowed into `{:ok, reservation}` (the pre-fix behavior): the
      # failure propagates, distinguishable, carrying the exact record.
      err = assert_raise JournalWriteError, fn -> SpendGate.reserve(c, cost_ref, 100) end
      assert %{kind: :reserve, cost_ref: ^cost_ref, estimate: 100} = err.record

      # The error payload is sufficient for the budget owner to reconcile the
      # charge — after which NO charged-but-unrecorded reserve exists: the
      # budget is back to its pre-reserve value and the journal holds nothing.
      assert Agent.get(budget, & &1) == 900
      refund.(err.record.estimate)
      assert Agent.get(budget, & &1) == 1000

      # The claim was released on the way out: the cost_ref is retryable, not
      # wedged (same contour as a raising `call_fun`).
      c_ok = ctx(budget_id: budget_id, try_reserve: charge)
      assert {:ok, _} = SpendGate.reserve(c_ok, cost_ref, 100)
    end

    test "an ephemeral :noproc from a dead journal bus is still tolerated (reservation usable)" do
      cost_ref = "f2b-#{System.unique_integer([:positive])}"

      # A journal recorder that is already DEAD — emitting into it exits with
      # `{:noproc, {GenServer, :call, ...}}`, the dead-test-bus case. No durable
      # journal existed to diverge from, so the gate proceeds.
      {:ok, bus} = Agent.start(fn -> [] end)
      :ok = Agent.stop(bus)

      c = ctx(emit: fn record -> Agent.update(bus, &[record | &1]) end)

      assert {:ok, reservation} = SpendGate.reserve(c, cost_ref, 100)
      assert :ok = SpendGate.settle(c, reservation, 70)
    end
  end

  describe "finding #3v2 (HIGH) — a real emit(:settle) failure surfaces AFTER settle accounting completed" do
    test "emit(:settle) failing for real raises JournalWriteError; the settle is complete, never re-runnable" do
      cost_ref = "f3-#{System.unique_integer([:positive])}"

      c =
        ctx(
          try_reserve: fn _amount -> {:ok, 900} end,
          emit: fn
            %{kind: :settle} -> raise "settle journal boom"
            _record -> :ok
          end
        )

      assert {:ok, reservation} = SpendGate.reserve(c, cost_ref, 100)

      # The CAS flip is irreversible and the claim is released BEFORE the
      # journal write — settle accounting is complete. But the missing `actual`
      # record must SURFACE (pre-fix it was swallowed into a bare `:ok`).
      err = assert_raise JournalWriteError, fn -> SpendGate.settle(c, reservation, 70) end
      assert %{kind: :settle, cost_ref: ^cost_ref, actual: 70} = err.record

      # Proof the guard flipped despite the raise: a replay is rejected as
      # already-settled (no double-refund), never re-run.
      assert {:error, {:already_settled, ^cost_ref}} = SpendGate.settle(c, reservation, 70)

      # Proof the claim was released: the same cost_ref is reservable again.
      assert {:ok, _} = SpendGate.reserve(c, cost_ref, 100)
    end

    test "emit(:call) failing for real in around/4 releases the claim and propagates" do
      cost_ref = "f3b-#{System.unique_integer([:positive])}"

      c =
        ctx(
          emit: fn
            %{kind: :call} -> raise "call journal boom"
            _record -> :ok
          end
        )

      err =
        assert_raise JournalWriteError, fn ->
          SpendGate.around(c, cost_ref, 100, fn -> {80, :result} end)
        end

      assert %{kind: :call, cost_ref: ^cost_ref} = err.record

      # Claim released ⇒ retryable; the reserve stays visible in the fold as
      # dangling (the crash contour's shape), never silently lost.
      assert {:ok, _} = SpendGate.reserve(c, cost_ref, 100)
    end
  end

  describe "finding #4 — dedup keyed on a stable budget id, not the try_reserve closure" do
    test "same cost_ref across two FRESHLY-BUILT closures for the SAME budget id is deduped" do
      budget_id = make_ref()
      cost_ref = "f4-#{System.unique_integer([:positive])}"

      # Two contexts for ONE budget, each with a DISTINCT try_reserve closure
      # term (rebuilt per call, as a real caller composing caps might). Keying on
      # the closure would fragment the namespace and let cost_ref reserve twice.
      ctx_a = ctx(budget_id: budget_id, try_reserve: fn _amt -> {:ok, 900} end)
      ctx_b = ctx(budget_id: budget_id, try_reserve: fn _amt -> {:ok, 800} end)

      refute ctx_a.try_reserve == ctx_b.try_reserve

      assert {:ok, _} = SpendGate.reserve(ctx_a, cost_ref, 100)
      # Second, distinct closure, SAME budget id ⇒ reserve-once dedup fires.
      assert {:error, {:refused, :duplicate_reserve}} = SpendGate.reserve(ctx_b, cost_ref, 100)
    end

    test "two DISTINCT budget ids do not false-collide on the same cost_ref" do
      cost_ref = "f4b-#{System.unique_integer([:positive])}"

      ctx_1 = ctx(budget_id: make_ref())
      ctx_2 = ctx(budget_id: make_ref())

      assert {:ok, _} = SpendGate.reserve(ctx_1, cost_ref, 100)
      # Different budget ⇒ independent namespace, NOT a duplicate.
      assert {:ok, _} = SpendGate.reserve(ctx_2, cost_ref, 100)
    end
  end

  describe "finding #5 — the registry owner survives stray messages (table not destroyed)" do
    test "an unexpected call/cast/info does NOT stop the owner or destroy the table" do
      Reservations.ensure_started()
      owner = Process.whereis(Reservations)
      assert is_pid(owner)

      # A live claim we can prove survives.
      scope = {:budget_id, make_ref()}
      cost_ref = "f5-#{System.unique_integer([:positive])}"
      assert :ok = Reservations.claim(scope, cost_ref)

      # Default GenServer handle_call/handle_cast would STOP the owner here.
      assert {:error, :unsupported} = GenServer.call(owner, :nonsense)
      GenServer.cast(owner, :nonsense)
      send(owner, :nonsense)
      # A synchronous round-trip proves the owner is still alive after all three.
      assert {:error, :unsupported} = GenServer.call(owner, :ping)

      assert Process.alive?(owner)
      assert :ets.whereis(Reservations) != :undefined
      # The claim taken before the stray traffic is intact (would be gone if the
      # table had been destroyed and recreated).
      assert {:error, :duplicate} = Reservations.claim(scope, cost_ref)

      Reservations.release(scope, cost_ref)
    end
  end

  describe "finding #6 — leaked claims from an ended scope are reclaimable (bounded growth)" do
    test "sweep_scope reclaims every claim of an ended scope; the cost_refs are reusable" do
      Reservations.ensure_started()

      # A scope with claims that were never settled/released (killed mid-reserve,
      # or a run/session budget that simply ended).
      scope = {:budget_id, make_ref()}
      refs = for i <- 1..3, do: "f6-#{i}-#{System.unique_integer([:positive])}"
      for ref <- refs, do: assert(:ok = Reservations.claim(scope, ref))

      # A second, independent scope must NOT be swept.
      other_scope = {:budget_id, make_ref()}
      other_ref = "f6-other-#{System.unique_integer([:positive])}"
      assert :ok = Reservations.claim(other_scope, other_ref)

      # Teardown reclaims exactly the ended scope's 3 claims.
      assert Reservations.sweep_scope(scope) == 3

      # Reclaimed ⇒ every cost_ref is claimable again (no unbounded leak).
      for ref <- refs, do: assert(:ok = Reservations.claim(scope, ref))

      # The other scope's claim is untouched.
      assert {:error, :duplicate} = Reservations.claim(other_scope, other_ref)

      # cleanup
      Reservations.sweep_scope(scope)
      Reservations.release(other_scope, other_ref)
    end

    test "a brutally killed reserver LEAKS its claim; sweep_scope is the reclaim path" do
      # `Process.exit(pid, :kill)` is untrappable — no rescue/catch/after runs
      # in the dying reserver, so its claim stays in the registry (unlike the
      # raising-`call_fun` contour, which releases on the way out). This pins
      # BOTH halves: the leak is real, and per-scope sweep reclaims it.
      budget_id = make_ref()
      cost_ref = "f6-kill-#{System.unique_integer([:positive])}"
      c = %{emit: fn _ -> :ok end, try_reserve: fn _ -> {:ok, 900} end, budget_id: budget_id}
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          {:ok, _} = SpendGate.reserve(c, cost_ref, 100)
          send(parent, :reserved)
          Process.sleep(:infinity)
        end)

      assert_receive :reserved, 1_000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      # The claim leaked: a retry of the same cost_ref is refused as duplicate.
      assert {:error, {:refused, :duplicate_reserve}} = SpendGate.reserve(c, cost_ref, 100)

      # Scope teardown (what U7-I MUST wire at run/session end) reclaims it,
      # and the cost_ref becomes reusable.
      assert Reservations.sweep_scope({:budget_id, budget_id}) == 1
      assert {:ok, _} = SpendGate.reserve(c, cost_ref, 100)

      # cleanup
      Reservations.sweep_scope({:budget_id, budget_id})
    end
  end
end
