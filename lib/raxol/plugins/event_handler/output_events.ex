defmodule Raxol.Plugins.EventHandler.OutputEvents do
  @moduledoc """
  Handles output-related events for plugins.
  """


  alias Raxol.Plugins.EventHandler.Common
  alias Raxol.Plugins.Manager

  @type manager :: Manager.t()
  @type result :: {:ok, manager(), binary()} | {:error, term()}

  @doc """
  Dispatches an "output" event to all enabled plugins implementing `handle_output/2`.
  """
  @spec handle_output(Manager.t(), binary()) ::
          {:ok, Manager.t(), binary()} | {:error, term()}
  def handle_output(%Manager{} = manager, output) do
    initial_acc = %{
      manager: manager,
      output: output,
      transformed_output: output
    }

    result =
      Common.dispatch_event(
        manager,
        :handle_output,
        [output],
        2,
        initial_acc,
        &handle_output_result/4
      )

    case result do
      %{manager: updated_manager, transformed_output: transformed_output} ->
        {:ok, updated_manager, transformed_output}

      error ->
        error
    end
  end

  # Private result handlers

  defp handle_output_result(acc, plugin, _cb, {:ok, s, t})
       when is_map(s) and is_binary(t) do
    mgr = Common.update_manager_state(acc.manager, plugin, s)
    {:cont, %{acc | manager: mgr, transformed_output: t}}
  end

  defp handle_output_result(acc, plugin, _cb, {:ok, payload}) do
    handle_output_ok(acc, plugin, payload)
  end

  defp handle_output_result(acc, plugin, _cb, {:halt, payload}) do
    handle_output_halt(acc, plugin, payload)
  end

  defp handle_output_result(acc, plugin, _cb, {:error, reason}) do
    Common.log_plugin_error(plugin, :handle_output, reason)
    {:cont, acc}
  end

  defp handle_output_result(acc, plugin, _cb, other) do
    Common.log_unexpected_result(plugin, :handle_output, other)
    {:cont, acc}
  end

  defp handle_output_ok(acc, _plugin, t) when is_binary(t) do
    {:cont, %{acc | transformed_output: t}}
  end

  defp handle_output_ok(acc, plugin, {up, t}) when is_binary(t) do
    mgr = update_manager_from_plugin(acc.manager, plugin, up)
    {:cont, %{acc | manager: mgr, transformed_output: t}}
  end

  defp handle_output_ok(acc, plugin, up) do
    mgr = update_manager_from_plugin(acc.manager, plugin, up)
    {:cont, %{acc | manager: mgr}}
  end

  defp handle_output_halt(acc, _plugin, t) when is_binary(t) do
    {:halt, %{acc | transformed_output: t}}
  end

  defp handle_output_halt(acc, plugin, {up, t}) when is_binary(t) do
    mgr = update_manager_from_plugin(acc.manager, plugin, up)
    {:halt, %{acc | manager: mgr, transformed_output: t}}
  end

  defp update_manager_from_plugin(manager, plugin, updated_plugin) do
    updated_plugin_state = Common.extract_plugin_state(updated_plugin)
    Common.update_manager_state(manager, plugin, updated_plugin_state)
  end
end
