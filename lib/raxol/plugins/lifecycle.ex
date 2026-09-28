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

  alias Raxol.Core.Runtime.Plugins.PluginLifecycle, as: RuntimeLifecycle
  alias Raxol.Core.Runtime.Plugins.PluginRuntime

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
    with {:ok, merged_config} <-
           Initialization.get_and_validate_config(
             manager,
             plugin_name,
             module,
             config
           ),
         {:ok, plugin} <-
           build_plugin_descriptor(plugin_name, module, merged_config),
         :ok <- Dependencies.validate_plugin_dependencies(plugin, manager),
         :ok <- RuntimeLifecycle.load(plugin_name, module, merged_config) do
      finish_plugin_load(manager, plugin, plugin_name, merged_config)
    else
      {:error, :missing_dependencies, missing, chain} ->
        {:error, {:missing_dependencies, missing, chain}}

      {:error, :version_mismatch, mismatches, chain} ->
        {:error, {:version_mismatch, mismatches, chain}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_plugin_load(manager, plugin, plugin_name, merged_config) do
    with :ok <- call_stateful_hook(plugin_name, :on_load),
         {:ok, updated_manager} <-
           ManagerUpdate.update_manager_with_plugin(
             manager,
             plugin,
             plugin_name,
             merged_config
           ) do
      {:ok, updated_manager}
    else
      {:error, reason} ->
        RuntimeLifecycle.unload(plugin_name)
        {:error, reason}
    end
  end

  defp build_plugin_descriptor(plugin_name, module, config) do
    metadata =
      if function_exported?(module, :get_metadata, 0),
        do: module.get_metadata(),
        else: %{}

    plugin = %Raxol.Plugins.Plugin{
      name: plugin_name,
      version: Map.get(metadata, :version, "1.0.0"),
      description: Map.get(metadata, :description, "Plugin for #{module}"),
      enabled: true,
      config: config,
      dependencies: Map.get(metadata, :dependencies, []),
      api_version: module.get_api_version(),
      module: module,
      state: nil
    }

    case Initialization.validate_plugin_compatibility(plugin, module) do
      :ok -> {:ok, plugin}
      error -> error
    end
  end

  defp call_stateful_hook(plugin_name, hook) do
    case PluginRuntime.invoke(plugin_name, hook) do
      {:error, :callback_not_supported} -> :ok
      {:error, reason} -> {:error, reason}
      _result -> :ok
    end
  end

  defp format_load_error({:missing_dependencies, missing, chain}, module) do
    ErrorHandling.format_missing_dependencies_error(missing, chain, module)
  end

  defp format_load_error({:version_mismatch, mismatches, chain}, module) do
    ErrorHandling.format_version_mismatch_error(mismatches, chain, module)
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
    load_order =
      Enum.map(sorted_plugin_names, &Dependencies.normalize_plugin_key/1)

    %{manager | load_order: load_order}
  end

  defp initialize_all_plugins_with_configs(manager, module_configs) do
    Enum.reduce_while(module_configs, {:ok, []}, fn {module, config},
                                                    {:ok, acc_plugins} ->
      plugin_name = Initialization.get_plugin_id_from_metadata(module)

      with {:ok, merged_config} <-
             Initialization.get_and_validate_config(
               manager,
               plugin_name,
               module,
               config
             ),
           {:ok, plugin} <-
             build_plugin_descriptor(plugin_name, module, merged_config) do
        {:cont, {:ok, [plugin | acc_plugins]}}
      else
        {:error, reason} -> {:halt, {:error, :init_failed, module, reason}}
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
        with :ok <- call_stateful_hook(plugin_key, :on_unload),
             :ok <- call_cleanup(plugin_key),
             :ok <- RuntimeLifecycle.unload(plugin_key),
             {:ok, updated_manager} <-
               update_config_and_remove_plugin(manager, plugin, name) do
          {:ok, updated_manager}
        else
          {:error, reason} ->
            {:error, "Failed to cleanup plugin #{name}: #{inspect(reason)}"}
        end
    end
  end

  defp call_cleanup(plugin_name) do
    case PluginRuntime.invoke(plugin_name, :cleanup) do
      :ok -> :ok
      {:error, :callback_not_supported} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_cleanup_return, other}}
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
             config: saved_config
         }}

      {:error, reason} ->
        ErrorHandling.log_config_save_error(name, reason)

        {:ok,
         %{
           manager
           | plugins: Map.delete(manager.plugins, plugin_key),
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
         :ok <- RuntimeLifecycle.enable(name),
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
    with {:ok, plugin} <- get_plugin(manager, name),
         :ok <- RuntimeLifecycle.disable(name),
         {:ok, updated_config} <-
           ManagerUpdate.update_and_save_config(manager, name, :disable) do
      {:ok,
       ManagerUpdate.update_manager_state(
         manager,
         plugin,
         updated_config,
         false
       )}
    else
      {:error, _reason} -> {:error, "Plugin #{name} not found"}
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
    plugin_name = normalize_plugin_name(plugin_name)

    case Enum.find(initialized_plugins, &(&1.name == plugin_name)) do
      nil ->
        {:halt,
         {:error, :load_failed, plugin_name, "Not found in initialized list"}}

      plugin ->
        case load_plugin(acc_manager, plugin.module, plugin.config) do
          {:ok, manager} -> {:cont, {:ok, manager}}
          error -> {:halt, error}
        end
    end
  end

  defp normalize_plugin_name(plugin_name) when is_atom(plugin_name),
    do: Atom.to_string(plugin_name)

  defp normalize_plugin_name(plugin_name), do: plugin_name
end
