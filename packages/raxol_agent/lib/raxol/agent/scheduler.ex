defmodule Raxol.Agent.Scheduler do
  @moduledoc """
  A single-node scheduler for recurring and one-shot agent jobs.

  Each job holds a `prompt`, a `schedule` (parsed once by `Raxol.Agent.Schedule`),
  the `skills` to inject on each fire, a delivery `target`, and an `enabled` flag.
  The scheduler keeps one `Process.send_after/3` timer per enabled job; when a
  timer elapses it dispatches the job's run and, for a recurring schedule,
  re-arms the next occurrence. Jobs are persisted to `Raxol.Core.Stores.Dets`
  (when a path is configured) and replayed on boot, so a restart re-arms every
  job from its stored next-fire time. Missed fires during downtime are not
  back-filled: a recurring job re-arms forward from now, a one-shot whose time
  passed fires once, promptly.

  The BEAM owns the scheduling; there is no OS cron daemon. This is a single-node
  scheduler: a clustered variant sharded across the swarm is out of scope.

  ## Firing

  A fire never runs inline in the GenServer. The scheduler records the fire to
  its thread log (single-writer, in mailbox order), advances the schedule, and
  hands the actual work to an injectable `:dispatch` function (default: an
  unlinked process), which calls the `:runner` and then `:deliver`. A slow or
  crashing agent turn therefore cannot stall scheduling or drop another job.

  ## Options

    * `:name` -- registered name (default `#{inspect(__MODULE__)}`)
    * `:now_fn` -- `(-> DateTime.t())`, the clock; injectable for deterministic
      tests. Default `&DateTime.utc_now/0`.
    * `:runner` -- `(job -> {:ok, String.t()} | {:error, term()})`, runs one
      fire and returns its rendered output. Default logs and returns an error
      (the real fresh-agent runner is wired by the surface layer).
    * `:deliver` -- `(target, String.t() -> :ok | {:error, term()})`, delivers a
      fire's output to the job's target. Default logs.
    * `:dispatch` -- `((-> any()) -> any())`, runs the fire work. Default spawns
      an unlinked process; tests pass a synchronous function.
    * `:max_per_owner` -- cap on enabled + paused jobs per `owner` (default 50).
    * `:thread_log` -- a `Raxol.Agent.ThreadLog` adapter (`module` or
      `{module, config}`) that every fire is recorded to. Default: none.
    * `:dets_path` / `:dets_name` -- durable job store; falls back to
      `Application.get_env(:raxol_agent, :scheduler_dets_path)`. Unset means jobs
      live in memory only.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Agent.Schedule
  alias Raxol.Agent.ThreadLog
  alias Raxol.Core.ErrorHandling
  alias Raxol.Core.Stores.Dets

  @default_max_per_owner 50
  # Process.send_after tops out near 49 days; re-arm well under it for long
  # schedules (e.g. a yearly cron) so no single timer exceeds the limit.
  @max_timer_ms 24 * 60 * 60 * 1000

  @type job :: %{
          id: String.t(),
          owner: String.t() | nil,
          prompt: String.t(),
          schedule_spec: String.t(),
          schedule: Schedule.t(),
          skills: [String.t()],
          target: String.t() | nil,
          enabled: boolean(),
          next_fire: DateTime.t() | nil,
          created_at: DateTime.t(),
          last_fired_at: DateTime.t() | nil,
          fire_count: non_neg_integer()
        }

  # -- Public API -------------------------------------------------------------

  @doc "Create a job from `attrs` (`prompt`, `schedule`, and optional `owner`, `skills`, `target`, `enabled`, `id`)."
  @spec create(GenServer.server(), map()) :: {:ok, job()} | {:error, term()}
  def create(server \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.call(server, {:create, attrs})
  end

  @doc "List jobs, most-recently-created first. `:owner` filters to one owner."
  @spec list(GenServer.server(), keyword()) :: [job()]
  def list(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:list, Keyword.get(opts, :owner)})
  end

  @doc "Fetch one job by id."
  @spec get(GenServer.server(), String.t()) :: {:ok, job()} | {:error, :not_found}
  def get(server \\ __MODULE__, id), do: GenServer.call(server, {:get, id})

  @doc "Patch a job's `prompt`, `schedule`, `skills`, `target`, or `enabled` and re-arm."
  @spec update(GenServer.server(), String.t(), map()) :: {:ok, job()} | {:error, term()}
  def update(server \\ __MODULE__, id, changes) when is_map(changes) do
    GenServer.call(server, {:update, id, changes})
  end

  @doc "Disable a job and cancel its timer. It keeps its definition."
  @spec pause(GenServer.server(), String.t()) :: {:ok, job()} | {:error, :not_found}
  def pause(server \\ __MODULE__, id), do: GenServer.call(server, {:set_enabled, id, false})

  @doc "Re-enable a paused job and re-arm it from the next occurrence."
  @spec resume(GenServer.server(), String.t()) :: {:ok, job()} | {:error, :not_found}
  def resume(server \\ __MODULE__, id), do: GenServer.call(server, {:set_enabled, id, true})

  @doc "Fire a job now, out of schedule, without disturbing its next scheduled fire."
  @spec run(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def run(server \\ __MODULE__, id), do: GenServer.call(server, {:run_now, id})

  @doc "Remove a job, cancel its timer, and delete it from the store."
  @spec remove(GenServer.server(), String.t()) :: :ok
  def remove(server \\ __MODULE__, id), do: GenServer.call(server, {:remove, id})

  # -- BaseManager callbacks --------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    dets = open_store(opts)
    if dets, do: Process.flag(:trap_exit, true)

    now_fn = Keyword.get(opts, :now_fn, &DateTime.utc_now/0)

    state = %{
      jobs: %{},
      timers: %{},
      dets: dets,
      now_fn: now_fn,
      runner: Keyword.get(opts, :runner, &default_runner/1),
      deliver: Keyword.get(opts, :deliver, &default_deliver/2),
      dispatch: Keyword.get(opts, :dispatch, &default_dispatch/1),
      max_per_owner: Keyword.get(opts, :max_per_owner, @default_max_per_owner),
      thread_log: ThreadLog.normalize(Keyword.get(opts, :thread_log))
    }

    {:ok, replay(state)}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:create, attrs}, _from, state) do
    case build_job(attrs, state) do
      {:ok, job} ->
        state = state |> put_job(job) |> arm(job.id)
        {:reply, {:ok, fetch!(state, job.id)}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_manager_call({:list, owner}, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(is_nil(owner) or &1.owner == owner))
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

    {:reply, jobs, state}
  end

  def handle_manager_call({:get, id}, _from, state) do
    case Map.fetch(state.jobs, id) do
      {:ok, job} -> {:reply, {:ok, job}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_manager_call({:update, id, changes}, _from, state) do
    with {:ok, job} <- Map.fetch(state.jobs, id),
         {:ok, updated} <- apply_changes(job, changes, state) do
      state = state |> cancel(id) |> put_job(updated) |> arm(id)
      {:reply, {:ok, fetch!(state, id)}, state}
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_manager_call({:set_enabled, id, enabled}, _from, state) do
    case Map.fetch(state.jobs, id) do
      {:ok, job} ->
        state =
          state
          |> cancel(id)
          |> put_job(%{job | enabled: enabled})
          |> arm(id)

        {:reply, {:ok, fetch!(state, id)}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_manager_call({:run_now, id}, _from, state) do
    case Map.fetch(state.jobs, id) do
      {:ok, job} ->
        state = dispatch_fire(state, job, :manual)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_manager_call({:remove, id}, _from, state) do
    state = cancel(state, id)
    Dets.delete(state.dets, id)
    {:reply, :ok, %{state | jobs: Map.delete(state.jobs, id)}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:fire, id}, state) do
    case Map.fetch(state.jobs, id) do
      {:ok, %{enabled: true} = job} -> {:noreply, fire(job, state)}
      _other -> {:noreply, drop_timer(state, id)}
    end
  end

  def handle_manager_info({:rearm, id}, state) do
    {:noreply, state |> drop_timer(id) |> arm(id)}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    Dets.close(state.dets)
    :ok
  end

  # -- firing -----------------------------------------------------------------

  # A scheduled fire: run the work, then advance to the next occurrence.
  defp fire(job, state) do
    state
    |> dispatch_fire(job, :schedule)
    |> advance(job)
  end

  # Record the fire and hand the run to the dispatcher. Shared by scheduled and
  # manual (`run/1`) fires; a manual fire does not advance the schedule.
  defp dispatch_fire(state, job, trigger) do
    now = state.now_fn.()
    record_fire(state, job, trigger, now)

    runner = state.runner
    deliver = state.deliver
    state.dispatch.(fn -> run_and_deliver(job, runner, deliver) end)

    updated = %{job | last_fired_at: now, fire_count: job.fire_count + 1}
    put_job(state, updated)
  end

  defp advance(state, job) do
    job = fetch!(state, job.id)
    now = state.now_fn.()

    if job.schedule.recurring? do
      case Schedule.next_fire(job.schedule, now) do
        {:ok, next} -> state |> put_job(%{job | next_fire: next}) |> arm(job.id)
        :never -> retire(state, job)
      end
    else
      # A one-shot has fired; retire it (keep the record).
      retire(state, job)
    end
  end

  # Retire a job that will not fire again: keep its record but drop the elapsed
  # timer ref so `state.timers` stays bounded and means "currently armed".
  defp retire(state, job) do
    state |> drop_timer(job.id) |> put_job(%{job | next_fire: nil})
  end

  defp run_and_deliver(job, runner, deliver) do
    case ErrorHandling.safe_call(fn -> runner.(job) end) do
      {:ok, {:ok, output}} when is_binary(output) ->
        deliver_output(job, output, deliver)

      {:ok, {:error, reason}} ->
        Logger.warning("scheduler job #{job.id} runner failed: #{inspect(reason)}")

      {:ok, other} ->
        Logger.warning("scheduler job #{job.id} runner returned #{inspect(other)}")

      {:error, crash} ->
        Logger.warning("scheduler job #{job.id} runner crashed: #{inspect(crash)}")
    end
  end

  defp deliver_output(%{target: nil}, _output, _deliver), do: :ok

  defp deliver_output(%{target: target} = job, output, deliver) do
    case ErrorHandling.safe_call(fn -> deliver.(target, output) end) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        Logger.warning("scheduler job #{job.id} delivery failed: #{inspect(reason)}")

      {:ok, other} ->
        Logger.warning("scheduler job #{job.id} delivery returned #{inspect(other)}")

      {:error, crash} ->
        Logger.warning("scheduler job #{job.id} delivery crashed: #{inspect(crash)}")
    end
  end

  defp record_fire(%{thread_log: nil}, _job, _trigger, _now), do: :ok

  # Runs inline in the GenServer (single-writer per thread), so a raising or
  # misbehaving thread-log adapter must never crash the scheduler -- that would
  # drop every armed timer, and since recording precedes the schedule advance,
  # replay would re-fire the same job into the same failing adapter in a loop.
  defp record_fire(state, job, trigger, now) do
    payload = %{job_id: job.id, prompt: job.prompt, trigger: trigger, fired_at: now}

    result =
      ErrorHandling.safe_call(fn ->
        ThreadLog.append(state.thread_log, "cron:" <> job.id, :cron_fire, payload)
      end)

    case result do
      {:ok, {:ok, _event}} ->
        :ok

      {:ok, {:error, reason}} ->
        Logger.warning("scheduler job #{job.id} thread-log append failed: #{inspect(reason)}")

      {:ok, other} ->
        Logger.warning("scheduler job #{job.id} thread-log append returned #{inspect(other)}")

      {:error, crash} ->
        Logger.warning("scheduler job #{job.id} thread-log append crashed: #{inspect(crash)}")
    end
  end

  # -- timers -----------------------------------------------------------------

  # Arm (or re-arm) a job's timer. A next-fire beyond the timer ceiling parks a
  # `:rearm` checkpoint that recomputes the delay on wake, so no single timer
  # exceeds the send_after limit.
  defp arm(state, id) do
    job = fetch!(state, id)

    cond do
      not job.enabled -> state
      is_nil(job.next_fire) -> state
      true -> put_timer(state, id, arm_timer(state, id, job.next_fire))
    end
  end

  defp arm_timer(state, id, target) do
    delay = max(0, DateTime.diff(target, state.now_fn.(), :millisecond))

    if delay > @max_timer_ms do
      Process.send_after(self(), {:rearm, id}, @max_timer_ms)
    else
      Process.send_after(self(), {:fire, id}, delay)
    end
  end

  defp cancel(state, id), do: drop_timer(state, id)

  defp put_timer(state, id, ref), do: %{state | timers: Map.put(state.timers, id, ref)}

  defp drop_timer(state, id) do
    case Map.pop(state.timers, id) do
      {nil, timers} ->
        %{state | timers: timers}

      {ref, timers} ->
        Process.cancel_timer(ref)
        flush_fire(id)
        %{state | timers: timers}
    end
  end

  # cancel_timer does not remove a `{:fire, id}` the timer already delivered to
  # the mailbox. Without this, cancelling on a re-arm that keeps a job enabled
  # (e.g. update/3) could let a stale fire slip through and drift the schedule.
  defp flush_fire(id) do
    receive do
      {:fire, ^id} -> :ok
    after
      0 -> :ok
    end
  end

  # -- job construction -------------------------------------------------------

  defp build_job(attrs, state) do
    with {:ok, prompt} <- require_string(attrs, :prompt),
         {:ok, spec} <- require_string(attrs, :schedule),
         {:ok, id} <- resolve_id(attrs),
         {:ok, target} <- resolve_target(attrs),
         {:ok, schedule} <- Schedule.parse(spec),
         owner = attrs[:owner],
         :ok <- check_owner_limit(owner, state) do
      resolved = %{id: id, owner: owner, prompt: prompt, target: target, schedule: schedule}
      job = new_job(resolved, attrs, state.now_fn.())

      if Map.has_key?(state.jobs, job.id),
        do: {:error, :duplicate_id},
        else: {:ok, job}
    end
  end

  defp new_job(resolved, attrs, now) do
    %{
      id: resolved.id,
      owner: resolved.owner,
      prompt: resolved.prompt,
      schedule_spec: resolved.schedule.source,
      schedule: resolved.schedule,
      skills: normalize_skills(attrs[:skills]),
      target: resolved.target,
      enabled: Map.get(attrs, :enabled, true),
      next_fire: initial_next_fire(resolved.schedule, now),
      created_at: now,
      last_fired_at: nil,
      fire_count: 0
    }
  end

  defp initial_next_fire(schedule, now) do
    case Schedule.next_fire(schedule, now) do
      {:ok, next} -> next
      :never -> nil
    end
  end

  defp apply_changes(job, changes, state) do
    with {:ok, schedule_spec, schedule} <- maybe_reparse(job, changes) do
      now = state.now_fn.()

      updated =
        job
        |> maybe_put(:prompt, string_change(changes, :prompt))
        |> maybe_put(:skills, skills_change(changes))
        |> maybe_put(:target, target_change(changes))
        |> maybe_put(:enabled, bool_change(changes, :enabled))
        |> Map.put(:schedule_spec, schedule_spec)
        |> Map.put(:schedule, schedule)

      # A schedule change recomputes the next fire from now.
      updated =
        if Map.has_key?(changes, :schedule),
          do: %{updated | next_fire: initial_next_fire(schedule, now)},
          else: updated

      {:ok, updated}
    end
  end

  defp maybe_reparse(job, changes) do
    case Map.fetch(changes, :schedule) do
      {:ok, spec} when is_binary(spec) ->
        case Schedule.parse(spec) do
          {:ok, schedule} -> {:ok, schedule.source, schedule}
          {:error, _reason} = error -> error
        end

      {:ok, _bad} ->
        {:error, :invalid_schedule}

      :error ->
        {:ok, job.schedule_spec, job.schedule}
    end
  end

  defp check_owner_limit(nil, _state), do: :ok

  defp check_owner_limit(owner, state) do
    count = Enum.count(state.jobs, fn {_id, job} -> job.owner == owner end)
    if count >= state.max_per_owner, do: {:error, :owner_limit_reached}, else: :ok
  end

  # -- persistence ------------------------------------------------------------

  defp open_store(opts) do
    case Dets.resolve_path(opts, :raxol_agent, :scheduler_dets_path) do
      nil ->
        nil

      path ->
        Dets.open!(Keyword.get(opts, :dets_name, __MODULE__.Jobs), path, fn _record -> :ok end)
    end
  end

  # Reload persisted jobs, reparse each schedule once, and re-arm from the
  # stored next-fire time. A job whose schedule no longer parses is dropped.
  defp replay(%{dets: nil} = state), do: state

  defp replay(state) do
    :dets.foldl(fn {id, stored}, acc -> replay_job(acc, id, stored) end, state, state.dets)
  end

  defp replay_job(state, id, stored) do
    case Schedule.parse(stored.schedule_spec) do
      {:ok, schedule} ->
        job = Map.put(stored, :schedule, schedule)
        state |> Map.update!(:jobs, &Map.put(&1, id, job)) |> arm(id)

      {:error, reason} ->
        Logger.warning("scheduler dropping job #{id}: unparseable schedule #{inspect(reason)}")
        Dets.delete(state.dets, id)
        state
    end
  end

  # The `:schedule` struct is derived from `:schedule_spec`, so it is dropped
  # before persisting and reparsed on replay -- no struct is stored on disk.
  defp put_job(state, job) do
    Dets.put(state.dets, job.id, Map.delete(job, :schedule))
    %{state | jobs: Map.put(state.jobs, job.id, job)}
  end

  # -- change helpers ---------------------------------------------------------

  defp string_change(changes, key) do
    case Map.get(changes, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp bool_change(changes, key) do
    case Map.get(changes, key) do
      value when is_boolean(value) -> value
      _other -> nil
    end
  end

  defp skills_change(changes) do
    case Map.fetch(changes, :skills) do
      {:ok, skills} -> normalize_skills(skills)
      :error -> nil
    end
  end

  defp target_change(changes) do
    case Map.fetch(changes, :target) do
      {:ok, nil} -> :unset
      {:ok, target} when is_binary(target) -> target
      _other -> nil
    end
  end

  defp maybe_put(job, _key, nil), do: job
  defp maybe_put(job, :target, :unset), do: %{job | target: nil}
  defp maybe_put(job, key, value), do: Map.put(job, key, value)

  # -- misc -------------------------------------------------------------------

  defp fetch!(state, id), do: Map.fetch!(state.jobs, id)

  defp require_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing, key}}
    end
  end

  # A caller-supplied id must be a non-empty binary (it keys the job map, the
  # DETS store, and the `"cron:" <> id` thread-log id); otherwise generate one.
  defp resolve_id(attrs) do
    case Map.get(attrs, :id) do
      nil -> {:ok, generate_id()}
      id when is_binary(id) and id != "" -> {:ok, id}
      _other -> {:error, :invalid_id}
    end
  end

  # Validate `target` at creation the same way `update/3` does, so a malformed
  # target can never reach the delivery seam.
  defp resolve_target(attrs) do
    case Map.get(attrs, :target) do
      nil -> {:ok, nil}
      target when is_binary(target) -> {:ok, target}
      _other -> {:error, :invalid_target}
    end
  end

  defp normalize_skills(nil), do: []
  defp normalize_skills(skills) when is_list(skills), do: Enum.filter(skills, &is_binary/1)
  defp normalize_skills(_other), do: []

  defp generate_id, do: "job_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp default_runner(_job), do: {:error, :no_runner_configured}

  defp default_deliver(target, _output) do
    Logger.debug(fn -> "scheduler: no deliver configured for target #{inspect(target)}" end)
    :ok
  end

  defp default_dispatch(fun), do: spawn(fun)
end
