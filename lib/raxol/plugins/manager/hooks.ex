defmodule Raxol.Plugins.Manager.Hooks do
  @moduledoc """
  Handles plugin hook execution.
  Provides functions for running various plugin hooks and collecting their results.
  """

  alias Raxol.Plugins.Manager

  @doc """
  Runs render-related hooks for all enabled plugins.
  Collects any direct output commands (e.g., escape sequences) returned by plugins.
  Returns {:ok, updated_manager, list_of_output_commands}
  """
  def run_render_hooks(%Manager{} = manager) do
    Enum.reduce(manager.plugins, {:ok, manager, []}, &run_plugin_render_hook/2)
  end

  defp run_plugin_render_hook({_name, plugin}, {:ok, acc_manager, acc_commands}) do
    handle_render_plugin_enabled(
      plugin.enabled,
      plugin,
      acc_manager,
      acc_commands
    )
  end

  # Helper functions to eliminate if statements

  defp handle_render_plugin_enabled(false, _plugin, acc_manager, acc_commands) do
    {:ok, acc_manager, acc_commands}
  end

  defp handle_render_plugin_enabled(true, plugin, acc_manager, acc_commands) do
    module = plugin.__struct__

    handle_render_function_exported(
      function_exported?(module, :handle_render, 1),
      module,
      plugin,
      acc_manager,
      acc_commands
    )
  end

  defp handle_render_function_exported(
         false,
         _module,
         _plugin,
         acc_manager,
         acc_commands
       ) do
    {:ok, acc_manager, acc_commands}
  end

  defp handle_render_function_exported(
         true,
         module,
         plugin,
         acc_manager,
         acc_commands
       ) do
    handle_render_hook(module, plugin, acc_manager, acc_commands)
  end

  defp handle_render_hook(module, plugin, acc_manager, acc_commands) do
    case module.handle_render(plugin) do
      {:ok, updated_plugin, command} when not is_nil(command) ->
        updated_manager =
          Manager.update_plugins(
            acc_manager,
            Map.put(acc_manager.plugins, plugin.name, updated_plugin)
          )

        {:ok, updated_manager, [command | acc_commands]}

      {:ok, updated_plugin} ->
        updated_manager =
          Manager.update_plugins(
            acc_manager,
            Map.put(acc_manager.plugins, plugin.name, updated_plugin)
          )

        {:ok, updated_manager, acc_commands}

      command when is_binary(command) ->
        {:ok, acc_manager, [command | acc_commands]}

      _ ->
        {:ok, acc_manager, acc_commands}
    end
  end

  @doc """
  Runs a specific hook on all enabled plugins.
  Returns {:ok, updated_manager, results} where results is a list of hook results.
  """
  def run_hook(%Manager{} = manager, hook_name, args \\ []) do
    Enum.reduce(manager.plugins, {:ok, manager, []}, fn {name, plugin}, acc ->
      run_plugin_hook({name, plugin}, acc, hook_name, args)
    end)
  end

  defp run_plugin_hook(
         {_name, plugin},
         {:ok, acc_manager, acc_results},
         hook_name,
         args
       ) do
    handle_hook_plugin_enabled(
      plugin.enabled,
      plugin,
      hook_name,
      args,
      acc_manager,
      acc_results
    )
  end

  defp handle_hook_plugin_enabled(
         false,
         _plugin,
         _hook_name,
         _args,
         acc_manager,
         acc_results
       ) do
    {:ok, acc_manager, acc_results}
  end

  defp handle_hook_plugin_enabled(
         true,
         plugin,
         hook_name,
         args,
         acc_manager,
         acc_results
       ) do
    module = plugin.__struct__

    handle_hook_function_exported(
      function_exported?(module, hook_name, length(args) + 1),
      module,
      plugin,
      hook_name,
      args,
      acc_manager,
      acc_results
    )
  end

  defp handle_hook_function_exported(
         false,
         _module,
         _plugin,
         _hook_name,
         _args,
         acc_manager,
         acc_results
       ) do
    {:ok, acc_manager, acc_results}
  end

  defp handle_hook_function_exported(
         true,
         module,
         plugin,
         hook_name,
         args,
         acc_manager,
         acc_results
       ) do
    handle_plugin_hook(
      module,
      plugin,
      hook_name,
      args,
      acc_manager,
      acc_results
    )
  end

  defp handle_plugin_hook(
         module,
         plugin,
         hook_name,
         args,
         acc_manager,
         acc_results
       ) do
    case apply(module, hook_name, [plugin | args]) do
      {:ok, updated_plugin, result} ->
        updated_manager =
          Manager.update_plugins(
            acc_manager,
            Map.put(acc_manager.plugins, plugin.name, updated_plugin)
          )

        {:ok, updated_manager, [result | acc_results]}

      {:ok, updated_plugin} ->
        updated_manager =
          Manager.update_plugins(
            acc_manager,
            Map.put(acc_manager.plugins, plugin.name, updated_plugin)
          )

        {:ok, updated_manager, acc_results}

      result ->
        {:ok, acc_manager, [result | acc_results]}
    end
  end
end
