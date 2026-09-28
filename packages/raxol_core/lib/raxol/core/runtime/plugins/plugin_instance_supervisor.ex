defmodule Raxol.Core.Runtime.Plugins.PluginInstanceSupervisor do
  @moduledoc """
  Owns the stable runtime process for one loaded plugin.

  Instances run below a `DynamicSupervisor`, so stopping one plugin cannot stop
  another plugin or the core runtime.
  """

  use Supervisor

  alias Raxol.Core.Runtime.Plugins.PluginRuntime

  @process_registry Raxol.Core.Runtime.Plugins.ProcessRegistry
  @dynamic_supervisor Raxol.Core.Runtime.Plugins.InstanceDynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    plugin_id = Keyword.fetch!(opts, :plugin_id)
    Supervisor.start_link(__MODULE__, opts, name: instance_name(plugin_id))
  end

  @spec start_plugin(atom() | String.t(), module(), map()) ::
          {:ok, pid()} | {:error, term()}
  def start_plugin(plugin_id, module, config) do
    spec = {__MODULE__, plugin_id: plugin_id, module: module, config: config}
    DynamicSupervisor.start_child(@dynamic_supervisor, spec)
  end

  @spec stop_plugin(atom() | String.t()) :: :ok | {:error, :not_found}
  def stop_plugin(plugin_id) do
    case instance_pid(plugin_id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(@dynamic_supervisor, pid)
    end
  end

  @spec instance_pid(atom() | String.t()) :: pid() | nil
  def instance_pid(plugin_id), do: whereis(instance_name(plugin_id))

  @spec runtime_pid(atom() | String.t()) :: pid() | nil
  def runtime_pid(plugin_id), do: whereis(runtime_name(plugin_id))

  @doc false
  def instance_name(plugin_id), do: via(plugin_id, :instance)

  @doc false
  def runtime_name(plugin_id), do: via(plugin_id, :runtime)

  @impl Supervisor
  def init(opts) do
    children = [
      {PluginRuntime,
       plugin_id: Keyword.fetch!(opts, :plugin_id),
       module: Keyword.fetch!(opts, :module),
       config: Keyword.get(opts, :config, %{})}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp via(plugin_id, role) do
    {:via, Registry, {@process_registry, {normalize_id(plugin_id), role}}}
  end

  defp whereis(name) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> pid
      nil -> nil
    end
  end

  defp normalize_id(id) when is_atom(id), do: id

  defp normalize_id(id) when is_binary(id) do
    String.to_existing_atom(id)
  rescue
    ArgumentError -> id
  end
end
