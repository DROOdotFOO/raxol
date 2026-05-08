defmodule Raxol.Symphony.Supervisor do
  @moduledoc """
  Top-level supervisor for the Symphony orchestrator.

  Children:

  - `Task.Supervisor` (worker fan-out for the orchestrator)
  - `Raxol.Symphony.WorkflowStore` (when `:workflow_path` is given) -- holds
    parsed config, watches the file for hot-reload, falls back to
    last-known-good on parse/validate errors
  - `Raxol.Symphony.Orchestrator` -- the dispatch GenServer; pulls config
    from `WorkflowStore` per tick when wired

  Pass either `:config` (static) or `:workflow_path` (loaded + watched). When
  both are given, `:workflow_path` wins.
  """

  use Supervisor

  alias Raxol.Symphony.WorkflowStore

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {workflow_store_spec, orchestrator_extra_opts} = workflow_store_child(opts)

    base_orchestrator_opts =
      Keyword.merge(
        Keyword.take(opts, [:config, :runner_module, :tracker_module, :auto_start_tick]),
        orchestrator_extra_opts
      )

    children =
      Enum.reject(
        [
          {Task.Supervisor, name: Raxol.Symphony.TaskSupervisor},
          workflow_store_spec,
          {Raxol.Symphony.Orchestrator, base_orchestrator_opts}
        ],
        &is_nil/1
      )

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp workflow_store_child(opts) do
    case Keyword.get(opts, :workflow_path) do
      nil ->
        {nil, []}

      path ->
        store_opts =
          [path: path, name: WorkflowStore]
          |> Keyword.merge(Keyword.take(opts, [:watch?, :debounce_ms]))

        {{WorkflowStore, store_opts}, [workflow_store: WorkflowStore]}
    end
  end
end
