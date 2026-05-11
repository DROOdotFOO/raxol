defmodule Raxol.Core.Runtime.Plugins.Loader do
  @moduledoc """
  Manages plugin loading operations.
  """

  use Raxol.Core.Behaviours.BaseManager

  @behaviour Raxol.Core.Runtime.Plugins.LoaderBehaviour

  require Logger

  defstruct [
    :loaded_plugins,
    :plugin_configs,
    :plugin_metadata
  ]

  @type t :: %__MODULE__{
          loaded_plugins: map(),
          plugin_configs: map(),
          plugin_metadata: map()
        }

  # Client API

  @doc """
  Loads a plugin from the given path.
  """
  # Implementation of load_plugin/1 (not part of behaviour)
  def load_plugin(plugin_path) when is_binary(plugin_path) do
    load_plugin(plugin_path, [])
  end

  @impl Raxol.Core.Runtime.Plugins.LoaderBehaviour
  def load_plugin(plugin_spec, opts \\ []) do
    GenServer.call(__MODULE__, {:load_plugin, plugin_spec, opts})
  end

  @doc """
  Unloads a plugin.
  """
  @impl Raxol.Core.Runtime.Plugins.LoaderBehaviour
  def unload_plugin(plugin) do
    GenServer.call(__MODULE__, {:unload_plugin, plugin})
  end

  @doc """
  Reloads a plugin.
  """
  # reload_plugin is not part of the behaviour
  def reload_plugin(plugin) do
    GenServer.call(__MODULE__, {:reload_plugin, plugin})
  end

  @doc """
  Gets the list of loaded plugins.
  """
  # get_loaded_plugins is not part of the behaviour
  def get_loaded_plugins do
    GenServer.call(__MODULE__, :get_loaded_plugins)
  end

  @doc """
  Checks if a plugin is loaded.
  """
  # plugin_loaded? is not part of the behaviour
  def plugin_loaded?(plugin) do
    GenServer.call(__MODULE__, {:plugin_loaded?, plugin})
  end

  @impl Raxol.Core.Runtime.Plugins.LoaderBehaviour
  def list_available_plugins(opts \\ []) do
    case Keyword.get(opts, :plugin_dirs, []) do
      [] ->
        []

      dirs when is_list(dirs) ->
        case discover_plugins(dirs) do
          {:ok, plugins} -> plugins
          {:error, _} -> []
        end
    end
  end

  @impl Raxol.Core.Runtime.Plugins.LoaderBehaviour
  def validate_plugin(plugin_spec) do
    # Simple validation - just check if it's a valid module or path
    case plugin_spec do
      spec when is_atom(spec) or is_binary(spec) -> :ok
      _ -> {:error, :invalid_plugin_spec}
    end
  end

  @doc """
  Discovers plugins in the given directories.
  Returns a list of discovered plugin paths.
  """
  def discover_plugins(plugin_dirs) when is_list(plugin_dirs) do
    discovered_plugins =
      plugin_dirs
      |> Enum.flat_map(fn dir ->
        case File.dir?(dir) do
          true ->
            dir
            |> File.ls!()
            |> Enum.filter(&String.ends_with?(&1, ".ex"))
            |> Enum.map(&Path.join(dir, &1))

          false ->
            []
        end
      end)
      |> Enum.uniq()

    {:ok, discovered_plugins}
  end

  def discover_plugins(_) do
    {:error, :invalid_directories}
  end

  # Server Callbacks

  @impl true
  def init_manager(_opts) do
    state = %__MODULE__{
      loaded_plugins: %{},
      plugin_configs: %{},
      plugin_metadata: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:load_plugin, plugin_path}, _from, state) do
    case do_load_plugin(plugin_path, state) do
      {:ok, new_state} ->
        {:reply, {:ok, Map.get(new_state.loaded_plugins, plugin_path)}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call({:unload_plugin, plugin}, _from, state) do
    case do_unload_plugin(plugin, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call({:reload_plugin, plugin}, _from, state) do
    case do_reload_plugin(plugin, state) do
      {:ok, new_state} ->
        {:reply, {:ok, Map.get(new_state.loaded_plugins, plugin)}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call(:get_loaded_plugins, _from, state) do
    {:reply, Map.values(state.loaded_plugins), state}
  end

  @impl true
  def handle_manager_call({:plugin_loaded?, plugin}, _from, state) do
    {:reply, Map.has_key?(state.loaded_plugins, plugin), state}
  end

  # Private Functions

  defp do_load_plugin(plugin_path, state) do
    compiled_modules = Code.compile_file(plugin_path)

    case compiled_modules do
      [{plugin_module, _binary} | _] ->
        {:ok, plugin_metadata} = extract_metadata(plugin_module)

        case initialize_plugin(plugin_module, %{}) do
          {:ok, _initial_state} ->
            new_state = %{
              state
              | loaded_plugins: Map.put(state.loaded_plugins, plugin_path, plugin_module),
                plugin_configs: Map.put(state.plugin_configs, plugin_path, %{}),
                plugin_metadata: Map.put(state.plugin_metadata, plugin_path, plugin_metadata)
            }

            {:ok, new_state}

          {:error, reason} ->
            {:error, reason}
        end

      [] ->
        {:error, :no_modules_compiled}
    end
  rescue
    e -> {:error, e}
  end

  defp do_unload_plugin(plugin, state) do
    case Map.get(state.loaded_plugins, plugin) do
      nil ->
        {:error, :plugin_not_found}

      plugin_module ->
        :code.purge(plugin_module)

        new_state = %{
          state
          | loaded_plugins: Map.delete(state.loaded_plugins, plugin),
            plugin_configs: Map.delete(state.plugin_configs, plugin),
            plugin_metadata: Map.delete(state.plugin_metadata, plugin)
        }

        {:ok, new_state}
    end
  end

  defp do_reload_plugin(plugin, state) do
    with {:ok, new_state} <- do_unload_plugin(plugin, state),
         {:ok, final_state} <- do_load_plugin(plugin, new_state) do
      {:ok, final_state}
    else
      error -> error
    end
  end

  def extract_metadata(module) do
    case function_exported?(module, :plugin_info, 0) do
      true -> {:ok, module.plugin_info()}
      false -> {:ok, %{name: module, version: "1.0.0"}}
    end
  end

  def initialize_plugin(module, config) do
    case function_exported?(module, :init, 1) do
      true ->
        case module.init(config) do
          {:ok, state} -> {:ok, state}
          state when is_map(state) -> {:ok, state}
          _ -> {:error, :invalid_init_return}
        end

      false ->
        {:ok, %{}}
    end
  end

  @doc """
  Checks if a module implements the given behaviour.
  """
  def behaviour_implemented?(module, behaviour) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           check_behaviour_implementation(module, behaviour)
         end) do
      {:ok, result} -> result
      {:error, _} -> false
    end
  end

  @doc """
  Loads code for a plugin by its ID.
  """
  def load_code(id) when is_binary(id) do
    # This is a simplified implementation
    # In a real implementation, this would load the actual plugin code
    case String.ends_with?(id, ".ex") or String.ends_with?(id, ".exs") do
      true ->
        # Assume it's a file path
        case Code.compile_file(id) do
          [{module, _}] -> {:ok, module}
          _ -> {:error, :compilation_failed}
        end

      false ->
        # Assume it's a module name
        load_module_by_name(id)
    end
  end

  def load_code(_id) do
    {:error, :invalid_id}
  end

  defp check_behaviour_implementation(module, behaviour) do
    # Check if the module has the behaviour attribute
    module_info = module.module_info(:attributes)
    behaviours = Keyword.get_values(module_info, :behaviour)

    case behaviour in behaviours do
      true ->
        true

      false ->
        # Fallback: check if the module has the required callbacks
        # This is a simplified check - in a real implementation you'd check all callbacks
        function_exported?(module, :plugin_info, 0)
    end
  end

  defp load_module_by_name(id) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           ensure_module_loaded(id)
         end) do
      {:ok, result} -> result
      {:error, _} -> {:error, :module_not_found}
    end
  end

  defp ensure_module_loaded(id) do
    module = String.to_existing_atom(id)

    case Code.ensure_loaded(module) do
      {:module, ^module} -> {:ok, module}
      _ -> {:error, :module_not_found}
    end
  end
end
