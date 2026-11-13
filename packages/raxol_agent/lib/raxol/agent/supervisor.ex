defmodule Raxol.Agent.Supervisor do
  @moduledoc """
  Supervision subtree for the agent subsystem.

  Children:
  - `Raxol.Agent.Registry` -- unique Registry for agent discovery
  - `Raxol.Agent.DynSup` -- DynamicSupervisor for Agent.Process instances
    (and per-session `Raxol.Agent.EmitBridge` sinks)
  - `Raxol.Agent.TaskSupervisor` -- a `Task.Supervisor` for unlinked
    short-lived work; nothing in the tree starts a task under it
  - `Raxol.Agent.SessionStreamer` -- singleton harness event stream
  - `Raxol.Agent.Orchestrator` -- multi-agent coordinator
  - `Raxol.Agent.Skills.Store` -- when a skills provider is configured
  - `Raxol.Agent.Scheduler` -- when a `:scheduler` config is set
  - `Raxol.Agent.McpTools` -- the `agent_*` MCP tools

  Strategy is `:rest_for_one`: if the DynSup crashes, the Orchestrator
  restarts and rebuilds from ContextStore. If the Registry crashes,
  everything restarts. `McpTools` is last, so its own restart restarts
  nothing; a restart of an earlier child restarts it, and it finds its
  running agents again in the Registry.

  `start_link(mcp_tools: opts)` passes `opts` to `Raxol.Agent.McpTools`
  (`:registry`, `:server`).
  """

  use Supervisor

  # Idempotent: the subtree is named, and more than one caller legitimately
  # tries to bring it up -- RaxolAgent.Application and the example/test
  # scripts that boot it manually. Whoever wins, everyone else gets the same
  # running subtree back instead of an :already_started crash.
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    case Supervisor.start_link(__MODULE__, opts, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @impl true
  def init(opts) do
    children =
      [
        {Registry, keys: :unique, name: Raxol.Agent.Registry},
        {DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one},
        {Task.Supervisor, name: Raxol.Agent.TaskSupervisor},
        Raxol.Agent.SessionStreamer,
        Raxol.Agent.Orchestrator
      ] ++
        skills_children() ++
        scheduler_children() ++
        mcp_tools_children(opts)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp mcp_tools_children(opts),
    do: [{Raxol.Agent.McpTools, Keyword.get(opts, :mcp_tools, [])}]

  # Start the skills store only when a skills provider is configured.
  defp skills_children do
    case Application.get_env(:raxol_agent, :skills_provider) do
      Raxol.Agent.Skills.Store -> [Raxol.Agent.Skills.Store]
      _ -> []
    end
  end

  # Start the Scheduler only when a :scheduler config (a keyword list) is set,
  # so the whole cronjob subsystem stays opt-in: an unconfigured host must not
  # acquire a timer wheel and a DETS file it never asked for.
  defp scheduler_children do
    case Application.get_env(:raxol_agent, :scheduler) do
      opts when is_list(opts) ->
        # BaseManager registers a name only when one is given; default it to the
        # module so `Scheduler.create/2` and friends resolve without an explicit
        # server argument.
        [{Raxol.Agent.Scheduler, Keyword.put_new(opts, :name, Raxol.Agent.Scheduler)}]

      _ ->
        []
    end
  end
end
