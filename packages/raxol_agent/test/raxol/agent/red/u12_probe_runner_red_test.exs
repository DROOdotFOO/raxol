defmodule Raxol.Agent.Red.U12ProbeRunnerRedTest do
  @moduledoc """
  U12-R — permanent failing-first RED suite for the probe Runner interface
  (roadmap D2: in-BEAM supervised pool). Authored BEFORE the
  implementation exists, as a red-first fan-out against the frozen
  contract.

  ## What U12 is

  Probes are PURE (`Raxol.Agent.Probe`: `spec/0`, `build/1`, `interpret/2` —
  data in, data out); the Runner (`Raxol.Agent.Probe.Runner`) owns the journal,
  the bus, the provider, and provenance. The frozen observables:

    * `submit/3` NEVER blocks, NEVER returns results inline; only an
      unregistered probe fails it. Saturation/exhaustion PARK the run.
    * lifecycle = `probe_run` meta events: exactly one `:started`-or-`:parked`
      and exactly one terminal per run (P-U12.1/N-U12.8).
    * budget in tokens, reserve-before-call (AD-6a; P-U12.2/N-U12.2);
      settlement internal (F4); the `charge` split shape frozen; three
      exhaustion signals (park at submit-refuse, `:exhausted` mid-run with
      atomic output, runner-owned `max_calls`/`timeout`).
    * bounded parking (F5): `max_parked` dominates → `:exhausted` with exactly
      one terminal; a parked run past `park_timeout_ms` sheds to `:exhausted`
      (N-U12.10, additive to N-U12.3).
    * cache-riding: request prefix byte-identical to the primary's at the tip
      (P-U12.3/N-U12.5 — provider-free: captured request bytes compared).
    * isolation: kill/crash leaves the primary trace identical (P-U12.4);
      `family: :loop` drafts rejected whole (N-U12.1); no post-kill emission
      (N-U12.7).
    * provenance: Runner stamps `source = :probe_<id>`,
      `trust = context.taint ⊓ refs` — a tainted context can produce NO
      trusted event (P-U12.5/N-U12.6).
    * fingerprint REQUIRED on every `probe_run` terminal.

  ## Observable seam (frozen by this suite)

  The Runner reports through injectable sinks in `opts`:

      submit(session_id, probe, emit: fun, provider: stub, budget: pid,
             context: %Raxol.Agent.Probe.context(), ...)

  where `emit` receives the lab's frozen record shapes (`:probe_run`,
  `:meta_result`, `:reserve`/`:call`/`:settle` — see
  `Raxol.Agent.Red.ProbeRunnerLab`). In production the sinks are the journal /
  EmitBridge and the real provider; here they are in-memory recorders the
  checkers fold. Binding them is U12 implementation work.

  ## NOT authored here (OQ-U12.2)

  `mode: :standalone` reds are `@tag`-pending until U17 — the interface is
  frozen (the `spec()` mode enum includes `:standalone`) but C6 cross-family is
  its only consumer and lands in Wave 4. Deliberately no standalone contour in
  this file.

  ## Mergeability discipline

  GRADUATED: the Runner Pool impl lands these all GREEN, so the
  `@moduletag :harness_red` gate was removed and the suite now runs in CI. It
  was authored red-first (excluded via `:harness_red` in `test_helper.exs`)
  and stayed red until the impl existed; graduation followed the N-U12.3
  amendment (see the test at the `submit under exhaustion` case for the ruling).
  The negative controls (dead injectors) live in `U12ProbeRunnerControlsTest`
  below and prove the checkers are not vacuous.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Probe.Runner
  alias Raxol.Agent.Red.ProbeRunnerLab, as: L

  alias Raxol.Agent.Red.ProbeRunnerLab.{
    CacheRideProbe,
    HangingProbe,
    LoopDraftProbe,
    MultiCallProbe,
    GatedProbe,
    ShortParkProbe,
    SlowMultiCallProbe,
    TaintedTrustProbe,
    UnregisteredSourceProbe
  }

  # Seed for concurrent-schedule contours; overridable + dumped on failure (m2).
  @seed String.to_integer(System.get_env("U12_SEED", "424242"))

  defmodule NotAProbe do
    @moduledoc false
  end

  defp ctx(opts \\ []) do
    %{
      session_id: Keyword.get(opts, :session_id, "u12-red"),
      tip_offset: Keyword.get(opts, :tip_offset, 41),
      prefix_ref: Keyword.get(opts, :prefix_ref, {:captured, L.primary_prefix()}),
      taint: Keyword.get(opts, :taint, :trusted),
      budget_scope: Keyword.get(opts, :budget_scope, :session_then_run),
      read_set: Keyword.get(opts, :read_set, [])
    }
  end

  defp rig(opts \\ []) do
    %{
      bus: L.new_bus(),
      provider: L.new_provider(),
      budget: L.new_budget(Keyword.get(opts, :cap, 1_000))
    }
  end

  defp submit_opts(rig, context) do
    [
      emit: L.emit_fun(rig.bus),
      provider: rig.provider,
      budget: rig.budget,
      context: context
    ]
  end

  # Terminals are asynchronous — poll the bus fold until every submitted run
  # carries a terminal probe_run (or the deadline passes and we fold what's
  # there). The default slack is generous AND scales with the run count: the pool
  # is a shared singleton, so a burst of runs from a parallel async test can add
  # latency (adversarial-review #8a). A genuinely-dropped run still fails: the
  # bound elapses and the fold sees openings:1/terminals:0 (N-U12.3, pinned).
  defp await_terminals(bus, run_ids, deadline_ms \\ nil) do
    deadline_ms = deadline_ms || 5_000 + 250 * length(run_ids)
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await(bus, MapSet.new(run_ids), deadline)
  end

  defp do_await(bus, wanted, deadline) do
    events = L.events(bus)

    terminal_ids =
      for %{kind: :probe_run, run_id: id, status: s} <- events,
          s in L.terminal_statuses(),
          into: MapSet.new(),
          do: id

    cond do
      MapSet.subset?(wanted, terminal_ids) ->
        events

      System.monotonic_time(:millisecond) > deadline ->
        events

      true ->
        Process.sleep(20)
        do_await(bus, wanted, deadline)
    end
  end

  # Submit `n` runs whose `build/1` is blocked on a gate this process owns, and
  # return the submit results. The gate stays SHUT on return, so the caller can
  # assert against a pool where no run has reached the provider.
  #
  # The 15s bound is a LIVENESS deadline, not a latency budget: it only elapses
  # if a submit genuinely never returns (i.e. it ran the gated probe inline).
  # Nothing here asserts how fast a submit is -- that was the flaw in the
  # wall-clock form this replaced.
  defp submit_gated!(rig, prefix, n) do
    gate = self()
    context = Map.put(ctx(), :gate, gate)

    task =
      Task.async(fn ->
        for i <- 1..n do
          Runner.submit("#{prefix}-#{i}", GatedProbe, submit_opts(rig, context))
        end
      end)

    case Task.yield(task, 15_000) do
      {:ok, results} ->
        results

      _ ->
        Task.shutdown(task, :brutal_kill)

        flunk(
          "submit blocked: #{n} submit(s) never returned while every run was " <>
            "held in build/1 — submit is waiting for the run"
        )
    end
  end

  # Open the gate and keep it open until every run is terminal. This is cleanup
  # with teeth: the pool is a shared SINGLETON, so leaving workers parked in
  # `build/1` would starve every other async test — exactly the cross-test
  # interference this rewrite exists to stop causing.
  defp release_gated(bus, run_ids) do
    drain_and_release(
      bus,
      MapSet.new(run_ids),
      System.monotonic_time(:millisecond) + 10_000
    )
  end

  defp drain_and_release(bus, wanted, deadline) do
    receive do
      {:probe_gated, pid} ->
        send(pid, :release)
        drain_and_release(bus, wanted, deadline)
    after
      25 ->
        cond do
          all_terminal?(bus, wanted) -> :ok
          System.monotonic_time(:millisecond) > deadline -> :ok
          true -> drain_and_release(bus, wanted, deadline)
        end
    end
  end

  defp all_terminal?(bus, wanted) do
    terminal =
      for %{kind: :probe_run, run_id: id, status: s} <- L.events(bus),
          s in L.terminal_statuses(),
          into: MapSet.new(),
          do: id

    MapSet.subset?(wanted, terminal)
  end

  describe "submit is non-blocking and total (red until U12 lands)" do
    test "submit returns {:ok, run_id} without waiting for the run" do
      rig = rig()

      # Causal, not timed. The run blocks inside `build/1`, which the Pool calls
      # STRICTLY BEFORE the provider -- so a submit that returns here provably
      # did not run its own probe inline. The old form asserted `micros <
      # 50_000`, which measured `GenServer.call` queueing on a pool that is a
      # shared singleton every other async test also submits to; that is
      # contention, not the design property, and it flaked accordingly.
      {:ok, run_id} = submit_gated!(rig, "u12-red", 1) |> hd()

      assert is_binary(run_id)

      assert L.provider_calls(rig.provider) == 0,
             "submit returned only after the run reached the provider — it blocked"

      release_gated(rig.bus, [run_id])
    end

    test "only an unknown probe fails submit — {:error, :unknown_probe}" do
      rig = rig()

      assert {:error, :unknown_probe} =
               Runner.submit("u12-red", NotAProbe, submit_opts(rig, ctx()))

      # Nothing emitted, no provider call for a rejected submit.
      assert L.events(rig.bus) == []
      assert L.provider_calls(rig.provider) == 0
    end

    # Tagged :slow (adversarial-review #8b): this pins the N-U12.3 law against the
    # PRODUCTION 10s park_timeout_ms and takes ~10s, so it is excluded from the
    # default CI run. A fast equivalent below (ShortParkProbe) checks the same law
    # in CI. Run the slow one with `mix test --include slow`.
    @tag :slow
    test "submit under exhaustion still returns {:ok, run_id}; the run PARKS, then its lifecycle completes via the shed terminal — zero provider calls (N-U12.3)" do
      # Cap 0 ⇒ every reserve refused at the submit-time budget check.
      rig = rig(cap: 0)

      assert {:ok, run_id} =
               Runner.submit("u12-red", CacheRideProbe, submit_opts(rig, ctx()))

      # The contradiction: the original N-U12.3 read the bus IMMEDIATELY after
      # submit and asserted `lifecycle_complete/2`, which requires exactly one
      # terminal per run. On a budget-refused (cap:0) run the immediate read sees
      # only the `:parked` opening (openings:1, terminals:0), so it demanded a
      # SYNCHRONOUS terminal at submit time. That is pre-F5 semantics (park =
      # immediate synthetic terminal). It is mutually exclusive with the
      # bounded-parking laws in THIS file for the identical first run: test ~298
      # (a parked run sheds to :exhausted only after park_timeout_ms) and test
      # ~315 (a max_parked-refused run is :exhausted and was NEVER :parked).
      #
      # Genuine held bounded parking (ratified F5) means a parked run
      # legitimately has NO terminal until it sheds (TTL/pressure) or executes.
      # The lifecycle-completeness law it pins — every submitted run terminates,
      # even when parked — REMAINS in force, but ASYNCHRONOUSLY. So AWAIT the
      # terminal (bounded poll until the real shed produces it) instead of reading
      # it inline. A truly-missing terminal still fails (the bound elapses and the
      # fold sees openings:1/terminals:0) rather than hanging. Tests ~298/~315 are
      # untouched; all three laws (lifecycle-completeness, over-cap exhaustion,
      # parked≠exhausted-lie) still hold — only the timing assumption changed.
      # Rationale: F5 genuine-parking (the frozen Budget contour).
      park_ttl = CacheRideProbe.spec().park_timeout_ms
      events = await_terminals(rig.bus, [run_id], park_ttl + 2_000)

      assert Enum.any?(
               events,
               &(&1.kind == :probe_run and &1.run_id == run_id and
                   &1.status == :parked)
             ),
             "budget-refused submit must PARK (probe_run{status: :parked}), got #{inspect(events)}"

      # Fail-closed: no reserve ⇒ no call, ever — even across the shed.
      assert L.fail_closed(L.provider_calls(rig.provider), 0) == :ok
      # Never dropped silently: the submitted run's lifecycle COMPLETES with a
      # terminal, arriving asynchronously via the real shed path (not inline).
      assert L.lifecycle_complete(events, [run_id]) == :ok
    end

    test "N-U12.3 (fast, CI): budget-refused submit PARKS then completes via the shed terminal — same pinned law, short park_timeout_ms" do
      # The fast CI equivalent of the :slow N-U12.3 test above — ShortParkProbe's
      # park_timeout_ms is 300ms, so the shed arrives sub-second. The pinned law
      # is identical: parks, then the lifecycle completes ASYNCHRONOUSLY via the
      # real shed; a genuinely-dropped run still fails (bounded await).
      rig = rig(cap: 0)

      assert {:ok, run_id} =
               Runner.submit("u12-red", ShortParkProbe, submit_opts(rig, ctx()))

      park_ttl = ShortParkProbe.spec().park_timeout_ms
      events = await_terminals(rig.bus, [run_id], park_ttl + 2_000)

      assert Enum.any?(
               events,
               &(&1.kind == :probe_run and &1.run_id == run_id and
                   &1.status == :parked)
             ),
             "budget-refused submit must PARK, got #{inspect(events)}"

      assert L.fail_closed(L.provider_calls(rig.provider), 0) == :ok
      assert L.lifecycle_complete(events, [run_id]) == :ok
    end

    test "submit under saturation never waits for the run (burst)" do
      rig = rig()
      n = 16

      # Real saturation, held open: every run is stuck in `build/1` for the
      # whole burst, so the pool cannot drain between submits the way it could
      # when the runs were instant. All 16 submits still return.
      results = submit_gated!(rig, "u12-red", n)

      assert Enum.all?(results, &match?({:ok, _}, &1)),
             "submit failed under saturation: #{inspect(results)}"

      run_ids = Enum.map(results, fn {:ok, id} -> id end)
      assert length(Enum.uniq(run_ids)) == n, "run_ids must be unique"

      # THE PROPERTY, stated causally: 16 submits returned while not one run had
      # reached the provider. A submit that ran its probe inline could not have
      # gotten past the first shut gate, let alone returned 16 times.
      assert L.provider_calls(rig.provider) == 0,
             "a submit returned only after its run reached the provider — it blocked"

      release_gated(rig.bus, run_ids)
    end
  end

  describe "emit durability (adversarial-review #1)" do
    test "a genuine (non-:noproc) emit failure is NOT silently swallowed — the run crashes to :error, never :completed" do
      # safe_emit swallows ONLY the dead-test-bus :noproc exit. A journal write
      # that genuinely RAISES must surface: here the emit raises on the :call
      # accounting event (run-Task context), so the Task crashes and the coord
      # turns it into the run's :error terminal — instead of dropping the record
      # and letting the run complete as if journaled.
      rig = rig()

      raising_emit = fn
        %{kind: :call} -> raise "journal write down"
        event -> L.emit(rig.bus, event)
      end

      opts = [
        emit: raising_emit,
        provider: rig.provider,
        budget: rig.budget,
        context: ctx()
      ]

      assert {:ok, run_id} = Runner.submit("u12-red", CacheRideProbe, opts)

      events = await_terminals(rig.bus, [run_id])

      terminals =
        for %{kind: :probe_run, run_id: ^run_id, status: s, reason: r} <- events,
            s in L.terminal_statuses(),
            do: {s, r}

      assert terminals == [{:error, :crash}],
             "a raised emit must surface (crash → :error), got #{inspect(terminals)}"

      refute Enum.any?(
               events,
               &(&1.kind == :probe_run and &1.run_id == run_id and
                   &1.status == :completed)
             ),
             "a swallowed emit would have let the run complete as if journaled"

      assert L.lifecycle_complete(events, [run_id]) == :ok
    end
  end

  describe "P-U12.1 lifecycle completeness" do
    test "every submitted run: exactly one :started-or-:parked and exactly one terminal probe_run" do
      rig = rig()

      submitted =
        for i <- 1..4 do
          assert {:ok, run_id} =
                   Runner.submit(
                     "u12-red",
                     CacheRideProbe,
                     submit_opts(rig, ctx(tip_offset: 40 + i))
                   )

          run_id
        end

      events = await_terminals(rig.bus, submitted)
      assert L.lifecycle_complete(events, submitted) == :ok
      assert {:ok, status} = Runner.status(hd(submitted))

      assert status in [
               :completed,
               :exhausted,
               :timeout,
               :error,
               :killed,
               :parked,
               :queued,
               :running
             ]
    end

    test "kill/1 yields the :killed terminal exactly once; status reports it; no post-kill emission (N-U12.7)" do
      rig = rig()

      assert {:ok, run_id} =
               Runner.submit("u12-red", CacheRideProbe, submit_opts(rig, ctx()))

      assert :ok = Runner.kill(run_id)

      events = await_terminals(rig.bus, [run_id])
      assert L.lifecycle_complete(events, [run_id]) == :ok

      terminals =
        for %{kind: :probe_run, run_id: ^run_id, status: s} <- events,
            s in L.terminal_statuses(),
            do: s

      assert terminals == [:killed]
      assert {:ok, :killed} = Runner.status(run_id)
      assert {:error, :not_found} = Runner.kill("no-such-run")
      assert {:error, :not_found} = Runner.status("no-such-run")
    end
  end

  describe "budget reserve release on under-charge terminals (adversarial-review #5)" do
    test "kill releases the submit-time reserve — a subsequent submit that would have been refused now succeeds" do
      # Cap fits exactly ONE 100-token reserve. Run A holds it; without release,
      # run B would be refused (park). Killing A must return the headroom.
      rig = rig(cap: 100)

      assert {:ok, a} =
               Runner.submit("u12-red", CacheRideProbe, submit_opts(rig, ctx()))

      # A is running and holds the reserve.
      assert L.reserved(rig.budget) == 100
      assert :ok = Runner.kill(a)
      # The reserve is returned — the counter tracks the authoritative charge.
      assert L.reserved(rig.budget) == 0

      # B now fits: it RUNS (a :started opening), never parks on a phantom reserve.
      assert {:ok, b} =
               Runner.submit("u12-red", CacheRideProbe, submit_opts(rig, ctx()))

      events = await_terminals(rig.bus, [b])

      refute Enum.any?(
               events,
               &(&1.kind == :probe_run and &1.run_id == b and
                   &1.status == :parked)
             ),
             "B was refused a reserve that kill should have released: #{inspect(events)}"

      assert L.lifecycle_complete(events, [b]) == :ok
    end
  end

  describe "reserve/settle reconciliation (adversarial-review HIGH / #1)" do
    test "a completed multi-call run settles every reserve — reserved returns to baseline, no session growth" do
      # A bounded budget shared across several sequential COMPLETED multi-call
      # runs. MultiCallProbe makes two provider calls (two 100-token reserves). If
      # :completed released nothing (the leak), `reserved` would climb 200 per run
      # and eventually saturate; it must return to 0 after every run.
      rig = rig(cap: 1_000)

      for _round <- 1..3 do
        assert {:ok, run_id} =
                 Runner.submit(
                   "u12-red",
                   MultiCallProbe,
                   submit_opts(rig, ctx())
                 )

        events = await_terminals(rig.bus, [run_id])

        assert Enum.any?(
                 events,
                 &(&1.kind == :probe_run and &1.run_id == run_id and
                     &1.status == :completed)
               ),
               "expected the multi-call run to complete, got #{inspect(events)}"

        assert L.reserved(rig.budget) == 0,
               "a completed multi-call run stranded reserve: reserved=#{L.reserved(rig.budget)} " <>
                 "— the reserve/settle reconciliation leaked (monotonic budget growth)"
      end
    end

    test "a post-grace kill mid multi-call stops spend at the call boundary — no more calls, no leaked reserve, one :killed" do
      # SlowMultiCallProbe sleeps per call, so a kill issued PAST @kill_grace_ms
      # (25ms) lands mid multi-call. The budget is wide (cap fits every call) and
      # the leash/wall-clock are far off, so ONLY the kill can stop the run.
      rig = rig(cap: 2_000)
      probe = SlowMultiCallProbe
      max_calls = probe.spec().max_calls

      assert {:ok, run_id} =
               Runner.submit("u12-red", probe, submit_opts(rig, ctx()))

      # Past the 25ms grace + the initial checkpoint, so the run is in its
      # multi-call loop with call 1 in flight — NOT killed at the checkpoint.
      Process.sleep(40)
      assert :ok = Runner.kill(run_id)

      _ = await_terminals(rig.bus, [run_id])

      # Let the in-flight call finish and the loop hit its next reserve boundary
      # (refused → exit).
      Process.sleep(probe.per_call_ms() + 80)
      calls_after_kill = L.provider_calls(rig.provider)

      # A full run's worth of time: had the kill NOT stopped spend, the loop would
      # have made all max_calls provider calls by now.
      Process.sleep(max_calls * probe.per_call_ms() + 100)

      # (a) spend stopped at the call boundary: no provider call after the kill
      # settled, and the run never ran to the Runner-owned leash.
      assert L.provider_calls(rig.provider) == calls_after_kill,
             "provider called again after :killed — spend did not stop at the call boundary"

      assert calls_after_kill < max_calls,
             "the killed run ran to the leash (#{calls_after_kill}/#{max_calls}) — kill did not stop spend"

      # (b) no leaked reserve: every reserve the run took is released, budget
      # headroom fully restored.
      assert L.reserved(rig.budget) == 0,
             "a reserve leaked past the kill: reserved=#{L.reserved(rig.budget)}"

      # (c) exactly one :killed terminal, atomic (no drafted output survived).
      events = L.events(rig.bus)

      terminals =
        for %{kind: :probe_run, run_id: ^run_id, status: s} <- events,
            s in L.terminal_statuses(),
            do: s

      assert terminals == [:killed],
             "a mid-multi-call kill must yield exactly one :killed terminal, got #{inspect(terminals)}"

      assert L.lifecycle_complete(events, [run_id]) == :ok
      assert L.output_atomic(events) == :ok
    end
  end

  describe "two-level budget — session-then-run rollback (adversarial-review #6)" do
    test "session reserve is RELEASED when the run-level reserve is refused — no leaked session budget (OQ-U12.1)" do
      # Session cap fits one reserve; run cap is 0 so the RUN level is refused
      # AFTER the session level succeeded. The session reservation must roll back.
      session_budget = L.new_budget(100)
      run_budget = L.new_budget(0)
      bus = L.new_bus()
      provider = L.new_provider()

      opts = [
        emit: L.emit_fun(bus),
        provider: provider,
        budget: run_budget,
        session_budget: session_budget,
        context: ctx()
      ]

      assert {:ok, run_id} = Runner.submit("u12-red", ShortParkProbe, opts)

      # The rollback is synchronous inside submit: the session budget is back to 0.
      assert L.budget_conserved(session_budget, 0) == :ok,
             "session budget leaked on run-level refusal: reserved=#{L.reserved(session_budget)}"

      # The run still parks and completes its lifecycle via the shed terminal.
      park_ttl = ShortParkProbe.spec().park_timeout_ms
      events = await_terminals(bus, [run_id], park_ttl + 2_000)
      assert L.lifecycle_complete(events, [run_id]) == :ok
    end
  end

  describe "P-U12.2 budget — reserve-before-call (AD-6a)" do
    test "journal order per provider call is reserve → call → settle; never a call without a prior same-run reserve" do
      rig = rig()

      assert {:ok, run_id} =
               Runner.submit("u12-red", MultiCallProbe, submit_opts(rig, ctx()))

      events = await_terminals(rig.bus, [run_id])

      assert L.reserve_before_call(events) == :ok
      calls = Enum.count(events, &(&1.kind == :call))
      reserves = Enum.count(events, &(&1.kind == :reserve))

      assert calls > 0,
             "the probe made no provider calls — the contour is vacuous"

      assert reserves >= calls
      assert L.fail_closed(L.provider_calls(rig.provider), calls) == :ok
    end

    test "mid-run reserve refusal → :exhausted terminal with ATOMIC output — zero drafted events (P-U12.6/N-U12.9)" do
      # Cap fits exactly one 100-token reserve; MultiCallProbe wants two calls.
      rig = rig(cap: 100)

      assert {:ok, run_id} =
               Runner.submit("u12-red", MultiCallProbe, submit_opts(rig, ctx()))

      events = await_terminals(rig.bus, [run_id])

      assert Enum.any?(
               events,
               &(&1.kind == :probe_run and &1.run_id == run_id and
                   &1.status == :exhausted)
             ),
             "mid-run refusal must terminate :exhausted, got #{inspect(events)}"

      assert L.output_atomic(events) == :ok
      assert L.lifecycle_complete(events, [run_id]) == :ok
    end

    test "max_calls is Runner-owned: no (max_calls+1)th provider call, terminal :exhausted (N-U12.4)" do
      rig = rig()
      max_calls = CacheRideProbe.spec().max_calls

      assert {:ok, run_id} =
               Runner.submit("u12-red", CacheRideProbe, submit_opts(rig, ctx()))

      _events = await_terminals(rig.bus, [run_id])

      assert L.leash_enforced(L.provider_calls(rig.provider), max_calls) == :ok
    end

    test "the terminal charge carries the frozen split shape (cached dividend visible)" do
      rig = rig()

      assert {:ok, run_id} =
               Runner.submit("u12-red", CacheRideProbe, submit_opts(rig, ctx()))

      events = await_terminals(rig.bus, [run_id])

      terminal =
        Enum.find(
          events,
          &(&1.kind == :probe_run and &1.status in L.terminal_statuses())
        )

      assert %{
               prompt_tokens: p,
               cached_prompt_tokens: c,
               completion_tokens: o,
               calls: n
             } = terminal.charge

      assert is_integer(p) and is_integer(c) and is_integer(o) and is_integer(n)
      assert c <= p, "cached prompt tokens cannot exceed prompt tokens"
    end
  end

  describe "wall-clock timeout_ms leash (adversarial-review #2)" do
    test "a hung run gets a :timeout terminal at spec.timeout_ms and its reserve is released" do
      # cap fits exactly one reserve; HangingProbe.build/1 never returns, so
      # without the leash the reserve leaks forever and no terminal ever lands.
      rig = rig(cap: 100)
      timeout_ms = HangingProbe.spec().timeout_ms

      assert {:ok, run_id} =
               Runner.submit("u12-red", HangingProbe, submit_opts(rig, ctx()))

      # It reserved at submit and is now hung.
      assert L.reserved(rig.budget) == 100

      events = await_terminals(rig.bus, [run_id], timeout_ms + 2_000)

      terminals =
        for %{kind: :probe_run, run_id: ^run_id, status: s, reason: r} <- events,
            s in L.terminal_statuses(),
            do: {s, r}

      assert terminals == [{:timeout, :timeout_ms}],
             "a hung run must terminate :timeout at the leash, got #{inspect(terminals)}"

      # The reserve is released — a hung run no longer strands budget.
      assert L.reserved(rig.budget) == 0
      assert L.lifecycle_complete(events, [run_id]) == :ok
    end
  end

  describe "bounded parking (F5)" do
    # Tagged :slow (adversarial-review #8b): pins the park-TTL law against the
    # production 10s park_timeout_ms (~10s). The fast equivalent below checks the
    # same law in CI.
    @tag :slow
    test "a parked run past park_timeout_ms sheds to the :exhausted terminal — parking is never indefinite" do
      rig = rig(cap: 0)

      assert {:ok, run_id} =
               Runner.submit("u12-red", CacheRideProbe, submit_opts(rig, ctx()))

      park_ttl = CacheRideProbe.spec().park_timeout_ms
      events = await_terminals(rig.bus, [run_id], park_ttl + 2_000)

      assert Enum.any?(
               events,
               &(&1.kind == :probe_run and &1.run_id == run_id and
                   &1.status == :exhausted)
             ),
             "over-TTL parked run must terminate :exhausted, got #{inspect(events)}"

      assert L.lifecycle_complete(events, [run_id]) == :ok
    end

    test "a parked run past park_timeout_ms sheds to :exhausted (fast, CI) — short park_timeout_ms" do
      # Fast CI equivalent: ShortParkProbe.park_timeout_ms is 300ms, so the TTL
      # shed lands sub-second. Same law: parking is never indefinite.
      rig = rig(cap: 0)

      assert {:ok, run_id} =
               Runner.submit("u12-red", ShortParkProbe, submit_opts(rig, ctx()))

      park_ttl = ShortParkProbe.spec().park_timeout_ms
      events = await_terminals(rig.bus, [run_id], park_ttl + 2_000)

      assert Enum.any?(
               events,
               &(&1.kind == :probe_run and &1.run_id == run_id and
                   &1.status == :exhausted and
                   &1.reason == :park_timeout)
             ),
             "over-TTL parked run must terminate :exhausted (reason :park_timeout), got #{inspect(events)}"

      assert L.lifecycle_complete(events, [run_id]) == :ok
    end

    test "submit past max_parked: excess runs go :exhausted (never :parked — max_parked dominates), parked set stays bounded, all runs get exactly one terminal (N-U12.10)" do
      rig = rig(cap: 0)
      max_parked = CacheRideProbe.spec().max_parked
      :rand.seed(:exsss, {@seed, 12, @seed})
      n = max_parked + 5

      submitted =
        for i <- 1..n do
          Process.sleep(:rand.uniform(2) - 1)

          assert {:ok, run_id} =
                   Runner.submit(
                     "u12-red",
                     CacheRideProbe,
                     submit_opts(rig, ctx(tip_offset: i))
                   ),
                 "seed=#{@seed}: submit ##{i} must still return ok past max_parked (N-U12.3)"

          run_id
        end

      events = await_terminals(rig.bus, submitted)

      # The parked set never grows past the cap.
      assert L.bounded_parking(events, max_parked) == :ok, "seed=#{@seed}"

      # The OVER-CAP-refused runs are identified by their :exhausted
      # `reason: :max_parked` — NOT by "any :exhausted run". The contract
      # (Budget / N-U12.10) says pressure relief also sheds the OLDEST HELD
      # parked runs to :exhausted (reason :pressure); those legitimately WERE
      # :parked. Iterating every :exhausted run would wrongly flag a
      # pressure-evicted parked run. The LAW this pins — a max_parked-REFUSED
      # run is :exhausted and was NEVER :parked (parking precedence) — holds
      # regardless; only the set it applies to is scoped to the refused runs.
      # (Pressure-eviction is :exhausted, never :timeout, and sheds the
      # oldest one per overflow, never nukes all.)
      refused =
        for %{
              kind: :probe_run,
              run_id: id,
              status: :exhausted,
              reason: :max_parked
            } <- events,
            into: MapSet.new(),
            do: id

      assert MapSet.size(refused) == n - max_parked,
             "seed=#{@seed}: exactly #{n - max_parked} over-cap runs must shed :exhausted " <>
               "(reason :max_parked), got #{MapSet.size(refused)} — a silently discarded run " <>
               "is the N-U12.3 breach"

      for run_id <- refused do
        refute Enum.any?(
                 events,
                 &(&1.kind == :probe_run and &1.run_id == run_id and
                     &1.status == :parked)
               ),
               "seed=#{@seed}: a max_parked-refused run must NEVER be :parked (§3.3 parking precedence)"
      end

      # Still exactly one terminal each — shedding is not double-emitting.
      assert L.lifecycle_complete(events, submitted) == :ok, "seed=#{@seed}"
    end

    test "one over-cap submit sheds at most one (the oldest) parked run; the others survive (adversarial-review #7)" do
      # Fill the parked set to exactly max_parked (all PARK — cap:0 refuses every
      # reserve, parked set not yet full). ShortParkProbe: max_parked 3, fast TTL.
      rig = rig(cap: 0)
      max_parked = ShortParkProbe.spec().max_parked

      parked =
        for i <- 1..max_parked do
          assert {:ok, id} =
                   Runner.submit(
                     "u12-red",
                     ShortParkProbe,
                     submit_opts(rig, ctx(tip_offset: i))
                   )

          id
        end

      # Every one parked, none terminal yet (park_or_shed emits :parked inline).
      evs0 = L.events(rig.bus)

      for id <- parked do
        assert Enum.any?(
                 evs0,
                 &(&1.kind == :probe_run and &1.run_id == id and
                     &1.status == :parked)
               )

        refute Enum.any?(
                 evs0,
                 &(&1.kind == :probe_run and &1.run_id == id and
                     &1.status in L.terminal_statuses())
               )
      end

      # ONE over-cap submit → it goes :exhausted (never parked) and schedules a
      # SINGLE pressure-shed of the oldest held run.
      assert {:ok, over} =
               Runner.submit(
                 "u12-red",
                 ShortParkProbe,
                 submit_opts(rig, ctx(tip_offset: 99))
               )

      # Wait for the single pressure-shed (@pressure_shed_ms ~40ms) but well
      # inside the 300ms park TTL so survivors are shed by PRESSURE, not TTL.
      Process.sleep(120)
      events = L.events(rig.bus)

      # The over-cap run: :exhausted, reason :max_parked, never :parked.
      assert Enum.any?(
               events,
               &(&1.kind == :probe_run and &1.run_id == over and
                   &1.status == :exhausted and
                   &1.reason == :max_parked)
             )

      # Exactly ONE parked run was pressure-evicted (:exhausted, reason :pressure).
      pressure_shed =
        for %{
              kind: :probe_run,
              run_id: id,
              status: :exhausted,
              reason: :pressure
            } <- events,
            id in parked,
            into: MapSet.new(),
            do: id

      assert MapSet.size(pressure_shed) == 1,
             "one overflow must shed exactly one parked run, got #{inspect(MapSet.to_list(pressure_shed))}"

      # The oldest (smallest tip / first submitted) was the one evicted.
      assert MapSet.member?(pressure_shed, hd(parked)),
             "the OLDEST parked run must be the one shed"

      # The other parked runs SURVIVE (still parked, no terminal yet).
      survivors = Enum.reject(parked, &MapSet.member?(pressure_shed, &1))

      for id <- survivors do
        refute Enum.any?(
                 events,
                 &(&1.kind == :probe_run and &1.run_id == id and
                     &1.status in L.terminal_statuses())
               ),
               "a non-oldest parked run was shed by a single overflow: #{id}"
      end
    end
  end

  describe "kill on a parked run (adversarial-review #3)" do
    test "kill on a PARKED run emits the :killed terminal, cancels the TTL, sheds no later :exhausted" do
      # cap:0 refuses the reserve → the run PARKS. park_or_shed emits :parked
      # synchronously inside submit, so it is already on the bus when submit
      # returns. ShortParkProbe's park_timeout_ms is 300ms (fast-park, #8) so the
      # "no shed after kill" wait is sub-second, not the 10s production TTL.
      rig = rig(cap: 0)

      assert {:ok, run_id} =
               Runner.submit("u12-red", ShortParkProbe, submit_opts(rig, ctx()))

      assert Enum.any?(
               L.events(rig.bus),
               &(&1.kind == :probe_run and &1.run_id == run_id and
                   &1.status == :parked)
             ),
             "expected the run to park before kill: #{inspect(L.events(rig.bus))}"

      assert :ok = Runner.kill(run_id)

      # Wait past park_timeout_ms: a cancelled TTL must NOT shed a second terminal.
      park_ttl = ShortParkProbe.spec().park_timeout_ms
      Process.sleep(park_ttl + 200)
      events = L.events(rig.bus)

      terminals =
        for %{kind: :probe_run, run_id: ^run_id, status: s} <- events,
            s in L.terminal_statuses(),
            do: s

      assert terminals == [:killed],
             "kill on a parked run must yield exactly one :killed terminal, got #{inspect(terminals)}"

      assert {:ok, :killed} = Runner.status(run_id)
      assert L.lifecycle_complete(events, [run_id]) == :ok
    end
  end

  describe "P-U12.3 cache-riding — prefix byte-identity (provider-free)" do
    test "N probes at one tip: every captured request prefix is byte-identical to the primary's; divergence names the byte offset (N-U12.5)" do
      rig = rig()
      context = ctx(tip_offset: 41)

      submitted =
        for _ <- 1..3 do
          assert {:ok, run_id} =
                   Runner.submit(
                     "u12-red",
                     CacheRideProbe,
                     submit_opts(rig, context)
                   )

          run_id
        end

      _events = await_terminals(rig.bus, submitted)
      captures = L.captures(rig.provider)

      assert length(captures) >= 3,
             "expected ≥3 captured requests, got #{length(captures)}"

      # All prefixes byte-equal to the primary's captured request bytes...
      assert L.prefix_identity(captures, L.primary_prefix()) == :ok

      # ...and therefore to each other (pure byte comparison, no provider).
      prefixes = captures |> Enum.map(& &1.prefix) |> Enum.uniq()
      assert length(prefixes) == 1, "probe prefixes diverged among themselves"

      # AD-5: the suffix rides AFTER the prefix; the prefix is untouched.
      assert Enum.all?(captures, &(&1.suffix != nil))
    end
  end

  describe "P-U12.4 isolation" do
    test "killing/crashing a subset of concurrent probes leaves the primary event trace identical to the no-probes run" do
      # Baseline: the primary trace with NO probes.
      baseline = [
        :turn_started,
        :item_started,
        :item_completed,
        :turn_completed
      ]

      rig = rig()
      # The primary loop writes its trace through the same bus (the projection
      # the checker folds is kind: :loop only — P-U11.5 machinery reused).
      Enum.each(baseline, fn label -> L.emit(rig.bus, L.loop_event(label)) end)

      submitted =
        for i <- 1..4 do
          assert {:ok, run_id} =
                   Runner.submit(
                     "u12-red",
                     CacheRideProbe,
                     submit_opts(rig, ctx(tip_offset: i))
                   )

          run_id
        end

      # Kill half of them mid-flight.
      [k1, k2 | _] = submitted
      assert :ok = Runner.kill(k1)
      assert :ok = Runner.kill(k2)

      events = await_terminals(rig.bus, submitted)

      assert L.loop_fold_independence(events, baseline) == :ok
      # The killed runs still complete their lifecycle (one terminal each).
      assert L.lifecycle_complete(events, submitted) == :ok
      # No post-kill emission for the killed runs (N-U12.7 positive direction).
      assert L.output_atomic(events) == :ok
    end

    test "a probe drafting a family: :loop event is rejected WHOLE — :error terminal with :family_violation, zero drafted events (N-U12.1)" do
      rig = rig()

      assert {:ok, run_id} =
               Runner.submit("u12-red", LoopDraftProbe, submit_opts(rig, ctx()))

      events = await_terminals(rig.bus, [run_id])

      terminal =
        Enum.find(
          events,
          &(&1.kind == :probe_run and &1.run_id == run_id and
              &1.status in L.terminal_statuses())
        )

      assert terminal,
             "no terminal for the loop-drafting run: #{inspect(events)}"

      assert terminal.status == :error
      assert terminal.reason == :family_violation

      # The WHOLE result is rejected — zero drafted events emitted.
      assert Enum.count(
               events,
               &(&1.kind == :meta_result and &1.run_id == run_id)
             ) == 0

      assert L.family_isolation(events) == :ok
    end
  end

  describe "P-U12.5 provenance stamping (Runner-owned)" do
    test "every result event carries source == :probe_<spec.id> and trust == context.taint ⊓ refs-taint" do
      rig = rig()

      assert {:ok, run_id} =
               Runner.submit(
                 "u12-red",
                 CacheRideProbe,
                 submit_opts(rig, ctx(taint: :trusted))
               )

      events = await_terminals(rig.bus, [run_id])

      results = Enum.filter(events, &(&1.kind == :meta_result))

      assert results != [],
             "no result events — the provenance contour is vacuous"

      assert L.provenance_stamped(events, :probe_c1_gate, :trusted) == :ok
    end

    test "a tainted context produces NO trusted event — even when the probe drafts trust: :trusted (N-U12.6)" do
      rig = rig()

      assert {:ok, run_id} =
               Runner.submit(
                 "u12-red",
                 TaintedTrustProbe,
                 submit_opts(rig, ctx(taint: :tainted))
               )

      events = await_terminals(rig.bus, [run_id])

      results = Enum.filter(events, &(&1.kind == :meta_result))

      assert results != [],
             "no result events — the taint-override contour is vacuous"

      # The Runner overrides the probe's :trusted draft: the algebra is Runner-owned.
      assert L.provenance_stamped(events, :probe_c1_gate, :tainted) == :ok

      refute Enum.any?(results, &(&1.trust == :trusted)),
             "a tainted context produced a trusted event: #{inspect(results)}"
    end

    test "an unregistered probe id stamps :probe_unregistered, never the bare interned atom (adversarial-review #10)" do
      # :probe_notreal IS interned (by UnregisteredSourceProbe) but is not a
      # registered Meta.Registry source, so String.to_existing_atom/1 would
      # resolve it — only the membership check rejects it.
      rig = rig()
      assert UnregisteredSourceProbe.interned_source() == :probe_notreal

      assert {:ok, run_id} =
               Runner.submit(
                 "u12-red",
                 UnregisteredSourceProbe,
                 submit_opts(rig, ctx())
               )

      events = await_terminals(rig.bus, [run_id])
      results = Enum.filter(events, &(&1.kind == :meta_result))

      assert results != [],
             "no result events — the provenance-source contour is vacuous"

      assert Enum.all?(results, &(&1.source == :probe_unregistered)),
             "an unregistered probe id must stamp :probe_unregistered, got #{inspect(results)}"
    end

    test "a TRUSTED context whose drafted ref reaches a tainted record still stamps :tainted (adversarial-review #4)" do
      # The context floor is :trusted, but the draft refs offset 20, and the
      # read-set at 20 is a tainted tool_result. trust = ctx ⊓ refs-taint must
      # absorb to :tainted — the Runner recomputes from the refs via the U11 Meta
      # seam rather than trusting the coarse context floor.
      rig = rig()

      tainted_leaf = %{
        "id" => 20,
        "family" => "loop",
        "type" => "tool_result",
        "provenance" => %{"source" => "surface", "trust" => "tainted"}
      }

      context = ctx(taint: :trusted, tip_offset: 20, read_set: [tainted_leaf])

      assert {:ok, run_id} =
               Runner.submit(
                 "u12-red",
                 CacheRideProbe,
                 submit_opts(rig, context)
               )

      events = await_terminals(rig.bus, [run_id])

      results = Enum.filter(events, &(&1.kind == :meta_result))

      assert results != [],
             "no result events — the refs-taint contour is vacuous"

      # Expected trust is :tainted because ref 20 is tainted (tainted_refs [20]).
      assert L.provenance_stamped(events, :probe_c1_gate, :trusted, [20]) == :ok

      refute Enum.any?(results, &(&1.trust == :trusted)),
             "a trusted context with a tainted ref produced a trusted event: #{inspect(results)}"
    end
  end

  describe "fingerprint (REQUIRED on probe_run terminals)" do
    test "every probe_run terminal carries the model/params fingerprint" do
      rig = rig()

      submitted =
        for probe <- [CacheRideProbe, MultiCallProbe] do
          assert {:ok, run_id} =
                   Runner.submit("u12-red", probe, submit_opts(rig, ctx()))

          run_id
        end

      events = await_terminals(rig.bus, submitted)
      assert L.fingerprint_present(events) == :ok

      for %{kind: :probe_run, status: s, fingerprint: fp} <- events,
          s in L.terminal_statuses() do
        assert %{provider: p, name: n, params_hash: h, params_inline: inline} =
                 fp

        assert is_binary(p) and is_binary(n) and is_binary(h) and is_map(inline)
      end
    end
  end
end

defmodule Raxol.Agent.Red.U12ProbeRunnerControlsTest do
  @moduledoc """
  Negative controls for U12-R (meta-invariant m4). NO `:harness_red` tag — these
  RUN IN CI and must stay GREEN. Each dead injector is a one-mutation wrong
  Runner implementation (one per N-U12.x); its matching checker MUST flag
  it. A final pair proves the checkers pass a well-formed trace (the controls
  are not vacuously red) and that the m1 fired-counter itself catches a dead
  injector (dumping the seed-reproducible schedule, m2).
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Red.ProbeRunnerLab, as: L

  alias Raxol.Agent.Red.ProbeRunnerLab.{
    FamilyCheckRemovedRunner,
    HonorsProbeTrustRunner,
    LoopPerturbingRunner,
    NoFingerprintRunner,
    PostKillLeakRunner,
    ProbeControlledLeashRunner,
    ReferenceRunner,
    ReserializingPrefixRunner,
    SessionLeakRunner,
    SettleOnlyRunner,
    SilentDropRunner,
    StreamingDraftsRunner,
    TerminalCountRunner,
    UnboundedParkingRunner
  }

  @seed String.to_integer(System.get_env("U12_SEED", "424242"))

  defp rig(opts \\ []) do
    %{
      bus: L.new_bus(),
      provider: L.new_provider(),
      budget: L.new_budget(Keyword.get(opts, :cap, 1_000)),
      fireset: L.new_fireset()
    }
  end

  test "DEAD INJECTOR N-U12.1: family-check-removed Runner emits a loop draft — flagged by FAMILY-ISOLATION" do
    rig = rig()
    L.arm(rig.fireset, :family_check_removed)

    FamilyCheckRemovedRunner.run(rig, "r1")
    events = L.events(rig.bus)

    assert {:error, {:family_violation_emitted, "r1", :loop}} =
             L.family_isolation(events)

    L.assert_all_fired!(rig.fireset, [:family_check_removed])
  end

  test "DEAD INJECTOR N-U12.2: settle-only Runner (call before any reserve) — flagged by RESERVE-BEFORE-CALL" do
    rig = rig()
    L.arm(rig.fireset, :settle_only)

    SettleOnlyRunner.run(rig, "r1")
    events = L.events(rig.bus)

    assert {:error, {:bad_order, "r1", kinds, :call_without_reserve}} =
             L.reserve_before_call(events)

    assert kinds == [:call, :settle]

    # The provider WAS invoked with zero reserves — the stub counter has the proof.
    assert L.provider_calls(rig.provider) == 1

    assert {:error, {:provider_calls, 1, 0}} =
             L.fail_closed(L.provider_calls(rig.provider), 0)

    L.assert_all_fired!(rig.fireset, [:settle_only])
  end

  test "DEAD INJECTOR N-U12.3: silent-drop submit (ok returned, nothing emitted) — flagged by LIFECYCLE/DROPPED" do
    rig = rig()
    L.arm(rig.fireset, :silent_drop)

    # The injector "accepts" the run and emits nothing at all.
    SilentDropRunner.run(rig, "r1")
    events = L.events(rig.bus)

    assert events == []
    assert {:error, {:dropped, "r1"}} = L.lifecycle_complete(events, ["r1"])
    L.assert_all_fired!(rig.fireset, [:silent_drop])
  end

  test "DEAD INJECTOR N-U12.4: probe-controlled leash makes max_calls+1 provider calls — flagged by LEASH" do
    rig = rig()
    L.arm(rig.fireset, :probe_leash)
    max_calls = 2

    ProbeControlledLeashRunner.run(rig, "r1", max_calls)

    assert L.provider_calls(rig.provider) == max_calls + 1

    assert {:error, {:leash_exceeded, 3, 2}} =
             L.leash_enforced(L.provider_calls(rig.provider), max_calls)

    L.assert_all_fired!(rig.fireset, [:probe_leash])
  end

  test "DEAD INJECTOR N-U12.5: re-serializing prefix builder — flagged by PREFIX-IDENTITY with the divergent byte offset" do
    rig = rig()
    L.arm(rig.fireset, :reserialize_prefix)

    ReserializingPrefixRunner.run(rig, "r1")
    captures = L.captures(rig.provider)

    assert [_] = captures

    assert {:error, {:prefix_divergence, offset, "r1"}} =
             L.prefix_identity(captures, L.primary_prefix())

    # The 1-byte divergence is NAMED: the offset points at the first divergent
    # byte (the collapsed double space inside "hi  there").
    expected =
      L.first_divergent_offset(L.primary_prefix(), L.reserialized_prefix())

    assert offset == expected
    assert offset > 0

    assert binary_part(L.primary_prefix(), offset, 1) !=
             binary_part(L.reserialized_prefix(), offset, 1)

    L.assert_all_fired!(rig.fireset, [:reserialize_prefix])
  end

  test "DEAD INJECTOR N-U12.6: Runner honoring probe-drafted trust under a tainted context — flagged by PROVENANCE" do
    rig = rig()
    L.arm(rig.fireset, :honors_probe_trust)

    HonorsProbeTrustRunner.run(rig, "r1")
    events = L.events(rig.bus)

    assert {:error, {:trust_not_absorbed, "r1", :trusted, :tainted}} =
             L.provenance_stamped(events, :probe_c1_gate, :tainted)

    L.assert_all_fired!(rig.fireset, [:honors_probe_trust])
  end

  test "DEAD INJECTOR N-U12.7: kill leaking a post-kill drafted event — flagged by LIFECYCLE/POST-TERMINAL" do
    rig = rig()
    L.arm(rig.fireset, :post_kill_leak)

    PostKillLeakRunner.run(rig, "r1")
    events = L.events(rig.bus)

    assert {:error, {:post_terminal, "r1"}} = L.lifecycle_complete(events)
    L.assert_all_fired!(rig.fireset, [:post_kill_leak])
  end

  test "DEAD INJECTOR N-U12.8a: double-emitted terminal (re-emit after :completed) — flagged by LIFECYCLE" do
    rig = rig()
    L.arm(rig.fireset, :terminal_count)

    TerminalCountRunner.run(rig, "r1", :double)
    events = L.events(rig.bus)

    assert {:error, reason} = L.lifecycle_complete(events)

    assert match?({:lifecycle, "r1", %{terminals: 2}}, reason) or
             match?({:post_terminal, "r1"}, reason),
           "a double terminal must fail the fold, got #{inspect(reason)}"

    L.assert_all_fired!(rig.fireset, [:terminal_count])
  end

  test "DEAD INJECTOR N-U12.8b: omitted terminal (process freed, no terminal ever) — flagged by LIFECYCLE" do
    rig = rig()
    L.arm(rig.fireset, :terminal_count)

    TerminalCountRunner.run(rig, "r1", :omit)
    events = L.events(rig.bus)

    assert {:error, {:lifecycle, "r1", %{openings: 1, terminals: 0}}} =
             L.lifecycle_complete(events)

    L.assert_all_fired!(rig.fireset, [:terminal_count])
  end

  test "DEAD INJECTOR N-U12.9: streaming-drafts Runner (k of n emitted, then exhaustion) — flagged by ATOMICITY" do
    rig = rig()
    L.arm(rig.fireset, :streaming_drafts)

    StreamingDraftsRunner.run(rig, "r1", 2)
    events = L.events(rig.bus)

    assert {:error, {:partial_output, "r1", 2}} = L.output_atomic(events)
    L.assert_all_fired!(rig.fireset, [:streaming_drafts])
  end

  test "DEAD INJECTOR N-U12.10: no-cap/no-TTL Runner parks unbounded — flagged by BOUNDED-PARKING (seed-reproducible)" do
    rig = rig()
    L.arm(rig.fireset, :unbounded_parking)
    max_parked = 4

    :rand.seed(:exsss, {@seed, 10, @seed})
    n = max_parked + :rand.uniform(6) + 1
    run_ids = Enum.map(1..n, &"r#{&1}")

    UnboundedParkingRunner.run(rig, run_ids)
    events = L.events(rig.bus)

    assert {:error, {:parked_overflow, peak, ^max_parked}} =
             L.bounded_parking(events, max_parked)

    assert peak == n, "seed=#{@seed}: schedule=#{inspect(run_ids)}"
    L.assert_all_fired!(rig.fireset, [:unbounded_parking])
  end

  test "DEAD INJECTOR (isolation): a probe crash perturbing the primary trace — flagged by LOOP-FOLD-INDEPENDENCE" do
    rig = rig()
    L.arm(rig.fireset, :loop_perturb)
    baseline = [:turn_started, :item_completed, :turn_completed]

    LoopPerturbingRunner.run(rig, "r1", baseline)
    events = L.events(rig.bus)

    assert {:error, {:isolation_breach, got, ^baseline}} =
             L.loop_fold_independence(events, baseline)

    assert got == baseline ++ [:probe_injected]
    L.assert_all_fired!(rig.fireset, [:loop_perturb])
  end

  test "DEAD INJECTOR (fingerprint): terminal without the REQUIRED fingerprint — flagged by FINGERPRINT-PRESENT" do
    rig = rig()
    L.arm(rig.fireset, :no_fingerprint)

    NoFingerprintRunner.run(rig, "r1")
    events = L.events(rig.bus)

    assert {:error, {:missing_fingerprint, "r1"}} =
             L.fingerprint_present(events)

    L.assert_all_fired!(rig.fireset, [:no_fingerprint])
  end

  test "DEAD INJECTOR OQ-U12.1: session-leak Runner (run refused, session NOT released) — flagged by BUDGET-CONSERVED" do
    rig = rig()
    L.arm(rig.fireset, :session_leak)
    session_budget = L.new_budget(100)
    run_budget = L.new_budget(0)

    SessionLeakRunner.run(
      %{
        bus: rig.bus,
        session_budget: session_budget,
        budget: run_budget,
        fireset: rig.fireset
      },
      "r1"
    )

    # The session reservation leaked: reserved stayed at 100 instead of rolling
    # back to 0.
    assert {:error, {:session_leaked, 100, 0}} =
             L.budget_conserved(session_budget, 0)

    L.assert_all_fired!(rig.fireset, [:session_leak])
  end

  test "the checkers PASS a well-formed trace (controls are not vacuously red)" do
    rig = rig()
    tip = 41
    ReferenceRunner.run(rig, "r1", :trusted, tip)
    events = L.events(rig.bus)

    assert L.lifecycle_complete(events, ["r1"]) == :ok
    assert L.reserve_before_call(events) == :ok
    assert L.fail_closed(L.provider_calls(rig.provider), 1) == :ok
    assert L.leash_enforced(L.provider_calls(rig.provider), 1) == :ok

    assert L.prefix_identity(L.captures(rig.provider), L.primary_prefix()) ==
             :ok

    assert L.family_isolation(events) == :ok
    assert L.provenance_stamped(events, :probe_c1_gate, :trusted) == :ok
    assert L.output_atomic(events) == :ok
    assert L.bounded_parking(events, 4) == :ok
    assert L.fingerprint_present(events) == :ok
  end

  test "a tainted well-formed trace also passes (trust absorbed, not vacuous in the tainted direction)" do
    rig = rig()
    ReferenceRunner.run(rig, "r1", :tainted, 41)
    events = L.events(rig.bus)

    assert L.provenance_stamped(events, :probe_c1_gate, :tainted) == :ok

    # And the trusted expectation FAILS against it — the checker discriminates.
    assert {:error, {:trust_not_absorbed, "r1", :tainted, :trusted}} =
             L.provenance_stamped(events, :probe_c1_gate, :trusted)
  end

  test "m1: an armed injector that never fires fails assert_all_fired! and dumps the schedule (m2)" do
    fs = L.new_fireset()
    L.arm(fs, :settle_only)
    L.arm(fs, :unbounded_parking)
    L.fire(fs, :settle_only)

    err =
      assert_raise ExUnit.AssertionError, fn ->
        L.assert_all_fired!(fs, [:the, :schedule, @seed])
      end

    assert err.message =~ "dead injector"
    assert err.message =~ "unbounded_parking"
    refute err.message =~ ~r/never fired: \[.*settle_only/
    assert err.message =~ "[:the, :schedule, #{@seed}]"
  end
end
