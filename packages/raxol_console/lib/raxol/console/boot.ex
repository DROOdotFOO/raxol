defmodule Raxol.Console.Boot do
  @moduledoc """
  Boot a Console runtime from a `Raxol.Console.RuntimeConfig`.

  `start/2` brings up `Raxol.Console.Supervisor` (the scheduler wired with the
  agent's persona + delivery, plus a reconciler) and returns a boot report.
  `reconcile_jobs/2` is the convergence step: it makes a running scheduler's job
  set match the desired `tasks.json` jobs, keyed by task name (the stable id), so
  a reboot updates and prunes rather than duplicating (the scheduler is
  DETS-persisted and replays on start).
  """

  alias Raxol.Agent.Scheduler

  @type jobs_report :: %{
          created: [String.t()],
          updated: [String.t()],
          removed: [String.t()]
        }

  @type report :: %{supervisor: pid(), jobs: jobs_report()}

  @doc """
  Start the Console runtime tree for `runtime_config` and reconcile its jobs.

  Options are forwarded to `Raxol.Console.Supervisor` (`:adapters`,
  `:scheduler_name`, `:reconciler_name`, `:name`). Returns `{:ok, report}` with
  the supervisor pid and the reconciliation result.
  """
  @spec start(Raxol.Console.RuntimeConfig.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def start(runtime_config, opts \\ []) do
    reconciler = Keyword.get(opts, :reconciler_name, Raxol.Console.Reconciler)

    case Raxol.Console.Supervisor.start_link([{:runtime_config, runtime_config} | opts]) do
      {:ok, sup} -> {:ok, %{supervisor: sup, jobs: Raxol.Console.Reconciler.report(reconciler)}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Converge the scheduler's jobs to `desired`.

  Creates jobs missing from the scheduler, updates ones whose definition changed
  (prompt / schedule / target / enabled / skills), and removes ones no longer
  desired. Returns the ids in each bucket.
  """
  @spec reconcile_jobs(GenServer.server(), [map()]) :: jobs_report()
  def reconcile_jobs(server, desired) when is_list(desired) do
    existing = server |> Scheduler.list() |> Map.new(&{&1.id, &1})
    desired_ids = MapSet.new(desired, & &1.id)

    {created, updated} =
      Enum.reduce(desired, {[], []}, fn job, {created, updated} ->
        case Map.get(existing, job.id) do
          nil ->
            {:ok, _} = Scheduler.create(server, job)
            {[job.id | created], updated}

          current ->
            if changed?(current, job) do
              {:ok, _} = Scheduler.update(server, job.id, Map.delete(job, :id))
              {created, [job.id | updated]}
            else
              {created, updated}
            end
        end
      end)

    removed =
      existing
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(desired_ids, &1))
      |> Enum.map(fn id ->
        :ok = Scheduler.remove(server, id)
        id
      end)

    %{created: Enum.reverse(created), updated: Enum.reverse(updated), removed: Enum.sort(removed)}
  end

  # A live job carries the ORIGINAL schedule string as `schedule_spec` (plus a
  # parsed `schedule`); compare against the desired job's `schedule` string.
  defp changed?(current, job) do
    current.prompt != job.prompt or
      current.schedule_spec != job.schedule or
      current.target != job.target or
      current.enabled != job.enabled or
      current.skills != Map.get(job, :skills, [])
  end
end
