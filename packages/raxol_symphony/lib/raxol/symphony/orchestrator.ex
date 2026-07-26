defmodule Raxol.Symphony.Orchestrator do
  @moduledoc """
  Symphony orchestrator -- the only component that mutates dispatch state.

  Implements SPEC s7-8:

  - Polls the tracker on a fixed cadence.
  - Dispatches eligible issues with bounded concurrency.
  - Tracks per-issue claim state; refuses duplicate dispatch.
  - Schedules continuation retries (1s) after clean worker exits.
  - Schedules failure-driven retries with exponential backoff.
  - Reconciles running issues each tick: stall detection + tracker state
    refresh.

  Workers run under a `Task.Supervisor` so the orchestrator survives worker
  crashes. Each worker is monitored; `:DOWN` messages drive state transitions.

  ## Public API

  - `start_link/1` -- requires `:config` (a `Raxol.Symphony.Config` struct).
    Optional opts: `:name`, `:runner_module` (test override),
    `:tracker_module` (test override), `:task_supervisor` (test override),
    `:auto_start_tick` (default true).
  - `snapshot/1` -- returns the SPEC s13.7.2 JSON-shaped state.
  - `refresh/1` -- queues an immediate poll cycle.
  - `subscribe/1` -- registers the calling pid for `{:symphony_event, ...}`
    messages on every state change.
  - `stop_run/2` -- terminates the active run for an issue ID.
  - `tick_now/1` -- (test-only) synchronously runs a single tick.
  """

  use Raxol.Core.Behaviours.BaseManager
  require Logger

  alias Raxol.Symphony.Config.Schema
  alias Raxol.Symphony.Evidence.Capture
  alias Raxol.Symphony.Issue
  alias Raxol.Symphony.Orchestrator.Candidate
  alias Raxol.Symphony.Orchestrator.PausedSaver
  alias Raxol.Symphony.Orchestrator.Retry
  alias Raxol.Symphony.Orchestrator.State
  alias Raxol.Symphony.Runner
  alias Raxol.Symphony.Runners.RaxolAgentSession
  alias Raxol.Symphony.Tracker
  alias Raxol.Symphony.Workflow.GraphAdapter
  alias Raxol.Symphony.WorkflowStore
  alias Raxol.Symphony.Workspace
  alias Raxol.Workflow.Compiled, as: WorkflowCompiled

  # -- Client API -------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    GenServer.cast(server, :refresh)
  end

  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @spec stop_run(GenServer.server(), binary()) :: :ok | {:error, :not_running}
  def stop_run(server \\ __MODULE__, issue_id) do
    GenServer.call(server, {:stop_run, issue_id})
  end

  @doc """
  Resume a paused run by re-dispatching its runner.

  The runner is invoked with `:resume_token` (the `token` it returned in its
  prior `{:pause, _, token}` result) and `:resume_value` (caller-supplied
  payload describing the external event the run was waiting on) in `opts`.

  Returns `{:error, :not_paused}` if no paused entry exists for `issue_id`.
  """
  @spec resume_run(GenServer.server(), binary(), term()) ::
          :ok | {:error, :not_paused}
  def resume_run(server \\ __MODULE__, issue_id, resume_value) do
    GenServer.call(server, {:resume_run, issue_id, resume_value})
  end

  @doc """
  Return the full paused map keyed by `issue_id`.

  Each value is the in-memory `paused_entry` map (see
  `Raxol.Symphony.Orchestrator.State.paused_entry`), including the
  caller-supplied `:resume_token`. Used by
  `Raxol.Symphony.Resumer` to scan for matches against incoming
  telemetry events; the standard snapshot summary at
  `snapshot/1` deliberately strips the token to avoid leaking
  runner-internal state to dashboard subscribers.
  """
  @spec paused(GenServer.server()) :: %{optional(binary()) => map()}
  def paused(server \\ __MODULE__) do
    GenServer.call(server, :paused)
  end

  @doc """
  Returns the loaded `Raxol.Symphony.Config` struct.

  Used by the MCP and LiveView surfaces when they need to reach beyond the
  per-run snapshot (e.g., to look up `workspace.root` for evidence
  collection).
  """
  @spec get_config(GenServer.server()) :: Raxol.Symphony.Config.t()
  def get_config(server \\ __MODULE__) do
    GenServer.call(server, :get_config)
  end

  @doc """
  Test-only: runs a single poll-and-dispatch cycle synchronously.
  """
  @spec tick_now(GenServer.server()) :: :ok
  def tick_now(server \\ __MODULE__) do
    GenServer.call(server, :tick_now)
  end

  # -- GenServer callbacks ----------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    workflow_store = Keyword.get(opts, :workflow_store)

    config =
      case {Keyword.get(opts, :config), workflow_store} do
        {%_{} = cfg, _} ->
          cfg

        {nil, store} when not is_nil(store) ->
          WorkflowStore.get(store)

        {nil, nil} ->
          raise ArgumentError, ":config or :workflow_store is required"
      end

    runner_module = Keyword.get(opts, :runner_module)
    tracker_module = Keyword.get(opts, :tracker_module)
    task_supervisor = Keyword.get(opts, :task_supervisor)
    auto_start_tick = Keyword.get(opts, :auto_start_tick, true)
    paused_saver = Keyword.get(opts, :paused_saver)

    state = %State{
      config: config,
      runner_module: runner_module,
      tracker_module: tracker_module,
      task_supervisor: task_supervisor,
      workflow_store: workflow_store,
      paused_saver: paused_saver,
      paused: PausedSaver.load_all(paused_saver)
    }

    state = if auto_start_tick, do: schedule_tick(state, 0), else: state

    {:ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:snapshot, _from, %State{} = state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_manager_call({:subscribe, pid}, _from, %State{} = state) do
    Process.monitor(pid)
    {:reply, :ok, %State{state | listeners: MapSet.put(state.listeners, pid)}}
  end

  def handle_manager_call({:stop_run, issue_id}, _from, %State{} = state) do
    cond do
      Map.has_key?(state.running, issue_id) ->
        entry = Map.fetch!(state.running, issue_id)
        Process.demonitor(entry.worker_ref, [:flush])
        Process.exit(entry.worker_pid, :kill)

        # Terminal: the user stopped the run, it is not re-dispatched.
        new_state =
          state
          |> remove_running(issue_id, :stopped_by_user)
          |> reclaim_prompt_cache(issue_id)
          |> notify_listeners(:worker_stopped)

        {:reply, :ok, new_state}

      Map.has_key?(state.paused, issue_id) ->
        forget_paused(state.paused_saver, issue_id)

        # Terminal: a paused run stopped by the user does not resume.
        new_state =
          state
          |> Map.put(:paused, Map.delete(state.paused, issue_id))
          |> Map.put(:claimed, MapSet.delete(state.claimed, issue_id))
          |> reclaim_prompt_cache(issue_id)
          |> notify_listeners(:worker_stopped)

        {:reply, :ok, new_state}

      true ->
        {:reply, {:error, :not_running}, state}
    end
  end

  def handle_manager_call(
        {:resume_run, issue_id, resume_value},
        _from,
        %State{} = state
      ) do
    case Map.get(state.paused, issue_id) do
      nil ->
        {:reply, {:error, :not_paused}, state}

      paused_entry ->
        forget_paused(state.paused_saver, issue_id)

        new_state =
          state
          |> Map.put(:paused, Map.delete(state.paused, issue_id))
          |> dispatch_resumption(paused_entry, resume_value)
          |> notify_listeners(:run_resumed)

        {:reply, :ok, new_state}
    end
  end

  def handle_manager_call(:tick_now, _from, %State{} = state) do
    new_state = run_tick(state)
    {:reply, :ok, new_state}
  end

  def handle_manager_call(:get_config, _from, %State{} = state) do
    {:reply, state.config, state}
  end

  def handle_manager_call(:paused, _from, %State{} = state) do
    {:reply, state.paused, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast(:refresh, %State{} = state) do
    new_state = run_tick(state)
    {:noreply, schedule_next_tick(new_state)}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(:tick, %State{} = state) do
    new_state =
      state
      |> Map.put(:tick_timer_ref, nil)
      |> run_tick()
      |> schedule_next_tick()

    {:noreply, new_state}
  end

  def handle_manager_info({:retry_fire, issue_id}, %State{} = state) do
    new_state = handle_retry_fire(state, issue_id)
    {:noreply, new_state}
  end

  def handle_manager_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{} = state
      ) do
    cond do
      Map.has_key?(state.batches, ref) ->
        {:noreply, handle_batch_exit(state, ref, reason)}

      issue_id = find_running_by_ref(state, ref) ->
        {:noreply, handle_worker_exit(state, issue_id, reason)}

      true ->
        # Maybe a listener; drop it from listeners.
        {:noreply, drop_listener_by_ref(state, ref)}
    end
  end

  # A `:graph_parallel` batch worker sends this reply (via `async_nolink`)
  # just before it exits `:normal`; we stash the per-issue results on the
  # batch entry so the subsequent `:DOWN` fan-out can route each outcome.
  def handle_manager_info({ref, {:batch_result, results}}, %State{} = state)
      when is_reference(ref) and is_list(results) do
    {:noreply, store_batch_results(state, ref, results)}
  end

  def handle_manager_info({:run_event, issue_id, event}, %State{} = state) do
    {:noreply, integrate_run_event(state, issue_id, event)}
  end

  def handle_manager_info(
        {:run_paused, issue_id, interrupt_reason, token},
        %State{} = state
      ) do
    {:noreply, mark_running_paused(state, issue_id, interrupt_reason, token)}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- Tick / dispatch --------------------------------------------------------

  defp run_tick(%State{} = state) do
    case preflight(state) do
      {:ok, state} ->
        state
        |> reconcile()
        |> dispatch_candidates()
        |> notify_listeners(:tick_completed)

      {:error, reason, state} ->
        Logger.warning("symphony.orchestrator.preflight_failed reason=#{inspect(reason)}")

        notify_listeners(state, {:preflight_failed, reason})
    end
  end

  # SPEC s6.3: re-validate the workflow config before each dispatch tick.
  # Pulls the latest cached config from the WorkflowStore (if wired) so
  # hot-reloaded edits take effect on the next tick. On failure, the
  # in-memory config is preserved and dispatch is skipped this tick.
  defp preflight(%State{workflow_store: nil} = state) do
    case Schema.validate(state.config, validate_opts(state)) do
      :ok ->
        {:ok, %State{state | last_preflight_error: nil}}

      {:error, reason} ->
        {:error, reason, %State{state | last_preflight_error: reason}}
    end
  end

  defp preflight(%State{workflow_store: store} = state) do
    case WorkflowStore.get(store) do
      nil ->
        {:error, :no_workflow_config, %State{state | last_preflight_error: :no_workflow_config}}

      latest_config ->
        case Schema.validate(latest_config, validate_opts(state)) do
          :ok ->
            {:ok, %State{state | config: latest_config, last_preflight_error: nil}}

          {:error, reason} ->
            {:error, reason, %State{state | last_preflight_error: reason}}
        end
    end
  end

  # When the orchestrator was started with an explicit runner_module override
  # (typical in tests and embedded use), the workflow's declared `runner.kind`
  # is irrelevant -- skip that check during preflight.
  defp validate_opts(%State{runner_module: nil}), do: []
  defp validate_opts(%State{}), do: [skip_runner: true]

  defp dispatch_candidates(%State{config: %{workflow_mode: :graph_parallel}} = state) do
    dispatch_parallel_candidates(state)
  end

  defp dispatch_candidates(%State{} = state) do
    case Tracker.fetch_candidate_issues(state.config) do
      {:ok, issues} ->
        eligible =
          Candidate.eligible(issues, state.config, state.running, state.claimed)

        Enum.reduce(eligible, state, &dispatch_issue(&2, &1, _attempt = nil))

      {:error, _reason} ->
        state
    end
  end

  # `:graph_parallel` mode: take up to `workflow_parallelism` eligible issues
  # and fan them out through one batch worker per tick. In-flight batch issues
  # are folded into the concurrency accounting so the global
  # `max_concurrent_agents` cap still holds across batches.
  defp dispatch_parallel_candidates(%State{} = state) do
    case Tracker.fetch_candidate_issues(state.config) do
      {:ok, issues} ->
        eligible =
          Candidate.eligible(
            issues,
            state.config,
            running_for_slots(state),
            state.claimed
          )

        eligible
        |> Enum.take(state.config.workflow_parallelism)
        |> Enum.map(&{&1, nil})
        |> then(&dispatch_parallel_batch(state, &1))

      {:error, _reason} ->
        state
    end
  end

  # Fold in-flight batch issues into a synthetic running map so
  # `Candidate.eligible/4` counts them against `max_concurrent_agents` (batch
  # issues live in `state.batches`, not `state.running`).
  defp running_for_slots(%State{running: running, batches: batches}) do
    Enum.reduce(batches, running, fn {_ref, batch}, acc ->
      Enum.reduce(batch.issues, acc, fn %{issue: issue}, inner ->
        Map.put_new(inner, issue.id, %{state: issue.state})
      end)
    end)
  end

  # `:graph_parallel` retries arrive here one issue at a time (via the retry
  # timer); route them through the same batch machinery as a batch of one.
  defp dispatch_issue(
         %State{config: %{workflow_mode: :graph_parallel}} = state,
         %Issue{} = issue,
         attempt
       ) do
    dispatch_parallel_batch(state, [{issue, attempt}])
  end

  defp dispatch_issue(%State{} = state, %Issue{} = issue, attempt) do
    with {:ok, runner_mod} <- runner_module(state),
         {:ok, %{path: workspace_path}} <-
           Workspace.ensure(state.config, issue.identifier) do
      do_dispatch_issue(state, issue, attempt, runner_mod, workspace_path)
    else
      {:error, reason} ->
        Logger.warning(
          "symphony.orchestrator.dispatch_failed issue=#{issue.identifier} reason=#{inspect(reason)}"
        )

        schedule_failure_retry(state, issue, attempt || 0, reason)
    end
  end

  defp do_dispatch_issue(state, issue, attempt, runner_mod, workspace_path) do
    capture_pid = maybe_start_capture(state, issue, attempt, workspace_path)
    task = spawn_worker_task(state, runner_mod, issue, attempt, workspace_path)

    entry =
      build_running_entry(issue, attempt, workspace_path, task, capture_pid)

    register_running(state, issue, entry)
  end

  defp maybe_start_capture(
         %State{config: %{recording: %{enabled: true} = rec}},
         issue,
         attempt,
         workspace_path
       ) do
    case Capture.start_link(
           path: Capture.path_for(workspace_path, attempt),
           width: rec.width,
           height: rec.height,
           title: issue.identifier
         ) do
      {:ok, pid} ->
        pid

      _ ->
        nil
    end
  end

  defp maybe_start_capture(_state, _issue, _attempt, _workspace_path), do: nil

  defp spawn_worker_task(
         %State{} = state,
         runner_mod,
         %Issue{} = issue,
         attempt,
         workspace_path
       ) do
    parent = self()
    config = state.config

    Task.Supervisor.async_nolink(
      task_supervisor(state),
      fn ->
        run_worker_payload(
          config.workflow_mode,
          config,
          runner_mod,
          issue,
          attempt,
          workspace_path,
          parent
        )
      end
    )
  end

  defp run_worker_payload(
         :graph,
         config,
         runner_mod,
         issue,
         attempt,
         workspace_path,
         parent
       ) do
    case GraphAdapter.from_workflow([]) do
      {:ok, compiled} ->
        state =
          GraphAdapter.initial_state(
            config: config,
            runner_module: runner_mod,
            candidates: [issue],
            candidate: issue,
            parent_pid: parent,
            attempt: attempt,
            workspace_path: workspace_path
          )

        graph_outcome(WorkflowCompiled.invoke(compiled, state))

      {:error, reason} ->
        exit({:graph_compile_failed, reason})
    end
  end

  defp run_worker_payload(
         _mode,
         config,
         runner_mod,
         issue,
         attempt,
         workspace_path,
         parent
       ) do
    runner_opts = [
      parent: parent,
      attempt: attempt,
      workspace_path: workspace_path
    ]

    run_runner(runner_mod, issue, config, runner_opts)
  end

  defp run_runner(runner_mod, %Issue{} = issue, config, runner_opts) do
    case runner_mod.run(issue, config, runner_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        exit({:runner_error, reason})

      {:pause, interrupt_reason, token} when is_atom(interrupt_reason) ->
        parent = Keyword.fetch!(runner_opts, :parent)
        send(parent, {:run_paused, issue.id, interrupt_reason, token})
        :ok

      other ->
        exit({:runner_bad_return, other})
    end
  end

  defp graph_outcome({:ok, %{run_result: :ok}, _meta}), do: :ok

  defp graph_outcome({:ok, %{run_result: {:error, reason}}, _meta}),
    do: exit({:runner_error, reason})

  defp graph_outcome({:ok, _final, _meta}), do: :ok

  defp graph_outcome({:error, reason, _state}),
    do: exit({:graph_runtime_error, reason})

  defp graph_outcome({:interrupted, _run_id, _state, value}),
    do: exit({:graph_interrupted, value})

  # -- Parallel batch dispatch (:graph_parallel) ------------------------------

  defp dispatch_parallel_batch(%State{} = state, []), do: state

  defp dispatch_parallel_batch(%State{} = state, issues_with_attempts) do
    with {:ok, runner_mod} <- runner_module(state),
         {:ok, prepared} <- ensure_batch_workspaces(state, issues_with_attempts) do
      do_dispatch_parallel_batch(state, runner_mod, prepared)
    else
      {:error, reason} ->
        Logger.warning("symphony.orchestrator.parallel_dispatch_failed reason=#{inspect(reason)}")

        # Nothing was spawned; fall each issue back to a failure retry so the
        # batch is never silently dropped.
        Enum.reduce(issues_with_attempts, state, fn {issue, attempt}, acc ->
          schedule_failure_retry(acc, issue, (attempt || 0) + 1, reason)
        end)
    end
  end

  defp ensure_batch_workspaces(%State{} = state, issues_with_attempts) do
    result =
      Enum.reduce_while(issues_with_attempts, {:ok, []}, fn {issue, attempt}, {:ok, acc} ->
        case Workspace.ensure(state.config, issue.identifier) do
          {:ok, %{path: path}} ->
            entry = %{issue: issue, attempt: attempt, workspace_path: path}
            {:cont, {:ok, [entry | acc]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      err -> err
    end
  end

  defp do_dispatch_parallel_batch(%State{} = state, runner_mod, prepared) do
    issues = Enum.map(prepared, & &1.issue)
    workspaces = Enum.map(prepared, & &1.workspace_path)
    task = spawn_parallel_batch_task(state, runner_mod, issues, workspaces)

    entry = %{
      issues: prepared,
      worker_pid: task.pid,
      worker_ref: task.ref,
      started_at: System.monotonic_time(:millisecond),
      results: nil
    }

    register_batch(state, task.ref, entry)
  end

  defp register_batch(%State{} = state, ref, entry) do
    claimed =
      Enum.reduce(entry.issues, state.claimed, fn %{issue: issue}, acc ->
        MapSet.put(acc, issue.id)
      end)

    state = %State{state | batches: Map.put(state.batches, ref, entry), claimed: claimed}

    Enum.reduce(entry.issues, state, fn %{issue: issue}, acc ->
      cancel_retry(acc, issue.id)
    end)
  end

  defp spawn_parallel_batch_task(%State{} = state, runner_mod, issues, workspaces) do
    parent = self()
    config = state.config
    max_candidates = length(issues)

    Task.Supervisor.async_nolink(
      task_supervisor(state),
      fn ->
        run_parallel_batch_payload(
          config,
          runner_mod,
          issues,
          workspaces,
          max_candidates,
          parent
        )
      end
    )
  end

  defp run_parallel_batch_payload(
         config,
         runner_mod,
         issues,
         workspaces,
         max_candidates,
         parent
       ) do
    case GraphAdapter.from_workflow_parallel(max_candidates: max_candidates) do
      {:ok, compiled} ->
        state =
          GraphAdapter.initial_state(
            config: config,
            runner_module: runner_mod,
            candidates: issues,
            workspaces: workspaces,
            parent_pid: parent
          )

        results = batch_run_results(WorkflowCompiled.invoke(compiled, state), issues)
        {:batch_result, results}

      {:error, reason} ->
        exit({:graph_compile_failed, reason})
    end
  end

  defp batch_run_results({:ok, %{run_results: results}, _meta}, _issues)
       when is_list(results),
       do: results

  defp batch_run_results({:ok, _final, _meta}, issues),
    do: Enum.map(issues, &{&1.id, :ok})

  defp batch_run_results({:error, reason, _state}, issues),
    do: Enum.map(issues, &{&1.id, {:error, {:graph_runtime_error, reason}}})

  defp batch_run_results({:interrupted, _run_id, _state, value}, issues),
    do: Enum.map(issues, &{&1.id, {:error, {:graph_interrupted, value}}})

  defp store_batch_results(%State{} = state, ref, results) do
    case Map.get(state.batches, ref) do
      nil ->
        state

      entry ->
        %State{state | batches: Map.put(state.batches, ref, %{entry | results: results})}
    end
  end

  defp handle_batch_exit(%State{} = state, ref, reason) do
    entry = Map.fetch!(state.batches, ref)
    state = record_batch_runtime(state, entry)
    state = %State{state | batches: Map.delete(state.batches, ref)}
    results = batch_results_map(entry, reason)

    entry.issues
    |> Enum.reduce(state, fn %{issue: issue, attempt: attempt}, acc ->
      apply_batch_issue_result(acc, issue, attempt, Map.get(results, issue.id))
    end)
    |> notify_listeners(:batch_exit)
  end

  # Prefer the worker's reported per-issue results. If the batch worker died
  # before replying (abnormal exit / kill), every issue in the batch is
  # scheduled for a failure retry carrying the exit reason.
  defp batch_results_map(%{results: results}, _reason) when is_list(results),
    do: Map.new(results)

  defp batch_results_map(%{issues: issues}, reason) do
    Map.new(issues, fn %{issue: issue} ->
      {issue.id, {:error, {:batch_worker_exit, reason}}}
    end)
  end

  defp apply_batch_issue_result(%State{} = state, %Issue{} = issue, _attempt, :ok) do
    state
    |> Map.put(:completed, MapSet.put(state.completed, issue.id))
    |> schedule_continuation_retry(issue, 1)
  end

  defp apply_batch_issue_result(%State{} = state, %Issue{} = issue, attempt, {:error, reason}) do
    schedule_failure_retry(state, issue, (attempt || 0) + 1, reason)
  end

  # No result recorded for this slot (e.g. a candidate beyond the graph's slot
  # count). Re-check via a continuation retry rather than dropping it.
  defp apply_batch_issue_result(%State{} = state, %Issue{} = issue, _attempt, nil) do
    schedule_continuation_retry(state, issue, 1)
  end

  defp record_batch_runtime(%State{} = state, entry) do
    elapsed_seconds =
      (System.monotonic_time(:millisecond) - entry.started_at) / 1_000

    totals = state.codex_totals
    new_totals = Map.update!(totals, :seconds_running, &(&1 + elapsed_seconds))
    %State{state | codex_totals: new_totals}
  end

  defp build_running_entry(
         %Issue{} = issue,
         attempt,
         workspace_path,
         task,
         capture_pid
       ) do
    %{
      issue: issue,
      attempt: attempt,
      workspace_path: workspace_path,
      started_at: System.monotonic_time(:millisecond),
      worker_pid: task.pid,
      worker_ref: task.ref,
      state: issue.state,
      last_event: nil,
      last_message: nil,
      last_event_at_ms: nil,
      turn_count: 0,
      capture_pid: capture_pid,
      pending_pause: nil,
      tokens: State.empty_tokens()
    }
  end

  defp register_running(%State{} = state, %Issue{} = issue, entry) do
    state
    |> Map.put(:running, Map.put(state.running, issue.id, entry))
    |> Map.put(:claimed, MapSet.put(state.claimed, issue.id))
    |> cancel_retry(issue.id)
  end

  defp handle_worker_exit(%State{} = state, issue_id, reason) do
    entry = Map.fetch!(state.running, issue_id)
    Capture.stop(entry.capture_pid)
    state = record_runtime(state, entry)
    state = %State{state | running: Map.delete(state.running, issue_id)}

    case reason do
      :normal when entry.pending_pause != nil ->
        park_paused(state, entry, entry.pending_pause)

      :normal ->
        # Continuation retry: re-check after a short fixed delay.
        Logger.info(
          "symphony.orchestrator.worker_exit_normal issue=#{entry.issue.identifier} " <>
            "scheduling continuation"
        )

        state
        |> schedule_continuation_retry(entry.issue, 1)
        |> Map.put(:completed, MapSet.put(state.completed, issue_id))
        |> notify_listeners(:worker_exit_normal)

      :stopped_by_user ->
        Logger.info(
          "symphony.orchestrator.worker_stopped_by_user issue=#{entry.issue.identifier}"
        )

        # Terminal: user stop, no re-dispatch -- reclaim any cache row.
        state
        |> Map.put(:claimed, MapSet.delete(state.claimed, issue_id))
        |> reclaim_prompt_cache(issue_id)
        |> notify_listeners(:worker_stopped)

      other ->
        next_attempt = (entry.attempt || 0) + 1

        Logger.warning(
          "symphony.orchestrator.worker_exit_abnormal issue=#{entry.issue.identifier} " <>
            "reason=#{inspect(other)} next_attempt=#{next_attempt}"
        )

        state
        |> schedule_failure_retry(entry.issue, next_attempt, other)
        |> notify_listeners(:worker_exit_abnormal)
    end
  end

  # Pause is signalled by a {:run_paused, ...} message arriving from the
  # worker BEFORE its :normal exit (same-process message order
  # guarantees this). We record the pause intent on the running entry;
  # handle_worker_exit reads it from the entry when :DOWN :normal lands.
  defp mark_running_paused(%State{} = state, issue_id, interrupt_reason, token) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      entry ->
        updated = Map.put(entry, :pending_pause, {interrupt_reason, token})
        %State{state | running: Map.put(state.running, issue_id, updated)}
    end
  end

  defp park_paused(%State{} = state, entry, {interrupt_reason, token}) do
    Logger.info(
      "symphony.orchestrator.worker_paused issue=#{entry.issue.identifier} " <>
        "reason=#{inspect(interrupt_reason)}"
    )

    paused_entry = %{
      issue: entry.issue,
      attempt: entry.attempt,
      workspace_path: entry.workspace_path,
      interrupt_reason: interrupt_reason,
      resume_token: token,
      paused_at: System.monotonic_time(:millisecond),
      last_event: entry.last_event,
      last_message: entry.last_message,
      turn_count: entry.turn_count,
      tokens: entry.tokens
    }

    persist_paused(state.paused_saver, entry.issue.id, paused_entry)

    state
    |> Map.put(:paused, Map.put(state.paused, entry.issue.id, paused_entry))
    |> notify_listeners(:worker_paused)
  end

  defp persist_paused(saver, issue_id, paused_entry) do
    case PausedSaver.put(saver, issue_id, paused_entry) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "symphony.orchestrator.paused_saver_put_failed issue=#{issue_id} " <>
            "reason=#{inspect(reason)}"
        )
    end
  end

  defp forget_paused(saver, issue_id) do
    case PausedSaver.delete(saver, issue_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "symphony.orchestrator.paused_saver_delete_failed issue=#{issue_id} " <>
            "reason=#{inspect(reason)}"
        )
    end
  end

  defp dispatch_resumption(%State{} = state, paused_entry, resume_value) do
    issue = paused_entry.issue

    with {:ok, runner_mod} <- runner_module(state) do
      capture_pid =
        maybe_start_capture(
          state,
          issue,
          paused_entry.attempt,
          paused_entry.workspace_path
        )

      task =
        spawn_resume_worker_task(
          state,
          runner_mod,
          issue,
          paused_entry.attempt,
          paused_entry.workspace_path,
          paused_entry.resume_token,
          resume_value
        )

      entry =
        issue
        |> build_running_entry(
          paused_entry.attempt,
          paused_entry.workspace_path,
          task,
          capture_pid
        )
        |> Map.put(:turn_count, paused_entry.turn_count)
        |> Map.put(:tokens, paused_entry.tokens)

      register_running(state, issue, entry)
    else
      {:error, reason} ->
        Logger.warning(
          "symphony.orchestrator.resume_failed issue=#{issue.identifier} " <>
            "reason=#{inspect(reason)}"
        )

        schedule_failure_retry(state, issue, (paused_entry.attempt || 0) + 1, reason)
    end
  end

  defp spawn_resume_worker_task(
         %State{} = state,
         runner_mod,
         %Issue{} = issue,
         attempt,
         workspace_path,
         resume_token,
         resume_value
       ) do
    parent = self()
    config = state.config

    Task.Supervisor.async_nolink(
      task_supervisor(state),
      fn ->
        runner_opts = [
          parent: parent,
          attempt: attempt,
          workspace_path: workspace_path,
          resume_token: resume_token,
          resume_value: resume_value
        ]

        run_runner(runner_mod, issue, config, runner_opts)
      end
    )
  end

  defp remove_running(%State{} = state, issue_id, _reason) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      entry ->
        Capture.stop(entry.capture_pid)

        state
        |> record_runtime(entry)
        |> Map.put(:running, Map.delete(state.running, issue_id))
        |> Map.put(:claimed, MapSet.delete(state.claimed, issue_id))
    end
  end

  defp record_runtime(%State{} = state, entry) do
    elapsed_seconds =
      (System.monotonic_time(:millisecond) - entry.started_at) / 1_000

    totals = state.codex_totals
    new_totals = Map.update!(totals, :seconds_running, &(&1 + elapsed_seconds))
    %State{state | codex_totals: new_totals}
  end

  # -- Retry scheduling -------------------------------------------------------

  defp schedule_continuation_retry(%State{} = state, %Issue{} = issue, attempt) do
    schedule_retry(state, issue, attempt, Retry.continuation_delay_ms(), nil)
  end

  defp schedule_failure_retry(
         %State{} = state,
         %Issue{} = issue,
         attempt,
         error
       ) do
    delay =
      Retry.failure_delay_ms(
        max(attempt, 1),
        state.config.agent.max_retry_backoff_ms
      )

    schedule_retry(state, issue, attempt, delay, error)
  end

  defp schedule_retry(
         %State{} = state,
         %Issue{} = issue,
         attempt,
         delay_ms,
         error
       ) do
    state = cancel_retry(state, issue.id)
    timer_ref = Process.send_after(self(), {:retry_fire, issue.id}, delay_ms)
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms

    entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      attempt: attempt,
      due_at_ms: due_at_ms,
      timer_ref: timer_ref,
      error: error
    }

    %State{
      state
      | retry_attempts: Map.put(state.retry_attempts, issue.id, entry),
        claimed: MapSet.put(state.claimed, issue.id)
    }
  end

  defp cancel_retry(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      nil ->
        state

      %{timer_ref: ref} when is_reference(ref) ->
        Process.cancel_timer(ref)

        %State{
          state
          | retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        %State{
          state
          | retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }
    end
  end

  defp handle_retry_fire(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      nil -> state
      retry_entry -> retry_with_fresh_state(state, issue_id, retry_entry)
    end
  end

  defp retry_with_fresh_state(%State{} = state, issue_id, retry_entry) do
    state = %{
      state
      | retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }

    case Tracker.fetch_issue_states_by_ids(state.config, [issue_id]) do
      {:ok, [%Issue{} = issue]} ->
        retry_with_refreshed_issue(state, issue, retry_entry)

      {:ok, []} ->
        release_issue(state, issue_id)

      {:error, _reason} ->
        requeue_retry(state, issue_id, retry_entry)
    end
  end

  defp retry_with_refreshed_issue(
         %State{} = state,
         %Issue{} = issue,
         retry_entry
       ) do
    cond do
      Issue.terminal?(issue, state.config.tracker.terminal_states) ->
        release_issue(state, issue.id)

      Issue.active?(issue, state.config.tracker.active_states) ->
        dispatch_issue(state, issue, retry_entry.attempt)

      true ->
        release_issue(state, issue.id)
    end
  end

  # An issue is leaving the run set for good (terminal, gone, or no longer
  # active): drop the claim AND flush any prompt-cache row it left behind. The
  # session runner's `prompt_cache` writes a row on every fresh dispatch; a
  # one-shot issue (or an odd-length continuation chain) leaves one unread row
  # that only this terminal flush reclaims.
  defp release_issue(%State{} = state, issue_id) do
    state
    |> reclaim_prompt_cache(issue_id)
    |> Map.put(:claimed, MapSet.delete(state.claimed, issue_id))
  end

  # Flush the prompt-cache row an issue may have left behind. Pipeable; a no-op
  # unless the session runner's `prompt_cache` is configured. Call this ONLY at
  # genuinely-terminal release sites (the same `issue.id` is NOT about to be
  # re-dispatched) -- flushing on a continuation/retry path would just force a
  # needless re-render on the next dispatch.
  defp reclaim_prompt_cache(%State{} = state, issue_id) do
    RaxolAgentSession.flush_prompt_cache(state.config, issue_id)
    state
  end

  defp requeue_retry(%State{} = state, issue_id, retry_entry) do
    placeholder = %Issue{
      id: issue_id,
      identifier: retry_entry.identifier,
      title: retry_entry.identifier,
      state: ""
    }

    schedule_retry(
      state,
      placeholder,
      retry_entry.attempt,
      Retry.continuation_delay_ms(),
      {:tracker_unavailable_during_retry, retry_entry.error}
    )
  end

  # -- Reconciliation ---------------------------------------------------------

  defp reconcile(%State{} = state) do
    state
    |> reconcile_stalls()
    |> reconcile_tracker_states()
  end

  defp reconcile_stalls(%State{} = state) do
    stall_timeout = state.config.codex.stall_timeout_ms

    if stall_timeout <= 0 do
      state
    else
      now = System.monotonic_time(:millisecond)

      Enum.reduce(
        state.running,
        state,
        &maybe_terminate_stalled(&1, &2, now, stall_timeout)
      )
    end
  end

  defp maybe_terminate_stalled(
         {issue_id, entry},
         %State{} = acc,
         now,
         stall_timeout
       ) do
    last = entry.last_event_at_ms || entry.started_at

    if now - last > stall_timeout do
      terminate_stalled_run(acc, issue_id, entry, now - last)
    else
      acc
    end
  end

  defp terminate_stalled_run(%State{} = acc, issue_id, entry, elapsed_ms) do
    Logger.warning(
      "symphony.orchestrator.stall_detected issue=#{entry.issue.identifier} elapsed_ms=#{elapsed_ms}"
    )

    Process.demonitor(entry.worker_ref, [:flush])
    Process.exit(entry.worker_pid, :kill)
    new_acc = remove_running(acc, issue_id, :stalled)

    schedule_failure_retry(
      new_acc,
      entry.issue,
      (entry.attempt || 0) + 1,
      :stalled
    )
  end

  defp reconcile_tracker_states(%State{} = state) do
    if map_size(state.running) == 0 do
      state
    else
      ids = Map.keys(state.running)

      case Tracker.fetch_issue_states_by_ids(state.config, ids) do
        {:ok, refreshed} -> apply_state_refresh(state, refreshed)
        {:error, _reason} -> state
      end
    end
  end

  defp apply_state_refresh(%State{} = state, refreshed) do
    Enum.reduce(refreshed, state, &refresh_one_issue/2)
  end

  defp refresh_one_issue(%Issue{id: id} = issue, %State{} = acc) do
    case Map.get(acc.running, id) do
      nil -> acc
      entry -> refresh_running_entry(acc, id, issue, entry)
    end
  end

  defp refresh_running_entry(%State{} = acc, id, %Issue{} = issue, entry) do
    cond do
      Issue.terminal?(issue, acc.config.tracker.terminal_states) ->
        terminate_running(acc, id, entry, true)

      Issue.active?(issue, acc.config.tracker.active_states) ->
        %{acc | running: Map.put(acc.running, id, %{entry | issue: issue})}

      true ->
        terminate_running(acc, id, entry, false)
    end
  end

  # Reconcile-kill: the tracker reports this issue terminal or no longer
  # active, so the run is torn down for good and is NOT re-dispatched. Flush
  # its prompt-cache row here (not in the shared `remove_running`, which the
  # stall path also uses before a re-dispatch retry).
  defp terminate_running(%State{} = state, issue_id, entry, clean_workspace?) do
    Process.demonitor(entry.worker_ref, [:flush])
    Process.exit(entry.worker_pid, :kill)
    %State{} = state = remove_running(state, issue_id, :reconciled)

    if clean_workspace? do
      Workspace.remove(state.config, entry.workspace_path)
    end

    state
    |> Map.put(:claimed, MapSet.delete(state.claimed, issue_id))
    |> reclaim_prompt_cache(issue_id)
  end

  # -- Run events -------------------------------------------------------------

  defp integrate_run_event(%State{} = state, issue_id, event) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      entry ->
        Capture.record(entry.capture_pid, event)
        updated = update_entry_from_event(entry, event)
        %State{state | running: Map.put(state.running, issue_id, updated)}
    end
  end

  defp update_entry_from_event(entry, event) do
    %{
      entry
      | last_event: Map.get(event, :event) || Map.get(event, "event") || entry.last_event,
        last_message:
          Map.get(event, :message) || Map.get(event, "message") ||
            entry.last_message,
        last_event_at_ms: System.monotonic_time(:millisecond),
        tokens:
          merge_tokens(
            entry.tokens,
            Map.get(event, :usage) || Map.get(event, "usage")
          ),
        turn_count: entry.turn_count + maybe_turn_increment(event)
    }
  end

  defp maybe_turn_increment(event) do
    case Map.get(event, :event) || Map.get(event, "event") do
      :turn_completed -> 1
      "turn_completed" -> 1
      _ -> 0
    end
  end

  defp merge_tokens(current, nil), do: current

  defp merge_tokens(current, usage) when is_map(usage) do
    %{
      input_tokens:
        current.input_tokens +
          (Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0),
      output_tokens:
        current.output_tokens +
          (Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") ||
             0),
      total_tokens:
        current.total_tokens +
          (Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") || 0)
    }
  end

  # -- Snapshot ---------------------------------------------------------------

  defp build_snapshot(%State{} = state) do
    now_ms = System.monotonic_time(:millisecond)

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      counts: snapshot_counts(state),
      running: Enum.map(state.running, &snapshot_running(&1, now_ms)),
      retrying: Enum.map(state.retry_attempts, &snapshot_retry(&1, now_ms)),
      paused: Enum.map(state.paused, &snapshot_paused(&1, now_ms)),
      batches: Enum.map(state.batches, &snapshot_batch(&1, now_ms)),
      codex_totals: state.codex_totals,
      rate_limits: state.codex_rate_limits
    }
  end

  defp snapshot_counts(%State{} = state) do
    %{
      running: map_size(state.running),
      retrying: map_size(state.retry_attempts),
      paused: map_size(state.paused),
      batches: map_size(state.batches)
    }
  end

  defp snapshot_running({_id, entry}, now_ms) do
    %{
      issue_id: entry.issue.id,
      issue_identifier: entry.issue.identifier,
      state: entry.state,
      turn_count: entry.turn_count,
      last_event: entry.last_event,
      last_message: entry.last_message,
      started_ms_ago: now_ms - entry.started_at,
      tokens: entry.tokens
    }
  end

  defp snapshot_retry({_id, entry}, now_ms) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_in_ms: max(entry.due_at_ms - now_ms, 0),
      error: inspect_error(entry.error)
    }
  end

  defp snapshot_paused({_id, entry}, now_ms) do
    %{
      issue_id: entry.issue.id,
      issue_identifier: entry.issue.identifier,
      interrupt_reason: entry.interrupt_reason,
      paused_ms_ago: now_ms - entry.paused_at,
      attempt: entry.attempt,
      turn_count: entry.turn_count,
      last_event: entry.last_event,
      last_message: entry.last_message,
      tokens: entry.tokens
    }
  end

  defp snapshot_batch({_ref, entry}, now_ms) do
    %{
      size: length(entry.issues),
      issue_identifiers: Enum.map(entry.issues, & &1.issue.identifier),
      started_ms_ago: now_ms - entry.started_at
    }
  end

  defp inspect_error(nil), do: nil
  defp inspect_error(error), do: inspect(error)

  # -- Listeners --------------------------------------------------------------

  defp notify_listeners(%State{listeners: listeners} = state, event_name) do
    snapshot = build_snapshot(state)

    Enum.each(listeners, fn pid ->
      send(pid, {:symphony_event, event_name, snapshot})
    end)

    state
  end

  defp drop_listener_by_ref(%State{} = state, _ref) do
    # We do not track ref->pid mapping; on listener crash we simply leave the
    # entry in the set (sends to dead pids are no-ops). This is
    # acceptable; a future version may switch to Phoenix.PubSub.
    state
  end

  # -- Helpers ----------------------------------------------------------------

  defp schedule_next_tick(%State{} = state) do
    schedule_tick(state, state.config.polling.interval_ms)
  end

  defp schedule_tick(%State{} = state, delay_ms) do
    if state.tick_timer_ref do
      Process.cancel_timer(state.tick_timer_ref)
    end

    ref = Process.send_after(self(), :tick, delay_ms)
    %State{state | tick_timer_ref: ref}
  end

  defp runner_module(%State{runner_module: nil, config: config}),
    do: Runner.resolve(config)

  defp runner_module(%State{runner_module: mod}), do: {:ok, mod}

  defp task_supervisor(%State{task_supervisor: nil}),
    do: Raxol.Symphony.TaskSupervisor

  defp task_supervisor(%State{task_supervisor: sup}), do: sup

  defp find_running_by_ref(%State{running: running}, ref) do
    Enum.find_value(running, fn {id, entry} ->
      if entry.worker_ref == ref, do: id
    end)
  end
end
