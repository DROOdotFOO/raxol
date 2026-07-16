defmodule Raxol.Agent.Probe.Runner.Pool do
  @moduledoc """
  The in-BEAM Runner Pool backing `Raxol.Agent.Probe.Runner` (roadmap D2).

  A single serialized coordinator owns the run registry (`run_id → state`), the
  per-pool bounded parked set, and the kill↔finalize ordering. Each budget-OK
  run executes in its own linked `Task` (isolation by construction, §3.1); the
  Task rides the shared prefix through the injected provider, reserves before
  every call against the injected budget, and hands its result back through the
  coordinator so a concurrent `kill/1` deterministically wins the race
  (no post-kill emission, N-U12.7).

  This module is the U12 *seam wiring*: `submit/3`'s `opts` carry the injectable
  `:emit` / `:provider` / `:budget` (+ optional `:session_budget`) so the U12-R
  red suite folds them in-memory; production binds the journal / EmitBridge and
  the real provider / Ledger to the same seam.

  ## Process model — UNSUPERVISED lazy singleton (not yet supervised)

  The pool is a lazily-started, **unsupervised** named singleton: `ensure_started/0`
  calls `GenServer.start` (NOT `start_link`, and not under any supervisor), so it
  is unlinked from every caller. If a **coordinator-context** emit fails loudly
  (a genuine, non-`:noproc` journal/EmitBridge write error raised from inside a
  `handle_call`, e.g. `emit_opening/4` under `submit/3`), the coordinator crashes
  and its in-memory state — the run registry and parked set — is LOST; the next
  `submit/3` lazily restarts it. In-flight runs at that instant get **no in-band
  terminal** (the coordinator that would emit it is gone, and their Tasks then hit
  `:noproc` on the next `GenServer.call(parent, …)` and die silently).

  This is acceptable ONLY because the **journal is the durability authority**
  (§3.1 reserve-before-call / fail-closed), not the in-memory Pool state: every
  terminal is journaled as it is emitted, so the map is a cache, not the record.
  Lifecycle closure for a run orphaned by a coordinator crash therefore comes from
  **journal replay at recovery** (external to this module — the journal owner
  reconciles a run that opened but never reached a journaled terminal), NOT from
  this process.

  **Documented follow-ups (production wiring, deliberately NOT done here):**
    * Supervise the pool (a `start_link` under a supervisor) so a coordinator
      crash restarts it eagerly and orphaned Tasks are cleaned up, rather than the
      current lazy-restart-on-next-submit.
    * GC terminated runs — `state.runs` is currently append-only (see
      `put_run/3`), so a long-lived singleton grows unbounded; a TTL/cap is needed
      once `status/1`/`kill/1` no longer need to answer for old run_ids.

  ## Stub vs. production values

  Bound to the lab's in-memory seams, three helpers here return **placeholder**
  data, NOT real usage — a maintainer should read them as stubs pending the
  production `:provider` / Ledger / `Fingerprint` binding: `provider_invoke/3`
  (the lab call-counter shape; the real provider replaces it), `charge/1` (the
  frozen `100/90/12` split fixture; real settlement fills actuals), and
  `fingerprint/0` (a literal `anthropic`/`claude`/seed-7 fixture; the real model
  identity replaces it). The red suite deliberately pins only the SHAPE of these
  (key set, `cached ≤ prompt`, fingerprint fields) — value-level pinning against
  observed provider usage is production-binding work, not part of the D2 seam.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Fingerprint
  alias Raxol.Agent.Meta

  # Per-provider-call token reserve (the SpendGate/`Ledger.try_spend` unit,
  # AD-6a). The lab pins "cap fits exactly one 100-token reserve" — the reserve
  # AMOUNT is the frozen budget observable, not the emitted estimate value.
  @reserve_estimate 100

  # A parked run's terminal shape carries no successful-call spend.
  @zero_charge %{prompt_tokens: 0, cached_prompt_tokens: 0, completion_tokens: 0, calls: 0}

  # Kill-grace: a budget-OK run yields this long before its first side effect so
  # a synchronous `kill/1` deterministically preempts it mid-flight (N-U12.7 /
  # P-U12.4). Small enough to stay well inside the suite's terminal awaits.
  @kill_grace_ms 25

  @opening [:started, :parked]
  @terminal [:completed, :killed, :exhausted, :timeout, :error]

  # ---------------------------------------------------------------------------
  # public API (called by Raxol.Agent.Probe.Runner)
  # ---------------------------------------------------------------------------

  @spec submit(String.t(), module(), keyword()) ::
          {:ok, String.t()} | {:error, :unknown_probe}
  def submit(session_id, probe, opts) do
    ensure_started()
    GenServer.call(__MODULE__, {:submit, session_id, probe, opts})
  end

  @spec kill(String.t()) :: :ok | {:error, :not_found}
  def kill(run_id) do
    ensure_started()
    GenServer.call(__MODULE__, {:kill, run_id})
  end

  @spec status(String.t()) :: {:ok, atom()} | {:error, :not_found}
  def status(run_id) do
    ensure_started()
    GenServer.call(__MODULE__, {:status, run_id})
  end

  # Internal callbacks from the run Task.
  @doc false
  def checkpoint(run_id), do: GenServer.call(__MODULE__, {:checkpoint, run_id})

  @doc false
  def finalize(run_id, result), do: GenServer.call(__MODULE__, {:finalize, run_id, result})

  # Lazy, idempotent start — the pool is an UNSUPERVISED singleton in-BEAM
  # coordinator. `GenServer.start` (not `start_link`, not under a supervisor): it
  # is unlinked, so a caller crash never takes the pool down and the pool's own
  # crash never takes a caller down; on crash the next submit lazily restarts it
  # (see the moduledoc process model — the journal is the durability authority,
  # in-flight runs get no in-band terminal, closure comes from journal replay).
  @doc false
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  # Debounce after a max_parked overflow before the oldest held parked run sheds
  # to :exhausted (reason :pressure) (bounded parking under sustained pressure,
  # N-U12.10). Short enough to land inside the suite's terminal awaits, long
  # enough to batch a burst.
  @pressure_shed_ms 40

  @impl true
  def init(_), do: {:ok, %{runs: %{}, parked: %{}}}

  @impl true
  def handle_call({:submit, _session_id, probe, opts}, _from, state) do
    if valid_probe?(probe) do
      do_submit(probe, opts, state)
    else
      {:reply, {:error, :unknown_probe}, state}
    end
  end

  def handle_call({:kill, run_id}, _from, state) do
    case Map.get(state.runs, run_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: :running, killed: false, emit: emit, spec: spec} = run ->
        # TERMINATE the run Task (mirroring the :run_timeout leash): a killed run
        # must make no further provider call and emit NOTHING after its :killed
        # terminal (N-U12.7). A cooperative flag cannot stop an already-in-flight
        # call's `:call`/`:settle` accounting from racing past the terminal at the
        # bus; killing the process is the deterministic stop — spend halts at the
        # call boundary and no post-terminal event can be emitted (the reserve seam
        # `:reserve_next` additionally refuses any reserve the dead Task might have
        # had in flight, #1).
        case Map.get(run, :task_pid) do
          pid when is_pid(pid) -> Process.exit(pid, :kill)
          _ -> :ok
        end

        # :killed charges @zero_charge (< every reserve the run took): release the
        # FULL held reserve (`run.reserved` accrues each per-call grant, #1) so the
        # budget's reserved counter tracks the authoritative charge (F5, #5) and no
        # mid-multi-call reserve is stranded.
        cancel_timeout(run)
        release_reserve(run)
        emit_terminal(emit, run_id, spec.id, :killed, @zero_charge, nil)
        {:reply, :ok, put_run(state, run_id, %{run | status: :killed, killed: true, reserved: 0})}

      %{status: :parked, killed: false, emit: emit, spec: spec, key: key, park_ref: park_ref} =
          run ->
        # Kill on a PARKED run must NOT be a silent no-op (the old clause matched
        # only :running, so a parked run replied :ok with no terminal and later
        # shed :exhausted — a phantom double lifecycle). Evict it: cancel the TTL
        # timer so no shed terminal follows, drop it from the parked set, emit the
        # single :killed terminal (#3).
        Process.cancel_timer(park_ref)

        emit_terminal(emit, run_id, spec.id, :killed, @zero_charge, nil)

        state =
          state
          |> put_run(run_id, %{run | status: :killed, killed: true})
          |> Map.update(:parked, %{}, fn sets ->
            Map.update(sets, key, MapSet.new(), &MapSet.delete(&1, run_id))
          end)

        {:reply, :ok, state}

      _already_terminal ->
        # Idempotent: a run past its terminal is not re-killed (no double emit).
        {:reply, :ok, state}
    end
  end

  def handle_call({:status, run_id}, _from, state) do
    case Map.get(state.runs, run_id) do
      nil -> {:reply, {:error, :not_found}, state}
      %{status: s} -> {:reply, {:ok, s}, state}
    end
  end

  def handle_call({:checkpoint, run_id}, _from, state) do
    case Map.get(state.runs, run_id) do
      %{killed: false, status: :running} -> {:reply, :continue, state}
      _ -> {:reply, :killed, state}
    end
  end

  def handle_call({:finalize, run_id, result}, _from, state) do
    case Map.get(state.runs, run_id) do
      %{killed: false, status: :running} = run ->
        {:reply, :ok, apply_result(state, run_id, run, result)}

      _killed_or_gone ->
        # A kill won the race: drop the result whole (no post-kill emission).
        {:reply, :ok, state}
    end
  end

  # Per-call reserve seam for the run Task's multi-call loop (calls 2..max_calls;
  # call 1 rides the submit-time reserve). Serialized in the coordinator with
  # `kill/1` so the two never interleave:
  #
  #   * a RUNNING run reserves `amount` at both budget levels and the grant is
  #     accrued onto `run.reserved` (cumulative) — so the eventual terminal
  #     releases EVERY reserve the run took, not just the submit-time one (#1).
  #   * a killed / timed-out / already-terminal / gone run is REFUSED, so the loop
  #     exits without reserving OR calling the provider again — spend stops at the
  #     call boundary after the in-flight call (#1, N-U12.7 in the budget domain).
  def handle_call({:reserve_next, run_id, amount}, _from, state) do
    case Map.get(state.runs, run_id) do
      %{status: :running, killed: false, budget: budget, session_budget: session_budget} = run ->
        case reserve_two_level(session_budget, budget, amount) do
          :ok ->
            {:reply, :ok, put_run(state, run_id, %{run | reserved: run.reserved + amount})}

          {:over, reason} ->
            {:reply, {:over, reason}, state}
        end

      _killed_or_gone ->
        {:reply, {:over, :killed}, state}
    end
  end

  # A held parked run reached park_timeout_ms without being served → shed to
  # :exhausted (parking is never indefinite, §3.1 Budget / test 298).
  @impl true
  def handle_info({:park_ttl, run_id, key}, state) do
    {:noreply, shed_held(state, run_id, key, :exhausted, :park_timeout)}
  end

  # A max_parked overflow signalled sustained budget pressure. Shed only ONE
  # run — the OLDEST still-held parked run for this pool — per overflow, NOT the
  # entire parked set (the old code nuked every parked run on a single overflow).
  # The evicted run terminates `:exhausted` (the contract's park-eviction
  # observable: "the oldest/over-TTL parked runs shed to :exhausted", §3.1
  # Budget / N-U12.10) — NOT `:timeout`, which is reserved for the wall-clock
  # leash (#2, #7). One overflow relieves one slot; sustained overflow relieves
  # proportionally, so surviving parked runs keep waiting for a slot or their TTL.
  def handle_info({:pressure_shed, key}, state) do
    held = Map.get(state.parked, key, MapSet.new())

    state =
      case oldest_held(held) do
        nil -> state
        run_id -> shed_held(state, run_id, key, :exhausted, :pressure)
      end

    {:noreply, state}
  end

  # Wall-clock leash fired (#2): kill a still-running run, release its reserve,
  # and emit the :timeout terminal. Setting the status here means the subsequent
  # :DOWN (reason :killed) finds a non-:running run and is a no-op — no double
  # terminal. A run that already reached a terminal (its timer was cancelled but
  # the message had already been queued) is left untouched.
  def handle_info({:run_timeout, run_id}, state) do
    case Map.get(state.runs, run_id) do
      %{status: :running, killed: false, emit: emit, spec: spec} = run ->
        case Map.get(run, :task_pid) do
          pid when is_pid(pid) -> Process.exit(pid, :kill)
          _ -> :ok
        end

        release_reserve(run)
        emit_terminal(emit, run_id, spec.id, :timeout, @zero_charge, :timeout_ms)
        {:noreply, put_run(state, run_id, %{run | status: :timeout, killed: true, reserved: 0})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state)
      when reason in [:normal, :shutdown] do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # A crashed run Task yields a :error terminal and touches nothing else.
    case Enum.find(state.runs, fn {_id, r} -> Map.get(r, :task_pid) == pid end) do
      {run_id, %{status: :running, killed: false, emit: emit, spec: spec} = run} ->
        Logger.debug("probe run #{run_id} crashed: #{inspect(reason)}")
        cancel_timeout(run)
        release_reserve(run)
        emit_terminal(emit, run_id, spec.id, :error, @zero_charge, :crash)
        {:noreply, put_run(state, run_id, %{run | status: :error, reserved: 0})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # submit paths
  # ---------------------------------------------------------------------------

  defp do_submit(probe, opts, state) do
    run_id = gen_run_id()
    emit = Keyword.fetch!(opts, :emit)
    provider = Keyword.get(opts, :provider)
    budget = Keyword.get(opts, :budget)
    session_budget = Keyword.get(opts, :session_budget)
    context = Keyword.get(opts, :context, %{})
    spec = probe.spec()

    case reserve_two_level(session_budget, budget, @reserve_estimate) do
      :ok ->
        emit_opening(emit, run_id, spec.id, :started)

        run = %{
          status: :running,
          killed: false,
          emit: emit,
          spec: spec,
          context: context,
          # Budget handles + the running total of reserve HELD. It starts at the
          # submit-time reserve and accrues each per-call grant (`:reserve_next`);
          # every terminal SETTLES it back to the budget, so the reserved counter
          # returns to baseline (completed) or releases the full stranded amount
          # (under-charge kill/timeout) — never diverging from the authoritative
          # charge (F5, #1).
          budget: budget,
          session_budget: session_budget,
          reserved: @reserve_estimate
        }

        state = put_run(state, run_id, run)

        state =
          spawn_work(state, run_id, probe, spec, context, provider, budget, session_budget, emit)

        # Wall-clock leash (#2): a hung provider_invoke / build / interpret would
        # otherwise hold the reserve forever and never emit a terminal (lifecycle
        # incompleteness). Arm a timer; on fire, the run is killed and gets its
        # :timeout terminal. Cancelled by every other terminal path.
        timeout_ref = Process.send_after(self(), {:run_timeout, run_id}, spec.timeout_ms)

        state =
          put_run(state, run_id, Map.put(Map.get(state.runs, run_id), :timeout_ref, timeout_ref))

        {:reply, {:ok, run_id}, state}

      {:over, _reason} ->
        # Reserve refused at the submit-time budget check → the run PARKS
        # (never fails submit, never drops silently — N-U12.3). Bounded by
        # max_parked (F5): if the parked set is full the run sheds :exhausted
        # WITHOUT parking (parking precedence, §3.3).
        state = park_or_shed(state, run_id, spec, budget, emit)
        {:reply, {:ok, run_id}, state}
    end
  end

  defp park_or_shed(state, run_id, spec, budget, emit) do
    key = pool_key(budget)
    held = Map.get(state.parked, key, MapSet.new())

    if MapSet.size(held) < spec.max_parked do
      # Room in the parked set: PARK and HOLD. The run occupies a slot until it
      # sheds — at park_timeout_ms → :exhausted (reason :park_timeout, P-U12.10
      # TTL), or EARLY to :exhausted (reason :pressure) when a max_parked overflow
      # signals sustained budget pressure. A held run has no terminal yet; that is
      # the observable "parked" state.
      emit_opening(emit, run_id, spec.id, :parked)
      park_ref = Process.send_after(self(), {:park_ttl, run_id, key}, spec.park_timeout_ms)

      # A parked run holds NO reserve (its reserve was refused — that is why it
      # parked), so `reserved: 0`. `key`/`park_ref` let `kill/1` evict it and
      # cancel its TTL so no shed terminal follows the :killed one (#3).
      run = %{
        status: :parked,
        killed: false,
        emit: emit,
        spec: spec,
        budget: budget,
        key: key,
        park_ref: park_ref,
        reserved: 0
      }

      state
      |> put_run(run_id, run)
      |> Map.update!(:parked, &Map.put(&1, key, MapSet.put(held, run_id)))
    else
      # Parked set full → max_parked DOMINATES: this run cannot park, so it
      # terminates :exhausted (never :parked — §3.3 parking precedence). The
      # overflow is the pressure signal: schedule the OLDEST held run to shed to
      # :exhausted (reason :pressure) so the parked set never grows without bound
      # (N-U12.10).
      emit_opening(emit, run_id, spec.id, :started)
      emit_terminal(emit, run_id, spec.id, :exhausted, @zero_charge, :max_parked)
      Process.send_after(self(), {:pressure_shed, key}, @pressure_shed_ms)
      put_run(state, run_id, %{status: :exhausted, killed: false, emit: emit, spec: spec})
    end
  end

  # Shed a still-held parked run to a terminal status, releasing its slot. A run
  # that already terminated (killed, or a prior shed) is left untouched — exactly
  # one terminal per run (P-U12.1).
  # The oldest still-held parked run in `held`, by monotonic run_id order (the
  # gen_run_id suffix is a monotonic integer, so the smallest is the oldest), or
  # nil when the set is empty. Used to shed the single oldest run per overflow.
  defp oldest_held(held) do
    if Enum.empty?(held), do: nil, else: Enum.min_by(held, &run_seq/1)
  end

  defp run_seq(run_id) do
    run_id |> String.split("-") |> List.last() |> String.to_integer()
  end

  defp shed_held(state, run_id, key, status, reason) do
    case Map.get(state.runs, run_id) do
      %{status: :parked, emit: emit, spec: spec} = run ->
        # A parked run holds no reserve (reserved: 0), so this is a no-op; kept
        # for symmetry with the other under-charge terminals (#5).
        release_reserve(run)
        emit_terminal(emit, run_id, spec.id, status, @zero_charge, reason)

        state
        |> put_run(run_id, %{run | status: status})
        |> Map.update(:parked, %{}, fn sets ->
          Map.update(sets, key, MapSet.new(), &MapSet.delete(&1, run_id))
        end)

      _ ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # the run Task (budget-OK path)
  # ---------------------------------------------------------------------------

  defp spawn_work(state, run_id, probe, spec, context, provider, budget, session_budget, emit) do
    parent = self()

    {pid, _ref} =
      spawn_monitor(fn ->
        # Yield so a synchronous kill preempts before any side effect.
        Process.sleep(@kill_grace_ms)

        case GenServer.call(parent, {:checkpoint, run_id}) do
          :killed ->
            :ok

          :continue ->
            args = %{
              run_id: run_id,
              parent: parent,
              probe: probe,
              spec: spec,
              context: context,
              provider: provider,
              budget: budget,
              session_budget: session_budget,
              emit: emit,
              prefix: rideable_prefix(context)
            }

            result = run_calls(args)
            GenServer.call(parent, {:finalize, run_id, result})
        end
      end)

    put_run(state, run_id, Map.put(Map.get(state.runs, run_id), :task_pid, pid))
  end

  # Reserve→call→settle per call, up to max_calls; the first reserve was already
  # consumed at submit. Returns the run outcome (interpreted, never emitted here
  # — the coordinator emits it atomically so kill can veto).
  defp run_calls(%{run_id: run_id, emit: emit} = args) do
    # Call 1 (reserve already held from submit — record the reserve event).
    emit_acct(emit, run_id, :reserve, @reserve_estimate, nil)
    {resp1, calls1} = one_call(args)
    more_calls(args, resp1, calls1)
  end

  # Calls 2..max_calls: reserve-before-call; a mid-run refusal ends :exhausted
  # (atomic output — no drafts). At max_calls the Runner-owned leash stops.
  defp more_calls(%{spec: spec} = args, last_resp, made) when made >= spec.max_calls do
    interpret_result(args.probe, args.context, last_resp, made)
  end

  defp more_calls(%{run_id: run_id, parent: parent, emit: emit} = args, last_resp, made) do
    # Reserve through the coordinator, NOT the budget directly (as call 1 does at
    # submit). The Pool serializes this reserve with any concurrent `kill/1`, so a
    # LATE kill (past @kill_grace_ms, mid multi-call) STOPS spend at the call
    # boundary (#1): a killed/terminal run is REFUSED here, the loop exits per the
    # existing `{:over, _}` semantics, no further provider call is made, and
    # `finalize` drops the outcome (the kill already won). A reserve granted in the
    # kill race is TRACKED on the run (`reserved += amount`) so the kill RELEASES
    # it — never dropped. `{:over, :over_budget}` (the real budget refusal) is
    # unchanged: mid-run exhaustion.
    case GenServer.call(parent, {:reserve_next, run_id, @reserve_estimate}) do
      {:over, _} ->
        {:exhausted, made}

      :ok ->
        emit_acct(emit, run_id, :reserve, @reserve_estimate, nil)
        {resp, calls} = one_call(args)
        more_calls(args, resp || last_resp, made + calls)
    end
  end

  defp one_call(%{
         run_id: run_id,
         probe: probe,
         context: context,
         provider: provider,
         prefix: prefix,
         emit: emit
       }) do
    case probe.build(context) do
      :skip ->
        {nil, 0}

      {:ok, req} ->
        request = %{prefix: prefix, suffix: Map.get(req, :suffix, [])}
        resp = provider_invoke(provider, run_id, request)
        emit_acct(emit, run_id, :call, nil, nil)
        emit_acct(emit, run_id, :settle, nil, actual(resp))
        {resp, 1}
    end
  end

  defp interpret_result(probe, context, response, calls) do
    case probe.interpret(response || %{}, context) do
      {:error, _reason} ->
        {:error_run, calls}

      {:ok, drafts} when is_list(drafts) ->
        cond do
          Enum.any?(drafts, &(Map.get(&1, :family, :meta) != :meta)) ->
            {:family_violation, calls}

          true ->
            {:completed, drafts, calls}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # applying a run outcome (coordinator-owned, atomic, kill-vetoable)
  # ---------------------------------------------------------------------------

  defp apply_result(state, run_id, %{emit: emit, spec: spec} = run, result) do
    # The run reached its own terminal before the wall-clock leash — disarm it so
    # a queued {:run_timeout} cannot double-emit (the status guard also protects,
    # this just avoids the stale message).
    cancel_timeout(run)

    # SETTLE: release every reserve the run held (the per-call HOLD is settled at
    # the terminal; the authoritative spend is the emitted `charge`). This runs on
    # ALL of the Task's own terminals — :completed included, not just the
    # under-charge ones — so the budget's outstanding-reservation counter returns
    # to baseline and does NOT grow monotonically across a session (a completed
    # 2-call run reserves 200 and must release 200, not 0). The kill/timeout/crash
    # paths settle in their own handlers.
    release_reserve(run)
    run = %{run | reserved: 0}
    taint = context_taint(run)
    read_set = context_read_set(run)

    case result do
      {:completed, drafts, calls} ->
        Enum.each(drafts, fn draft ->
          emit_meta_result(emit, run_id, spec.id, draft, taint, read_set)
        end)

        emit_terminal(emit, run_id, spec.id, :completed, charge(calls), nil)
        put_run(state, run_id, %{run | status: :completed})

      {:exhausted, calls} ->
        emit_terminal(emit, run_id, spec.id, :exhausted, charge(calls), :budget_exhausted)
        put_run(state, run_id, %{run | status: :exhausted})

      {:family_violation, calls} ->
        emit_terminal(emit, run_id, spec.id, :error, charge(calls), :family_violation)
        put_run(state, run_id, %{run | status: :error})

      {:error_run, calls} ->
        emit_terminal(emit, run_id, spec.id, :error, charge(calls), :interpret_error)
        put_run(state, run_id, %{run | status: :error})
    end
  end

  # ---------------------------------------------------------------------------
  # emit helpers (the frozen record shapes the checkers fold)
  # ---------------------------------------------------------------------------

  # A test's ephemeral sink (bus Agent) can die while a run from that test is
  # still in flight in this shared singleton pool. Emitting into that dead sink
  # exits `:noproc` (or `{:noproc, _}` from the wrapped `GenServer.call`); that —
  # and ONLY that — is benign, because the owning test is gone so there is
  # nothing left to observe.
  #
  # Every OTHER emit failure is a genuine journal / EmitBridge write error and
  # MUST surface, never be silently swallowed: a run whose terminal is dropped
  # would live in Pool state yet never be journaled, breaking the durability
  # story (§3.1 reserve-before-call / fail-closed — the journal is the authority,
  # not in-memory Pool state). A raised error propagates; a non-`:noproc` exit
  # propagates. In the run-Task context that crashes the Task, which the coord's
  # `:DOWN` handler turns into the run's `:error` terminal (still exactly one
  # terminal). In the coordinator context it crashes the UNSUPERVISED pool
  # coordinator loudly (the singleton dies and lazily restarts on next submit; its
  # in-flight runs get no in-band terminal — see the moduledoc process model): the
  # journal, not the lost in-memory state, is the record, so failing loud and
  # losing the cache beats silently dropping a journal write.
  defp safe_emit(emit, event) do
    emit.(event)
    :ok
  catch
    :exit, reason when reason == :noproc or (is_tuple(reason) and elem(reason, 0) == :noproc) ->
      :ok
  end

  defp emit_opening(emit, run_id, probe_id, status) when status in @opening do
    safe_emit(emit, %{
      kind: :probe_run,
      run_id: run_id,
      probe: probe_id,
      status: status,
      charge: nil,
      refs: [],
      fingerprint: nil,
      reason: nil
    })
  end

  defp emit_terminal(emit, run_id, probe_id, status, charge, reason) when status in @terminal do
    safe_emit(emit, %{
      kind: :probe_run,
      run_id: run_id,
      probe: probe_id,
      status: status,
      charge: charge,
      refs: [],
      fingerprint: fingerprint(),
      reason: reason
    })
  end

  defp emit_meta_result(emit, run_id, probe_id, draft, ctx_taint, read_set) do
    safe_emit(emit, %{
      kind: :meta_result,
      run_id: run_id,
      type: Map.get(draft, :type),
      family: :meta,
      source: provenance_source(probe_id),
      trust: derive_trust(ctx_taint, draft, read_set),
      refs: Map.get(draft, :refs, [])
    })
  end

  defp emit_acct(emit, run_id, kind, estimate, actual) when kind in [:reserve, :call, :settle] do
    safe_emit(emit, %{kind: kind, run_id: run_id, estimate: estimate, actual: actual})
  end

  # ---------------------------------------------------------------------------
  # provenance (U11 §2.1 — stamped by the Runner, never the probe)
  # ---------------------------------------------------------------------------

  # `:probe_<id>` provenance source (§3.1). A probe cannot stamp its own source.
  # The source atoms are pre-interned in the grow-only provenance registry
  # (`Raxol.Agent.Meta.Registry` @sources, §2.1). Resolve to the existing atom
  # (never mint a fresh one from a probe token — atom-table DoS guard) AND require
  # it to be a REGISTERED source: `String.to_existing_atom/1` alone resolves ANY
  # interned atom, so it would accept `:probe_<x>` interned elsewhere but never
  # registered. Membership through the Meta seam is what makes the moduledoc's
  # "through the U11 Meta seam" claim true (#10).
  defp provenance_source(probe_id) do
    candidate = String.to_existing_atom("probe_" <> Atom.to_string(probe_id))
    if candidate in Meta.Registry.sources(), do: candidate, else: :probe_unregistered
  rescue
    ArgumentError -> :probe_unregistered
  end

  # trust = context.taint ⊓ refs-taint (U11 two-point absorbing algebra, P-U12.5).
  # BOTH points matter: a run over tainted context can produce NO trusted event
  # (the probe's drafted `trust` is ignored — Runner-owned, N-U12.6), AND a
  # trusted context whose drafted refs reach a TAINTED record still stamps
  # :tainted (defence-in-depth: the Runner recomputes from the refs, never
  # trusting the coarse context floor). The refs-taint is folded through the U11
  # Meta seam (`Meta.derive_taint`) over the probe's read-set, so there is one
  # taint algebra across the harness.
  defp derive_trust(:tainted, _draft, _read_set), do: :tainted

  defp derive_trust(_trusted_ctx, draft, read_set) do
    if refs_tainted?(draft, read_set), do: :tainted, else: :trusted
  end

  # Fold the draft's refs through `Meta.derive_taint`: wrap them in a synthetic
  # meta record whose `refs` are the draft's, prepend it to the read-set, and ask
  # the seam for that record's derived trust. `derive_taint` recurses the refs to
  # their leaves (loop `tool_result` taint entry-points AND meta records alike),
  # so this covers both. A ref that resolves to nothing is dangling — the seam
  # treats a dangling ref as non-tainting (its documented lenient behavior); the
  # context floor (the :tainted head above) is U12's fail-closed guard, so U12
  # does NOT layer U8's strict dangling-ref damage here (decided per §3.1/§2.1).
  defp refs_tainted?(draft, read_set) do
    refs = Map.get(draft, :refs, [])
    probe_id = {:probe_draft, make_ref()}

    synthetic = %{
      "id" => probe_id,
      "family" => "meta",
      "type" => "extract",
      "payload" => %{"refs" => refs}
    }

    Meta.derive_taint([synthetic | read_set]) |> Map.get(probe_id) == :tainted
  end

  defp context_taint(%{context: %{taint: t}}), do: t
  defp context_taint(_), do: :trusted

  # OQ-U12.3 FULL read-set: the string-keyed journal records the probe's context
  # actually included, fed to `Meta.derive_taint` for the refs-taint fold. Absent
  # (the common lab rig) → empty, so the fold reduces to the context floor.
  defp context_read_set(%{context: %{read_set: rs}}) when is_list(rs), do: rs
  defp context_read_set(_), do: []

  # ---------------------------------------------------------------------------
  # budget (two-level reserve, session-then-run + partial-failure rollback)
  # ---------------------------------------------------------------------------

  # OQ-U12.1: reserve session-then-run in fixed order. If the run-level reserve
  # is refused AFTER the session-level succeeded, RELEASE the session reservation
  # before the run parks (no leaked session budget). The lab injects only a
  # run-level `:budget` (session_budget = nil), so this reduces to one reserve.
  defp reserve_two_level(session_budget, run_budget, amount) do
    case reserve(session_budget, amount) do
      {:over, reason} ->
        {:over, reason}

      :ok ->
        case reserve(run_budget, amount) do
          :ok ->
            :ok

          {:over, reason} ->
            release(session_budget, amount)
            {:over, reason}
        end
    end
  end

  # Settle the FULL reserve held by a run at its terminal — the cumulative
  # `run.reserved` (submit-time reserve + every per-call `:reserve_next` grant),
  # not a fixed 100. Both budget levels are reserved together (reserve_two_level),
  # so both are released together. Called on every terminal (completed settles its
  # holds too; kill/timeout release the stranded amount). A run with no held
  # reserve (parked = reserve was refused, or an already-settled terminal) carries
  # `reserved: 0` and is a no-op.
  defp release_reserve(%{reserved: amount} = run) when amount > 0 do
    release(Map.get(run, :budget), amount)
    release(Map.get(run, :session_budget), amount)
    :ok
  end

  defp release_reserve(_run), do: :ok

  # Disarm a run's wall-clock leash (#2) when it reaches a terminal by another
  # path, so a queued {:run_timeout} message cannot fire against a fresh run.
  defp cancel_timeout(%{timeout_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_timeout(_run), do: :ok

  # Atomic `Ledger.try_spend`-shaped reserve against the injected handle.
  defp reserve(nil, _amount), do: :ok

  defp reserve(budget, amount) when is_pid(budget) do
    Agent.get_and_update(budget, fn %{reserved: reserved, cap: cap} = s ->
      if reserved + amount <= cap,
        do: {:ok, %{s | reserved: reserved + amount}},
        else: {{:over, :over_budget}, s}
    end)
  end

  defp release(nil, _amount), do: :ok

  defp release(budget, amount) when is_pid(budget) do
    Agent.update(budget, fn %{reserved: reserved} = s ->
      %{s | reserved: max(reserved - amount, 0)}
    end)
  catch
    # A release runs in the coordinator (e.g. off a crashed run's :DOWN). The
    # ephemeral test budget Agent can already be gone — a dead budget has nothing
    # to release, and it must NOT crash this shared singleton pool. Swallow ONLY
    # the dead-handle :noproc shape; any other failure surfaces.
    :exit, reason when reason == :noproc or (is_tuple(reason) and elem(reason, 0) == :noproc) ->
      :ok
  end

  # ---------------------------------------------------------------------------
  # provider (ride the shared prefix; never rebuild it — AD-5 / N-U12.5)
  # ---------------------------------------------------------------------------

  # `prefix_ref` is opaque: the Runner rides the CAPTURED bytes verbatim, never
  # re-serialized (byte-identity is the cache-riding contract, P-U12.3).
  defp rideable_prefix(%{prefix_ref: {:captured, bytes}}) when is_binary(bytes), do: bytes
  defp rideable_prefix(%{prefix_ref: bytes}) when is_binary(bytes), do: bytes
  defp rideable_prefix(_), do: ""

  # STUB (see moduledoc "Stub vs. production values"): invoke the injected
  # provider handle. The lab's in-memory stub is a call counter + captured-request
  # list returning a canned response; production binds the real provider here.
  defp provider_invoke(%{calls: calls, captures: captures}, run_id, %{
         prefix: prefix,
         suffix: suffix
       }) do
    :counters.add(calls, 1, 1)

    Agent.update(captures, fn caps ->
      [%{run_id: run_id, prefix: prefix, suffix: suffix} | caps]
    end)

    %{content: "probe-response", usage: %{output_tokens: 12}}
  end

  defp provider_invoke(_provider, _run_id, _request),
    do: %{content: "", usage: %{output_tokens: 0}}

  defp actual(%{usage: %{output_tokens: t}}), do: t

  # ---------------------------------------------------------------------------
  # fingerprint (REQUIRED on every probe_run terminal — §2.1 via Fingerprint)
  # ---------------------------------------------------------------------------

  # STUB (see moduledoc "Stub vs. production values"): a literal fixture model
  # identity; the real model/params replace this at production binding.
  defp fingerprint do
    params = %{temperature: 0.0, top_p: 1.0, max_tokens: 256, seed: 7}

    %{
      provider: "anthropic",
      name: "claude",
      revision: nil,
      params_hash: Fingerprint.params_hash(params),
      params_inline: Map.take(params, Fingerprint.inline_keys()),
      prompt_cache_key: nil
    }
  end

  # STUB (see moduledoc "Stub vs. production values"): the frozen charge split
  # fixture (cache-riding dividend visible). Per successful call: prompt 100 (the
  # reserve), cached 90 (the dividend), completion 12 — real settlement fills
  # actuals at production binding.
  defp charge(calls) when calls > 0 do
    %{
      prompt_tokens: 100 * calls,
      cached_prompt_tokens: 90 * calls,
      completion_tokens: 12 * calls,
      calls: calls
    }
  end

  defp charge(_zero), do: @zero_charge

  # ---------------------------------------------------------------------------
  # misc
  # ---------------------------------------------------------------------------

  defp valid_probe?(probe) do
    Code.ensure_loaded?(probe) and
      function_exported?(probe, :spec, 0) and
      function_exported?(probe, :build, 1) and
      function_exported?(probe, :interpret, 2)
  end

  defp gen_run_id,
    do: "probe-run-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp pool_key(budget), do: budget

  defp put_run(state, run_id, run), do: %{state | runs: Map.put(state.runs, run_id, run)}
end
