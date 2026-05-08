defmodule Raxol.Core.KeyboardShortcuts do
  @moduledoc """
  Refactored KeyboardShortcuts that delegates to GenServer implementation.

  This module provides the same API as the original KeyboardShortcuts but uses
  a supervised GenServer instead of the Process dictionary for state management.

  ## Migration Notice
  This module is a drop-in replacement for `Raxol.Core.KeyboardShortcuts`.
  All functions maintain backward compatibility while providing improved
  fault tolerance and functional programming patterns.

  ## Benefits over Process Dictionary
  - Supervised state management with fault tolerance
  - Pure functional shortcut resolution
  - Priority-based conflict resolution
  - Context-aware shortcut activation
  - Better debugging and testing capabilities
  - No global state pollution
  """

  # Removed non-existent @behaviour reference

  alias Raxol.Core.Events.EventManager, as: EventManager
  alias Raxol.Core.KeyboardShortcuts.ShortcutsServer, as: Server
  alias Raxol.Core.Runtime.Log

  @doc """
  Ensures the Keyboard Shortcuts server is started.
  """
  def ensure_started do
    case Server.start_link(name: Server) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Initialize the keyboard shortcuts manager.

  This function sets up the necessary state for managing keyboard shortcuts
  and registers event handlers for keyboard events.
  """
  def init do
    ensure_started()
    Server.init_shortcuts(Server)

    # Register this module's handler with EventManager
    EventManager.register_handler(
      :keyboard_event,
      __MODULE__,
      :handle_keyboard_event
    )

    :ok
  end

  @doc """
  Clean up the keyboard shortcuts manager.

  This function cleans up any resources used by the keyboard shortcuts manager
  and unregisters event handlers.
  """
  def cleanup do
    # Unregister event handler
    EventManager.unregister_handler(
      :keyboard_event,
      __MODULE__,
      :handle_keyboard_event
    )

    # Stop the server if it's running
    if pid = Process.whereis(Server) do
      GenServer.stop(pid, :normal)
    end

    :ok
  end

  @doc """
  Register a keyboard shortcut with a callback function.

  ## Parameters
  - `shortcut` - The keyboard shortcut string (e.g., "Ctrl+S", "Alt+F4")
  - `name` - A unique identifier for the shortcut (atom or string)
  - `callback` - A function to be called when the shortcut is triggered
  - `opts` - Options for the shortcut

  ## Options
  - `:context` - The context in which this shortcut is active (default: `:global`)
  - `:description` - A description of what the shortcut does
  - `:priority` - Priority level (1-10, lower = higher priority)
  - `:override` - Whether to override existing shortcut (default: false)
  """
  def register_shortcut(shortcut, name, callback, opts \\ []) do
    ensure_started()

    case Server.register_shortcut(Server, shortcut, name, callback, opts) do
      :ok ->
        :ok

      {:error, :conflict} ->
        # For backward compatibility, silently override on conflict
        Server.register_shortcut(
          Server,
          shortcut,
          name,
          callback,
          Keyword.put(opts, :override, true)
        )
    end
  end

  @doc """
  Unregister a keyboard shortcut.

  ## Parameters
  - `shortcut` - The keyboard shortcut string to unregister
  - `context` - The context from which to unregister (default: `:global`)
  """
  def unregister_shortcut(shortcut, context \\ :global) do
    ensure_started()
    Server.unregister_shortcut(Server, shortcut, context)
  end

  @doc """
  Set the active context for shortcuts.

  Context-specific shortcuts will only be active when their context is set.
  """
  def set_active_context(context) do
    ensure_started()
    Server.set_active_context(Server, context)
  end

  @doc """
  Get all shortcuts for a specific context.

  Returns a map of shortcut definitions for the given context.
  """
  def get_shortcuts_for_context(context \\ nil) do
    ensure_started()
    actual_context = context || get_active_context()
    Server.get_shortcuts_for_context(Server, actual_context)
  end

  @doc """
  Show help text for available shortcuts.

  Displays formatted help text for all available shortcuts in the current context.
  """
  def show_shortcuts_help do
    ensure_started()
    help_text = Server.generate_shortcuts_help(Server)
    Log.info(help_text)
    {:ok, help_text}
  end

  @doc """
  Handle keyboard events.

  This function is called by the EventManager when keyboard events occur.
  """
  def handle_keyboard_event(event_type, event_data) do
    ensure_started()
    # Create event struct from the separate type and data parameters
    event = %Raxol.Core.Events.Event{
      type: event_type,
      data: event_data,
      timestamp: DateTime.utc_now()
    }

    Server.handle_keyboard_event(Server, event)
    :ok
  end

  # Additional helper functions

  @doc """
  Get the currently active context.
  """
  def get_active_context do
    ensure_started()
    Server.get_active_context(Server)
  end

  @doc """
  Get all available shortcuts (global + active context).
  """
  def get_available_shortcuts do
    ensure_started()
    Server.get_available_shortcuts(Server)
  end

  @doc """
  Get formatted help text for shortcuts.
  """
  def get_shortcuts_help do
    ensure_started()
    Server.generate_shortcuts_help()
  end

  @doc """
  Enable or disable shortcut processing.
  """
  def set_enabled(enabled) when is_boolean(enabled) do
    ensure_started()
    Server.set_enabled(Server, enabled)
  end

  @doc """
  Check if shortcuts are enabled.
  """
  def enabled? do
    ensure_started()
    Server.enabled?(Server)
  end

  @doc """
  Set conflict resolution strategy.

  ## Strategies
  - `:first` - Keep the first registered shortcut
  - `:last` - Keep the last registered shortcut
  - `:priority` - Use priority to resolve conflicts
  """
  def set_conflict_resolution(strategy)
      when strategy in [:first, :last, :priority] do
    ensure_started()
    Server.set_conflict_resolution(Server, strategy)
  end

  @doc """
  Clear all shortcuts.
  """
  def clear_all do
    ensure_started()
    Server.clear_all(Server)
  end

  @doc """
  Clear shortcuts for a specific context.
  """
  def clear_context(context) do
    ensure_started()
    Server.clear_context(Server, context)
  end

  @doc """
  Register a batch of shortcuts at once.

  ## Example
  ```elixir
  register_batch([
    {"Ctrl+S", :save, &save_file/0, description: "Save file"},
    {"Ctrl+O", :open, &open_file/0, description: "Open file"},
    {"Ctrl+Q", :quit, &quit_app/0, description: "Quit application"}
  ])
  ```
  """
  def register_batch(shortcuts) when is_list(shortcuts) do
    ensure_started()

    Enum.each(shortcuts, fn
      {shortcut, name, callback} ->
        register_shortcut(shortcut, name, callback)

      {shortcut, name, callback, opts} ->
        register_shortcut(shortcut, name, callback, opts)
    end)

    :ok
  end

  @doc """
  Check if a shortcut is registered.
  """
  def shortcut_registered?(shortcut, context \\ :global) do
    ensure_started()
    shortcuts = Server.get_shortcuts_for_context(Server, context)

    # Parse the shortcut to get the key
    parsed = parse_shortcut_string(shortcut)
    key = shortcut_key(parsed)

    Map.has_key?(shortcuts, key)
  end

  # Private helper functions

  defp parse_shortcut_string(shortcut) when is_binary(shortcut) do
    parts = String.split(shortcut, "+")
    {modifiers, [key]} = Enum.split(parts, -1)

    modifiers =
      Enum.map(modifiers, fn mod ->
        case String.downcase(mod) do
          "ctrl" -> :ctrl
          "control" -> :ctrl
          "alt" -> :alt
          "shift" -> :shift
          "cmd" -> :cmd
          "command" -> :cmd
          _ -> String.to_atom(String.downcase(mod))
        end
      end)

    %{
      modifiers: Enum.sort(modifiers),
      key: String.to_atom(String.downcase(key))
    }
  end

  defp shortcut_key(parsed) do
    modifiers_str = Enum.join(parsed.modifiers, "_")
    "#{modifiers_str}_#{parsed.key}"
  end
end
