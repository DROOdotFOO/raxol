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

  use GenServer
  require Logger

  alias Raxol.Symphony.Config.Schema
  alias Raxol.Symphony.Issue
  alias Raxol.Symphony.Orchestrator.Candidate
  alias Raxol.Symphony.Orchestrator.Retry
  alias Raxol.Symphony.Orchestrator.State
  alias Raxol.Symphony.Runner
  alias Raxol.Symphony.Tracker
  alias Raxol.Symphony.WorkflowStore
  alias Raxol.Symphony.Workspace

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
  Test-only: runs a single poll-and-dispatch cycle synchronously.
  """
  @spec tick_now(GenServer.server()) :: :ok
  def tick_now(server \\ __MODULE__) do
    GenServer.call(server, :tick_now)
  end

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def init(opts) do
    workflow_store = Keyword.get(opts, :workflow_store)

    config =
      case {Keyword.get(opts, :config), workflow_store} do
        {%_{} = cfg, _} -> cfg
        {nil, store} when not is_nil(store) -> WorkflowStore.get(store)
        {nil, nil} -> raise ArgumentError, ":config or :workflow_store is required"
      end

    runner_module = Keyword.get(opts, :runner_module)
    tracker_module = Keyword.get(opts, :tracker_module)
    task_supervisor = Keyword.get(opts, :task_supervisor)
    auto_start_tick = Keyword.get(opts, :auto_start_tick, true)

    state = %State{
      config: config,
      runner_module: runner_module,
      tracker_module: tracker_module,
      task_supervisor: task_supervisor,
      workflow_store: workflow_store
    }

    state = if auto_start_tick, do: schedule_tick(state, 0), else: state

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call({:subscribe, pid}, _from, %State{} = state) do
    Process.monitor(pid)
    {:reply, :ok, %State{state | listeners: MapSet.put(state.listeners, pid)}}
  end

  def handle_call({:stop_run, issue_id}, _from, %State{} = state) do
    case Map.get(state.running, issue_id) do
      nil ->
        {:reply, {:error, :not_running}, state}

      entry ->
        Process.demonitor(entry.worker_ref, [:flush])
        Process.exit(entry.worker_pid, :kill)

        new_state =
          state
          |> remove_running(issue_id, :stopped_by_user)
          |> notify_listeners(:worker_stopped)

        {:reply, :ok, new_state}
    end
  end

  def handle_call(:tick_now, _from, %State{} = state) do
    new_state = run_tick(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast(:refresh, %State{} = state) do
    new_state = run_tick(state)
    {:noreply, schedule_next_tick(new_state)}
  end

  @impl true
  def handle_info(:tick, %State{} = state) do
    new_state =
      state
      |> Map.put(:tick_timer_ref, nil)
      |> run_tick()
      |> schedule_next_tick()

    {:noreply, new_state}
  end

  def handle_info({:retry_fire, issue_id}, %State{} = state) do
    new_state = handle_retry_fire(state, issue_id)
    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{} = state) do
    case find_running_by_ref(state, ref) do
      nil ->
        # Maybe a listener; drop it from listeners.
        {:noreply, drop_listener_by_ref(state, ref)}

      issue_id ->
        {:noreply, handle_worker_exit(state, issue_id, reason)}
    end
  end

  def handle_info({:run_event, issue_id, event}, %State{} = state) do
    {:noreply, integrate_run_event(state, issue_id, event)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
      :ok -> {:ok, %State{state | last_preflight_error: nil}}
      {:error, reason} -> {:error, reason, %State{state | last_preflight_error: reason}}
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

  defp dispatch_candidates(%State{} = state) do
    case Tracker.fetch_candidate_issues(state.config) do
      {:ok, issues} ->
        eligible = Candidate.eligible(issues, state.config, state.running, state.claimed)
        Enum.reduce(eligible, state, &dispatch_issue(&2, &1, _attempt = nil))

      {:error, _reason} ->
        state
    end
  end

  defp dispatch_issue(%State{} = state, %Issue{} = issue, attempt) do
    with {:ok, runner_mod} <- runner_module(state),
         {:ok, %{path: workspace_path}} <- Workspace.ensure(state.config, issue.identifier) do
      task = spawn_worker_task(state, runner_mod, issue, attempt, workspace_path)
      entry = build_running_entry(issue, attempt, workspace_path, task)
      register_running(state, issue, entry)
    else
      {:error, reason} ->
        Logger.warning(
          "symphony.orchestrator.dispatch_failed issue=#{issue.identifier} reason=#{inspect(reason)}"
        )

        schedule_failure_retry(state, issue, attempt || 0, reason)
    end
  end

  defp spawn_worker_task(%State{} = state, runner_mod, %Issue{} = issue, attempt, workspace_path) do
    parent = self()
    config = state.config

    Task.Supervisor.async_nolink(
      task_supervisor(state),
      fn ->
        runner_opts = [
          parent: parent,
          attempt: attempt,
          workspace_path: workspace_path
        ]

        case runner_mod.run(issue, config, runner_opts) do
          :ok -> :ok
          {:error, reason} -> exit({:runner_error, reason})
        end
      end
    )
  end

  defp build_running_entry(%Issue{} = issue, attempt, workspace_path, task) do
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
    state = record_runtime(state, entry)
    state = %State{state | running: Map.delete(state.running, issue_id)}

    case reason do
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

        state
        |> Map.put(:claimed, MapSet.delete(state.claimed, issue_id))
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

  defp remove_running(%State{} = state, issue_id, _reason) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      entry ->
        state
        |> record_runtime(entry)
        |> Map.put(:running, Map.delete(state.running, issue_id))
        |> Map.put(:claimed, MapSet.delete(state.claimed, issue_id))
    end
  end

  defp record_runtime(%State{} = state, entry) do
    elapsed_seconds = (System.monotonic_time(:millisecond) - entry.started_at) / 1_000
    totals = state.codex_totals
    new_totals = Map.update!(totals, :seconds_running, &(&1 + elapsed_seconds))
    %State{state | codex_totals: new_totals}
  end

  # -- Retry scheduling -------------------------------------------------------

  defp schedule_continuation_retry(%State{} = state, %Issue{} = issue, attempt) do
    schedule_retry(state, issue, attempt, Retry.continuation_delay_ms(), nil)
  end

  defp schedule_failure_retry(%State{} = state, %Issue{} = issue, attempt, error) do
    delay = Retry.failure_delay_ms(max(attempt, 1), state.config.agent.max_retry_backoff_ms)
    schedule_retry(state, issue, attempt, delay, error)
  end

  defp schedule_retry(%State{} = state, %Issue{} = issue, attempt, delay_ms, error) do
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
        %State{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}

      _ ->
        %State{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
    end
  end

  defp handle_retry_fire(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      nil -> state
      retry_entry -> retry_with_fresh_state(state, issue_id, retry_entry)
    end
  end

  defp retry_with_fresh_state(%State{} = state, issue_id, retry_entry) do
    state = %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}

    case Tracker.fetch_issue_states_by_ids(state.config, [issue_id]) do
      {:ok, [%Issue{} = issue]} ->
        retry_with_refreshed_issue(state, issue, retry_entry)

      {:ok, []} ->
        %{state | claimed: MapSet.delete(state.claimed, issue_id)}

      {:error, _reason} ->
        requeue_retry(state, issue_id, retry_entry)
    end
  end

  defp retry_with_refreshed_issue(%State{} = state, %Issue{} = issue, retry_entry) do
    cond do
      Issue.terminal?(issue, state.config.tracker.terminal_states) ->
        %{state | claimed: MapSet.delete(state.claimed, issue.id)}

      Issue.active?(issue, state.config.tracker.active_states) ->
        dispatch_issue(state, issue, retry_entry.attempt)

      true ->
        %{state | claimed: MapSet.delete(state.claimed, issue.id)}
    end
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
      Enum.reduce(state.running, state, &maybe_terminate_stalled(&1, &2, now, stall_timeout))
    end
  end

  defp maybe_terminate_stalled({issue_id, entry}, %State{} = acc, now, stall_timeout) do
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
    schedule_failure_retry(new_acc, entry.issue, (entry.attempt || 0) + 1, :stalled)
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

  defp terminate_running(%State{} = state, issue_id, entry, clean_workspace?) do
    Process.demonitor(entry.worker_ref, [:flush])
    Process.exit(entry.worker_pid, :kill)
    %State{} = state = remove_running(state, issue_id, :reconciled)

    if clean_workspace? do
      Workspace.remove(state.config, entry.workspace_path)
    end

    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  # -- Run events -------------------------------------------------------------

  defp integrate_run_event(%State{} = state, issue_id, event) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      entry ->
        updated = update_entry_from_event(entry, event)
        %State{state | running: Map.put(state.running, issue_id, updated)}
    end
  end

  defp update_entry_from_event(entry, event) do
    %{
      entry
      | last_event: Map.get(event, :event) || Map.get(event, "event") || entry.last_event,
        last_message: Map.get(event, :message) || Map.get(event, "message") || entry.last_message,
        last_event_at_ms: System.monotonic_time(:millisecond),
        tokens: merge_tokens(entry.tokens, Map.get(event, :usage) || Map.get(event, "usage")),
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
          (Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0),
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
      counts: %{
        running: map_size(state.running),
        retrying: map_size(state.retry_attempts)
      },
      running: Enum.map(state.running, &snapshot_running(&1, now_ms)),
      retrying: Enum.map(state.retry_attempts, &snapshot_retry(&1, now_ms)),
      codex_totals: state.codex_totals,
      rate_limits: state.codex_rate_limits
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
    # entry in the set (sends to dead pids are no-ops). For Phase 3 this is
    # acceptable; Phase 7+ may switch to Phoenix.PubSub.
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

  defp runner_module(%State{runner_module: nil, config: config}), do: Runner.resolve(config)
  defp runner_module(%State{runner_module: mod}), do: {:ok, mod}

  defp task_supervisor(%State{task_supervisor: nil}), do: Raxol.Symphony.TaskSupervisor
  defp task_supervisor(%State{task_supervisor: sup}), do: sup

  defp find_running_by_ref(%State{running: running}, ref) do
    Enum.find_value(running, fn {id, entry} ->
      if entry.worker_ref == ref, do: id
    end)
  end
end
