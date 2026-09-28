defmodule Raxol.Plugins.Lifecycle.ManagerUpdate do
  @moduledoc """
  Updates root plugin metadata and persisted configuration.
  """

  alias Raxol.Plugins.Lifecycle.Dependencies
  alias Raxol.Plugins.PluginConfig

  def update_manager_with_plugin(manager, plugin, plugin_name, merged_config) do
    case save_plugin_config(manager.config, plugin_name, merged_config) do
      {:ok, saved_config} ->
        {:ok, update_manager_state(manager, plugin, saved_config)}

      {:error, _reason} ->
        # Logging should be handled by caller
        {:ok, update_manager_state(manager, plugin, manager.config)}
    end
  end

  def save_plugin_config(config, plugin_name, merged_config) do
    updated_config =
      PluginConfig.update_plugin_config(config, plugin_name, merged_config)

    PluginConfig.save(updated_config)
  end

  def update_manager_state(manager, plugin, config) do
    plugin_key = Dependencies.normalize_plugin_key(plugin.name)

    %{
      manager
      | plugins: Map.put(manager.plugins, plugin_key, plugin),
        config: config
    }
  end

  def update_manager_state(manager, plugin, config, enabled) do
    plugin_key = Dependencies.normalize_plugin_key(plugin.name)
    updated_plugin = %{plugin | enabled: enabled}

    %{
      manager
      | plugins: Map.put(manager.plugins, plugin_key, updated_plugin),
        config: config
    }
  end

  def update_and_save_config(manager, name, action) do
    updated_config =
      case action do
        :enable -> PluginConfig.enable_plugin(manager.config, name)
        :disable -> PluginConfig.disable_plugin(manager.config, name)
      end

    case PluginConfig.save(updated_config) do
      {:ok, saved_config} ->
        {:ok, saved_config}

      {:error, _reason} ->
        # Logging should be handled by caller
        {:ok, manager.config}
    end
  end
end
