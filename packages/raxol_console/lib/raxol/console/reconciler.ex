defmodule Raxol.Console.Reconciler do
  @moduledoc """
  Reconciles a Console runtime's scheduled jobs against the scheduler once it is
  up. Started AFTER the scheduler under `Raxol.Console.Supervisor`'s
  `:rest_for_one`, so on a scheduler restart the reconciler restarts too and
  re-converges the jobs from the runtime config. Holds the last reconciliation
  report for inspection (`report/1`).
  """

  use GenServer

  alias Raxol.Console.Boot

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "The last reconciliation report (`%{created:, updated:, removed:}`)."
  @spec report(GenServer.server()) :: Boot.jobs_report()
  def report(server), do: GenServer.call(server, :report)

  @impl true
  def init(opts) do
    scheduler = Keyword.fetch!(opts, :scheduler)
    jobs = Keyword.get(opts, :jobs, [])
    {:ok, %{scheduler: scheduler, report: Boot.reconcile_jobs(scheduler, jobs)}}
  end

  @impl true
  def handle_call(:report, _from, state), do: {:reply, state.report, state}
end
