defmodule Raxol.Plugins.EventHandler.MouseEvents do
  @moduledoc """
  Handles mouse-related events for plugins.
  """

  alias Raxol.Plugins.EventHandler.Common
  alias Raxol.Plugins.Manager

  @type manager :: Manager.t()
  @type mouse_event :: map()
  @type result ::
          {:ok, manager()}
          | {:ok, manager(), :propagate | :halt}
          | {:error, term()}

  @doc """
  Dispatches a "mouse_event" to all enabled plugins implementing `handle_mouse_event/3`.
  """
  @spec handle_mouse_event(Manager.t(), mouse_event(), map()) ::
          {:ok, manager(), :propagate | :halt} | {:error, term()}
  def handle_mouse_event(%Manager{} = manager, event, rendered_cells) do
    initial_acc = %{
      manager: manager,
      event: event,
      rendered_cells: rendered_cells,
      modified_cells: rendered_cells,
      halt_requested: false
    }

    result =
      Common.dispatch_event(
        manager,
        :handle_mouse_event,
        [event, rendered_cells],
        3,
        initial_acc,
        &handle_mouse_event_result/4
      )

    case result do
      %{manager: updated_manager, halt_requested: halt_requested} ->
        propagation = if halt_requested, do: :halt, else: :propagate
        {:ok, updated_manager, propagation}

      error ->
        error
    end
  end

  @doc """
  Dispatches a "resize" event to all enabled plugins implementing `handle_resize/3`.
  """
  @spec handle_resize(Manager.t(), non_neg_integer(), non_neg_integer()) ::
          result()
  def handle_resize(%Manager{} = manager, width, height) do
    initial_acc = %{manager: manager, width: width, height: height}

    result =
      Common.dispatch_event(
        manager,
        :handle_resize,
        [width, height],
        3,
        initial_acc,
        &handle_resize_result/4
      )

    case result do
      %{manager: updated_manager} ->
        {:ok, updated_manager}

      error ->
        error
    end
  end

  # Private result handlers

  defp handle_mouse_event_result(acc, plugin, _callback_name, {:ok, result}) do
    handle_mouse_ok(acc, plugin, result)
  end

  defp handle_mouse_event_result(acc, plugin, _callback_name, {:halt, result}) do
    handle_mouse_halt(acc, plugin, result)
  end

  defp handle_mouse_event_result(acc, plugin, _callback_name, {:error, reason}) do
    Common.log_plugin_error(plugin, :handle_mouse_event, reason)
    {:cont, acc}
  end

  defp handle_mouse_event_result(acc, plugin, _callback_name, other) do
    Common.log_unexpected_result(plugin, :handle_mouse_event, other)
    {:cont, acc}
  end

  defp handle_mouse_ok(acc, _plugin, modified_cells)
       when is_map(modified_cells) do
    {:cont, %{acc | modified_cells: modified_cells}}
  end

  defp handle_mouse_ok(acc, plugin, {updated_plugin, modified_cells})
       when is_map(modified_cells) do
    updated_manager =
      update_manager_from_plugin(acc.manager, plugin, updated_plugin)

    {:cont, %{acc | manager: updated_manager, modified_cells: modified_cells}}
  end

  defp handle_mouse_ok(acc, plugin, updated_plugin) do
    updated_manager =
      update_manager_from_plugin(acc.manager, plugin, updated_plugin)

    {:cont, %{acc | manager: updated_manager}}
  end

  defp handle_mouse_halt(acc, _plugin, modified_cells)
       when is_map(modified_cells) do
    {:halt, %{acc | modified_cells: modified_cells, halt_requested: true}}
  end

  defp handle_mouse_halt(acc, plugin, {updated_plugin, modified_cells})
       when is_map(modified_cells) do
    updated_manager =
      update_manager_from_plugin(acc.manager, plugin, updated_plugin)

    {:halt,
     %{
       acc
       | manager: updated_manager,
         modified_cells: modified_cells,
         halt_requested: true
     }}
  end

  defp update_manager_from_plugin(manager, plugin, updated_plugin) do
    updated_plugin_state = Common.extract_plugin_state(updated_plugin)
    Common.update_manager_state(manager, plugin, updated_plugin_state)
  end

  defp handle_resize_result(acc, plugin, _callback_name, result) do
    case result do
      {:ok, updated_plugin} ->
        updated_plugin_state = Common.extract_plugin_state(updated_plugin)

        updated_manager =
          Common.update_manager_state(acc.manager, plugin, updated_plugin_state)

        {:cont, %{acc | manager: updated_manager}}

      {:error, reason} ->
        Common.log_plugin_error(plugin, :handle_resize, reason)
        {:cont, acc}

      other ->
        Common.log_unexpected_result(plugin, :handle_resize, other)
        {:cont, acc}
    end
  end
end
