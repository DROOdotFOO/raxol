defmodule Raxol.Plugins.Lifecycle.Initialization do
  @moduledoc """
  Builds root plugin metadata and configuration before the canonical runtime
  initializes callback state.
  """

  alias Raxol.Plugins.PluginConfig
  alias Raxol.Plugins.PluginDependency

  def get_and_validate_config(manager, plugin_name, module, config) do
    merged_config = get_merged_config(manager, plugin_name, module, config)
    validate_config_structure(merged_config)
  end

  def validate_config_structure(config) when is_map(config), do: {:ok, config}
  def validate_config_structure(_config), do: {:error, :invalid_config}

  def validate_plugin_compatibility(plugin, module) do
    PluginDependency.check_api_compatibility(
      plugin.api_version,
      module.get_api_version()
    )
  end

  def get_plugin_id_from_metadata(module) do
    _ = Code.ensure_loaded(module)

    if function_exported?(module, :get_metadata, 0) do
      case module.get_metadata() do
        %{name: name} when is_binary(name) -> name
        %{id: id} when is_atom(id) -> Atom.to_string(id)
        _metadata -> get_plugin_name(module)
      end
    else
      get_plugin_name(module)
    end
  end

  defp get_merged_config(manager, plugin_name, module, config) do
    default_config = get_default_config(module)

    persisted_config =
      PluginConfig.get_plugin_config(manager.config, plugin_name)

    default_config
    |> Map.merge(persisted_config)
    |> Map.merge(config)
  end

  defp get_default_config(module) do
    if function_exported?(module, :get_metadata, 0) do
      case module.get_metadata() do
        %{default_config: default_config} when is_map(default_config) ->
          default_config

        _metadata ->
          %{}
      end
    else
      %{}
    end
  end

  defp get_plugin_name(module) do
    module
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end
end
