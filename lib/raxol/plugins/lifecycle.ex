defmodule Raxol.Plugins.Lifecycle do
  @moduledoc """
  Handles the lifecycle management of Raxol plugins.

  This includes loading, unloading, enabling, disabling, and managing
  dependencies and configuration persistence.
  """


  alias Raxol.Plugins.{Manager, PluginConfig}

  alias Raxol.Plugins.Lifecycle.{
    Dependencies,
    ErrorHandling,
    Initialization,
    ManagerUpdate
  }

  @doc """
  Loads a single plugin module and initializes it.

  Handles configuration merging, API compatibility checks, dependency checks,
  and saving the updated configuration.
  Returns `{:ok, updated_manager}` or `{:error, reason}`.
  """
  @spec load_plugin(Manager.t(), atom(), map()) ::
          {:ok, Manager.t()} | {:error, String.t()}
  def load_plugin(%Manager{} = manager, module, config \\ %{})
      when is_atom(module) do
    plugin_name = Initialization.get_plugin_id_from_metadata(module)

    case load_plugin_internal(manager, plugin_name, module, config) do
      {:ok, updated_manager} -> {:ok, updated_manager}
      {:error, reason} -> {:error, format_load_error(reason, module)}
    end
  end

  defp load_plugin_internal(manager, plugin_name, module, config) do
    with {:ok, plugin, merged_config, plugin_state} <-
           Initialization.initialize_plugin_with_config(
             manager,
             plugin_name,
             module,
             config
           ),
         :ok <- Dependencies.validate_plugin_dependencies(plugin, manager),
         {:ok, updated_manager} <-
           ManagerUpdate.update_manager_with_plugin(
             manager,
             plugin,
             plugin_name,
             merged_config,
             plugin_state
           ) do
      {:ok, updated_manager}
    else
      {:error, :missing_dependencies, missing, chain} ->
        {:error, {:missing_dependencies, missing, chain}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_load_error({:missing_dependencies, missing, chain}, module) do
    ErrorHandling.format_missing_dependencies_error(missing, chain, module)
  end

  defp format_load_error(reason, module) do
    ErrorHandling.format_error(reason, module)
  end

  @doc """
  Loads multiple plugins in the correct dependency order.

  Initializes all plugins first, resolves dependencies, then loads them
  one by one using `load_plugin/3`.
  Returns `{:ok, updated_manager}` or `{:error, reason}`.
  """
  @spec load_plugins(Manager.t(), list(atom())) ::
          {:ok, Manager.t()} | {:error, String.t()}
  def load_plugins(%Manager{} = manager, modules) when is_list(modules) do
    module_configs = prepare_module_configs(modules)

    with {:ok, initialized_plugins} <-
           initialize_all_plugins_with_configs(
             manager,
             module_configs
           ),
         {:ok, sorted_plugin_names} <-
           Dependencies.resolve_plugin_order(initialized_plugins),
         {:ok, final_manager} <-
           load_plugins_in_order(
             manager,
             initialized_plugins,
             sorted_plugin_names
           ) do
      {:ok, build_final_manager(final_manager, sorted_plugin_names)}
    else
      error -> ErrorHandling.handle_load_plugins_error(error)
    end
  end

  defp prepare_module_configs(modules) do
    Enum.map(modules, fn
      {module, config} -> {module, config}
      module -> {module, %{}}
    end)
  end

  defp build_final_manager(manager, sorted_plugin_names) do
    loaded_plugins =
      manager.plugins
      |> Map.merge(manager.loaded_plugins)

    load_order =
      Enum.map(sorted_plugin_names, &Dependencies.normalize_plugin_key/1)

    %{manager | loaded_plugins: loaded_plugins, load_order: load_order}
  end

  defp initialize_all_plugins_with_configs(manager, module_configs) do
    Enum.reduce_while(module_configs, {:ok, []}, fn {module, config},
                                                    {:ok, acc_plugins} ->
      plugin_name = Initialization.get_plugin_id_from_metadata(module)

      case Initialization.initialize_plugin_with_config(
             manager,
             plugin_name,
             module,
             config
           ) do
        {:ok, plugin, _merged_config, _plugin_state} ->
          {:cont, {:ok, [plugin | acc_plugins]}}

        {:error, reason} ->
          {:halt, {:error, :init_failed, module, reason}}
      end
    end)
  end

  @doc """
  Unloads a plugin by name.

  Calls the plugin's `cleanup/1` callback, updates the configuration to disable
  the plugin, saves the configuration, and removes the plugin from the manager state.
  Returns `{:ok, updated_manager}` or `{:error, reason}`.
  """
  @spec unload_plugin(Manager.t(), String.t()) ::
          {:ok, Manager.t()} | {:error, String.t()}
  def unload_plugin(%Manager{} = manager, name) when is_binary(name) do
    plugin_key = Dependencies.normalize_plugin_key(name)

    case Map.get(manager.plugins, plugin_key) do
      nil ->
        {:error, "Plugin #{name} not found"}

      plugin ->
        with :ok <- do_plugin_cleanup_and_stop(plugin),
             {:ok, updated_manager} <-
               update_config_and_remove_plugin(manager, plugin, name) do
          {:ok, updated_manager}
        else
          {:error, reason} ->
            {:error, "Failed to cleanup plugin #{name}: #{inspect(reason)}"}
        end
    end
  end

  defp do_plugin_cleanup_and_stop(plugin) do
    module = plugin.module
    plugin_config = plugin.config || %{}

    with :ok <- call_plugin_stop_with_config(plugin, module, plugin_config),
         :ok <- module.cleanup(plugin_config) do
      :ok
    else
      error -> error
    end
  end

  defp call_plugin_stop_with_config(_plugin, module, plugin_config) do
    handle_plugin_stop(
      function_exported?(module, :stop, 1),
      module,
      plugin_config
    )
  end

  defp handle_plugin_stop(false, _module, _plugin_config) do
    :ok
  end

  defp handle_plugin_stop(true, module, plugin_config) do
    case module.stop(plugin_config) do
      {:ok, _updated_state} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_config_and_remove_plugin(manager, _plugin, name) do
    plugin_key = Dependencies.normalize_plugin_key(name)
    updated_config = PluginConfig.disable_plugin(manager.config, name)

    case PluginConfig.save(updated_config) do
      {:ok, saved_config} ->
        {:ok,
         %{
           manager
           | plugins: Map.delete(manager.plugins, plugin_key),
             loaded_plugins: Map.delete(manager.loaded_plugins, plugin_key),
             plugin_states: Map.delete(manager.plugin_states, plugin_key),
             config: saved_config
         }}

      {:error, reason} ->
        ErrorHandling.log_config_save_error(name, reason)

        {:ok,
         %{
           manager
           | plugins: Map.delete(manager.plugins, plugin_key),
             loaded_plugins: Map.delete(manager.loaded_plugins, plugin_key),
             plugin_states: Map.delete(manager.plugin_states, plugin_key),
             config: manager.config
         }}
    end
  end

  @doc """
  Enables a plugin by name.

  Checks dependencies, updates the configuration to enable the plugin,
  saves the configuration, and updates the plugin state in the manager.
  Returns `{:ok, updated_manager}` or `{:error, reason}`.
  """
  @spec enable_plugin(Manager.t(), String.t()) ::
          {:ok, Manager.t()} | {:error, String.t()}
  def enable_plugin(%Manager{} = manager, name) when is_binary(name) do
    with {:ok, plugin} <- get_plugin(manager, name),
         :ok <- check_plugin_dependencies(plugin, manager),
         {:ok, updated_config} <-
           ManagerUpdate.update_and_save_config(manager, name, :enable) do
      {:ok,
       ManagerUpdate.update_manager_state(manager, plugin, updated_config, true)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_plugin(manager, name) do
    plugin_key = Dependencies.normalize_plugin_key(name)
    plugin = Map.get(manager.plugins, plugin_key)
    validate_plugin_existence(plugin, name)
  end

  defp validate_plugin_existence(nil, name) do
    {:error, "Plugin #{name} not found"}
  end

  defp validate_plugin_existence(plugin, _name) do
    {:ok, plugin}
  end

  defp check_plugin_dependencies(plugin, manager) do
    Dependencies.check_dependencies(plugin, manager)
  end

  @doc """
  Disables a plugin by name.

  Updates the configuration to disable the plugin, saves the configuration,
  and updates the plugin state in the manager.
  Returns `{:ok, updated_manager}` or `{:error, reason}`.
  """
  @spec disable_plugin(Manager.t(), String.t()) ::
          {:ok, Manager.t()} | {:error, String.t()}
  def disable_plugin(%Manager{} = manager, name) when is_binary(name) do
    case get_plugin(manager, name) do
      {:ok, plugin} ->
        {:ok, updated_config} =
          ManagerUpdate.update_and_save_config(manager, name, :disable)

        {:ok,
         ManagerUpdate.update_manager_state(
           manager,
           plugin,
           updated_config,
           false
         )}

      {:error, _} ->
        {:error, "Plugin #{name} not found"}
    end
  end

  # --- Private Helper Functions for load_plugins/2 ---

  defp load_plugins_in_order(manager, initialized_plugins, sorted_plugin_names) do
    Enum.reduce_while(
      sorted_plugin_names,
      {:ok, manager},
      &load_single_plugin(&1, &2, initialized_plugins)
    )
  end

  defp load_single_plugin(plugin_name, {:ok, acc_manager}, initialized_plugins) do
    case find_and_load_plugin(plugin_name, acc_manager, initialized_plugins) do
      {:ok, updated_manager} ->
        case call_plugin_start(
               plugin_name,
               updated_manager,
               initialized_plugins
             ) do
          {:ok, final_manager} -> {:cont, {:ok, final_manager}}
          error -> {:halt, error}
        end

      error ->
        {:halt, error}
    end
  end

  defp call_plugin_start(plugin_name, manager, initialized_plugins) do
    case find_plugin_and_start(plugin_name, manager, initialized_plugins) do
      {:ok, updated_manager} -> {:ok, updated_manager}
      {:error, reason} -> {:error, :start_failed, plugin_name, reason}
    end
  end

  defp find_plugin_and_start(plugin_name, manager, initialized_plugins) do
    plugin_name_str = normalize_plugin_name(plugin_name)

    case Enum.find(initialized_plugins, &(&1.name == plugin_name_str)) do
      nil -> {:error, "Plugin not found"}
      plugin -> start_plugin_if_supported(plugin, manager)
    end
  end

  defp normalize_plugin_name(plugin_name) when is_atom(plugin_name) do
    Atom.to_string(plugin_name)
  end

  defp normalize_plugin_name(plugin_name) do
    plugin_name
  end

  defp start_plugin_if_supported(plugin, manager) do
    check_start_function_support(
      function_exported?(plugin.module, :start, 1),
      plugin,
      manager
    )
  end

  defp check_start_function_support(false, _plugin, manager) do
    {:ok, manager}
  end

  defp check_start_function_support(true, plugin, manager) do
    handle_plugin_start(plugin, manager)
  end

  defp handle_plugin_start(plugin, manager) do
    case plugin.module.start(plugin.config) do
      {:ok, updated_config} ->
        updated_plugin = %{plugin | config: updated_config}

        ManagerUpdate.update_manager_with_plugin_config(
          manager,
          updated_plugin,
          updated_config
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_and_load_plugin(plugin_name, acc_manager, initialized_plugins) do
    plugin_name_str = normalize_plugin_name(plugin_name)

    case Enum.find(initialized_plugins, &(&1.name == plugin_name_str)) do
      plugin when not is_nil(plugin) ->
        plugin_key = Dependencies.normalize_plugin_key(plugin.name)
        updated_plugins = Map.put(acc_manager.plugins, plugin_key, plugin)

        updated_loaded_plugins =
          Map.put(acc_manager.loaded_plugins, plugin_key, plugin)

        updated_plugin_states =
          Map.put(acc_manager.plugin_states, plugin_key, plugin.state || %{})

        {:ok,
         %{
           acc_manager
           | plugins: updated_plugins,
             loaded_plugins: updated_loaded_plugins,
             plugin_states: updated_plugin_states
         }}

      nil ->
        Raxol.Core.Runtime.Log.error(
          "Plugin #{plugin_name} found in sorted list but not in initialized list."
        )

        {:error, :load_failed, plugin_name, "Not found in initialized list"}
    end
  end
end
