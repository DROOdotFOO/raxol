defmodule Raxol.Console.Supervisor do
  @moduledoc """
  Supervision tree for a booted Console runtime.

  Children (`:rest_for_one`):

    * MCP `DynamicSupervisor` -- present only when `Raxol.Console.Boot` bundled
      MCP servers (`:mcp_supervisor_name` set). Started empty here and owned by
      this tree (so it is torn down on stop, not leaked on the boot caller); Boot
      then loads the server clients into it. It is the FIRST, `:temporary` child,
      so no unrelated restart terminates it (`:rest_for_one` only restarts
      children started AFTER a crash), and if it ever dies it stays dead rather
      than restarting empty.
    * `Raxol.Agent.Skills.Store` -- present only when the package ships skills
      (`:skills_store` + `:skills_dir` set); a read-only index over the package's
      `skills/` directory. Up before the scheduler and chat handler that
      reference it.
    * `Raxol.Agent.Scheduler` -- wired with the agent's persona + executor
      (`:runner`), gateway delivery (`:deliver`), and the skills store (when
      present) via `Raxol.Console.Scheduler.Wiring`.
    * `Raxol.Console.Reconciler` -- converges the scheduler's jobs to the runtime
      config's `tasks.json` jobs once the scheduler is up.

  The gateway channel subtree is NOT a static child: `Raxol.Console.Boot` adds it
  dynamically as the last child once MCP tools resolve (its chat handler needs
  them at build time), present only when at least one channel is connected.
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
      mcp_child(opts) ++
        skills_child(opts) ++
        [
          {Raxol.Agent.Scheduler, scheduler_opts},
          {Reconciler,
           name: reconciler_name, scheduler: scheduler_name, jobs: config.scheduler_jobs}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Start the MCP DynamicSupervisor empty as the first, `:temporary` child (Boot
  # loads clients into it by name in its second phase). Owned by this tree so it
  # is torn down on stop rather than leaking on the boot caller. `:temporary`: it
  # holds already-resolved clients, so restarting it empty would be useless -- if
  # it ever dies, leave it dead rather than cascade-restart the tree toolless.
  defp mcp_child(opts) do
    case Keyword.get(opts, :mcp_supervisor_name) do
      nil ->
        []

      name ->
        [
          Supervisor.child_spec(
            {DynamicSupervisor, strategy: :one_for_one, name: name},
            id: :mcp_supervisor,
            restart: :temporary
          )
        ]
    end
  end

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
end
