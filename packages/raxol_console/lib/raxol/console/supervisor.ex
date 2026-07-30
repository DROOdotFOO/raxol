defmodule Raxol.Console.Supervisor do
  @moduledoc """
  Supervision tree for a booted Console runtime.

  Children (`:rest_for_one`):

    * `Raxol.Agent.Skills.Store` -- present only when the package ships skills
      (`:skills_store` + `:skills_dir` set); a read-only index over the package's
      `skills/` directory. First child, so it is up before the scheduler and chat
      handler that reference it.
    * `Raxol.Agent.Scheduler` -- wired with the agent's persona + executor
      (`:runner`), gateway delivery (`:deliver`), and the skills store (when
      present) via `Raxol.Console.Scheduler.Wiring`.
    * `Raxol.Console.Reconciler` -- converges the scheduler's jobs to the runtime
      config's `tasks.json` jobs once the scheduler is up.
    * `Raxol.Gateway.Supervisor` -- the channel subtree, present only when
      `Raxol.Console.Boot` connected at least one channel.
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
    skills_store = Keyword.get(opts, :skills_store)

    scheduler_opts =
      %{
        adapters: adapters,
        system_prompt: config.system_prompt,
        agent_opts: config.agent_opts
      }
      |> maybe_put(:skills_store, skills_store)
      |> Wiring.scheduler_opts()
      |> Keyword.put(:name, scheduler_name)

    children =
      skills_child(opts) ++
        [
          {Raxol.Agent.Scheduler, scheduler_opts},
          {Reconciler,
           name: reconciler_name, scheduler: scheduler_name, jobs: config.scheduler_jobs}
        ] ++ gateway_child(opts)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # The skills store indexes the package's `skills/` directory read-only. Its
  # managed root points at an unused sibling dir so the store never falls back to
  # the developer's global `~/.raxol/skills` -- a Console runtime is hermetic.
  defp skills_child(opts) do
    case {Keyword.get(opts, :skills_store), Keyword.get(opts, :skills_dir)} do
      {store, dir} when not is_nil(store) and is_binary(dir) ->
        managed = Path.join(Path.dirname(dir), ".raxol-managed-skills")

        [
          {Raxol.Agent.Skills.Store, name: store, external_dirs: [dir], skills_root: managed}
        ]

      _ ->
        []
    end
  end

  # The gateway subtree (channels + per-chat sessions running the agent handler)
  # is present only when `Raxol.Console.Boot` connected at least one channel.
  defp gateway_child(opts) do
    case Keyword.get(opts, :gateway) do
      nil -> []
      gateway_opts -> [{Raxol.Gateway.Supervisor, gateway_opts}]
    end
  end
end
