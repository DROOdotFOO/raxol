defmodule Raxol.Agent.Supervisor do
  @moduledoc """
  Supervision subtree for the agent subsystem.

  Children:
  - `Raxol.Agent.Registry` -- unique Registry for agent discovery
  - `Raxol.Agent.DynSup` -- DynamicSupervisor for Agent.Process instances
  - `Raxol.Agent.Orchestrator` -- multi-agent coordinator
  - `Raxol.Agent.Memory.Store.Ets` -- when configured as the memory provider
  - `Raxol.Agent.Skills.Store` -- when a skills provider is configured
  - `Raxol.Agent.Curator` -- when a `:curator` config is set

  Strategy is `:rest_for_one`: if the DynSup crashes, the Orchestrator
  restarts and rebuilds from ContextStore. If the Registry crashes,
  everything restarts.
  """

  use Supervisor

  # Idempotent: the subtree is named, and more than one caller legitimately
  # tries to bring it up -- RaxolAgent.Application, the main `raxol` app's
  # maybe_add_agent_supervisor, and the example/test scripts that boot it
  # manually. Whoever wins, everyone else gets the same running subtree back
  # instead of an :already_started crash.
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    case Supervisor.start_link(__MODULE__, opts, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @impl true
  def init(_opts) do
    children =
      [
        {Registry, keys: :unique, name: Raxol.Agent.Registry},
        {DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one},
        Raxol.Agent.Orchestrator
      ] ++ memory_children() ++ skills_children() ++ curator_children()

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Start the default ETS memory store only when it is the configured provider.
  defp memory_children do
    case Application.get_env(:raxol_agent, :memory_provider) do
      Raxol.Agent.Memory.Store.Ets -> [Raxol.Agent.Memory.Store.Ets]
      _ -> []
    end
  end

  # Start the skills store only when a skills provider is configured.
  defp skills_children do
    case Application.get_env(:raxol_agent, :skills_provider) do
      Raxol.Agent.Skills.Store -> [Raxol.Agent.Skills.Store]
      _ -> []
    end
  end

  # Start the Curator only when a :curator config (a keyword list including
  # `:skills`) is set.
  defp curator_children do
    case Application.get_env(:raxol_agent, :curator) do
      opts when is_list(opts) -> [{Raxol.Agent.Curator, opts}]
      _ -> []
    end
  end
end
