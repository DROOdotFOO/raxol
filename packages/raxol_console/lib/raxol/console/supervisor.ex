defmodule Raxol.Console.Supervisor do
  @moduledoc """
  Supervision tree for a booted Console runtime.

  Children (`:rest_for_one`):

    * `Raxol.Agent.Scheduler` -- wired with the agent's persona + executor
      (`:runner`) and gateway delivery (`:deliver`) via
      `Raxol.Console.Scheduler.Wiring`.
    * `Raxol.Console.Reconciler` -- converges the scheduler's jobs to the runtime
      config's `tasks.json` jobs once the scheduler is up.

  The gateway channel subtree and the MCP-server bundle are added here as the
  loader grows; today this is the scheduler half of the runtime.
  """

  use Supervisor

  alias Raxol.Console.{Reconciler, Scheduler.Wiring}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :runtime_config)
    adapters = Keyword.get(opts, :adapters, %{})
    scheduler_name = Keyword.get(opts, :scheduler_name, Raxol.Console.Scheduler)
    reconciler_name = Keyword.get(opts, :reconciler_name, Reconciler)

    scheduler_opts =
      %{
        adapters: adapters,
        system_prompt: config.system_prompt,
        agent_opts: config.agent_opts
      }
      |> Wiring.scheduler_opts()
      |> Keyword.put(:name, scheduler_name)

    children = [
      {Raxol.Agent.Scheduler, scheduler_opts},
      {Reconciler, name: reconciler_name, scheduler: scheduler_name, jobs: config.scheduler_jobs}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
