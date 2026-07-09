defmodule Raxol.Plugins.Lifecycle.ErrorHandling do
  @moduledoc """
  Handles error formatting, logging, and result handling for plugin lifecycle management.
  """

  def format_error(:module_not_found, module),
    do: "Module #{module} does not exist"

  def format_error(:missing_init, module),
    do: "Module #{module} does not implement init/1"

  def format_error(:missing_cleanup, module),
    do: "Module #{module} does not implement cleanup/1"

  def format_error(:invalid_config, _module),
    do: "Invalid configuration structure"

  def format_error(:init_failed, module),
    do: "Plugin initialization failed for #{module}"

  def format_error({:missing_fields, fields}, module),
    do:
      "Missing required fields: #{Enum.join(fields, ", ")} for plugin #{module}"

  def format_error({:invalid_init_return, value}, module),
    do: "Invalid init return value: #{inspect(value)} for plugin #{module}"

  def format_error({:error, reason}, module),
    do: "Failed to initialize plugin #{module}: #{inspect(reason)}"

  def format_error({:circular_dependency, name}, _module),
    do: "Dependency cycle detected involving #{name}"

  def format_missing_dependencies_error(missing, chain, module) do
    chain_str = Enum.join(chain, " -> ")

    missing_str = Enum.map_join(missing, ", ", &format_dependency/1)

    "Plugin #{module} has missing dependencies: #{missing_str}. Dependency chain: #{chain_str}"
  end

  # Helper function to format dependency tuples as strings
  defp format_dependency({name, version})
       when is_binary(name) and is_binary(version) do
    "#{name} #{version}"
  end

  defp format_dependency(dependency) when is_binary(dependency) do
    dependency
  end

  defp format_dependency(dependency) do
    inspect(dependency)
  end

  def log_plugin_init_error(module, error) do
    Raxol.Core.Runtime.Log.error(
      "Plugin initialization failed: #{inspect(error)}",
      %{module: module}
    )
  end

  def log_config_save_error(plugin_name, reason) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Failed to save config for plugin #{plugin_name}: #{inspect(reason)}. Proceeding without saved config.",
      %{}
    )
  end

  def handle_load_plugins_error({:error, :init_failed, module, reason}),
    do: {:error, "Failed to initialize plugin #{module}: #{inspect(reason)}"}

  def handle_load_plugins_error({:error, :resolve_failed, reason}),
    do: {:error, "Failed to resolve plugin dependencies: #{inspect(reason)}"}

  def handle_load_plugins_error({:error, :load_failed, name, reason}),
    do: {:error, "Failed to load plugin #{name}: #{inspect(reason)}"}

  def handle_load_plugins_error({:error, :circular_dependency, cycle, _}),
    do: {:error, "Circular dependency detected: #{Enum.join(cycle, " -> ")}"}

  def handle_load_plugins_error({:error, reason}),
    do: {:error, "Failed to load plugins: #{inspect(reason)}"}

  def handle_load_plugins_error(error),
    do: {:error, "Failed to load plugins: #{inspect(error)}"}

  def log_plugin_error(plugin, callback_name, reason) do
    Raxol.Core.Runtime.Log.error_with_stacktrace(
      "Plugin #{plugin.name} failed during #{callback_name}",
      reason,
      nil,
      %{
        plugin: plugin.name,
        callback: callback_name,
        module: __MODULE__
      }
    )
  end

  def log_unexpected_result(plugin, callback_name, result) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Plugin #{plugin.name} returned unexpected value from #{callback_name}",
      %{
        plugin: plugin.name,
        callback: callback_name,
        value: result,
        module: __MODULE__
      }
    )
  end
end
