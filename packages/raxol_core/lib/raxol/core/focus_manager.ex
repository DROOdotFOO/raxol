defmodule Raxol.Core.FocusManager do
  @moduledoc """
  Refactored FocusManager that delegates to GenServer implementation.

  This module provides the same API as the original FocusManager but uses
  a supervised GenServer instead of the Process dictionary for state management.

  ## Migration Notice
  This module is a drop-in replacement for `Raxol.Core.FocusManager`.
  All functions maintain backward compatibility while providing improved
  fault tolerance and functional programming patterns.

  ## Benefits over Process Dictionary
  - Supervised state management with fault tolerance
  - Pure functional transformations
  - Better debugging and testing capabilities
  - Clear separation of concerns
  - No global state pollution
  """

  @behaviour Raxol.Core.FocusManager.Behaviour

  alias Raxol.Core.FocusManager.FocusServer, as: Server

  @doc """
  Ensures the FocusManager server is started.
  Called automatically when using any function.
  """
  def ensure_started do
    case Server.start_link(name: Server) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Register a focusable component with the focus manager.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def register_focusable(component_id, tab_index, opts \\ []) do
    ensure_started()
    Server.register_focusable(Server, component_id, tab_index, opts)
  end

  @doc """
  Unregister a focusable component.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def unregister_focusable(component_id) do
    ensure_started()
    Server.unregister_focusable(Server, component_id)
  end

  @doc """
  Set the initial focus to a specific component.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def set_initial_focus(component_id) do
    ensure_started()
    Server.set_initial_focus(Server, component_id)
  end

  @doc """
  Set focus to a specific component.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def set_focus(component_id) do
    ensure_started()
    Server.set_focus(Server, component_id)
  end

  @doc """
  Move focus to the next focusable element.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def focus_next(opts \\ []) do
    ensure_started()
    Server.focus_next(Server, opts)
  end

  @doc """
  Move focus to the previous focusable element.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def focus_previous(opts \\ []) do
    ensure_started()
    Server.focus_previous(Server, opts)
  end

  @doc """
  Get the ID of the currently focused element.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def get_focused_element do
    ensure_started()
    Server.get_focused_element(Server)
  end

  @doc """
  Alias for get_focused_element/0.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def get_current_focus do
    get_focused_element()
  end

  @doc """
  Gets the focus history.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def get_focus_history do
    ensure_started()
    Server.get_focus_history(Server)
  end

  @doc """
  Get the next focusable element after the given one.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def get_next_focusable(current_focus_id) do
    ensure_started()
    Server.get_next_focusable(Server, current_focus_id)
  end

  @doc """
  Get the previous focusable element before the given one.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def get_previous_focusable(current_focus_id) do
    ensure_started()
    Server.get_previous_focusable(Server, current_focus_id)
  end

  @doc """
  Check if a component has focus.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def has_focus?(component_id) do
    ensure_started()
    Server.has_focus?(Server, component_id)
  end

  @doc """
  Return to the previously focused element.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def return_to_previous do
    ensure_started()
    Server.return_to_previous(Server)
  end

  @doc """
  Enable a previously disabled focusable component.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def enable_component(component_id) do
    ensure_started()
    Server.enable_component(Server, component_id)
  end

  @doc """
  Disable a focusable component, preventing it from receiving focus.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def disable_component(component_id) do
    ensure_started()
    Server.disable_component(Server, component_id)
  end

  @doc """
  Register a handler function to be called when focus changes.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def register_focus_change_handler(handler_fun)
      when is_function(handler_fun, 2) do
    ensure_started()
    Server.register_focus_change_handler(Server, handler_fun)
  end

  @doc """
  Unregister a focus change handler function.
  """
  @impl Raxol.Core.FocusManager.Behaviour
  def unregister_focus_change_handler(handler_fun)
      when is_function(handler_fun, 2) do
    ensure_started()
    Server.unregister_focus_change_handler(Server, handler_fun)
  end
end
