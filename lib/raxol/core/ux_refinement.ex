defmodule Raxol.Core.UXRefinement do
  @moduledoc """
  Refactored UX refinement module that uses GenUxServer for state management.

  This module provides the same API as the original UXRefinement module but
  delegates all state management to a supervised GenUxServer, eliminating
  Process dictionary usage.

  ## Migration Notes

  This module maintains backward compatibility with the original API.
  The main difference is that it requires starting the UXRefinement.UxServer
  as part of your supervision tree:

      children = [
        {Raxol.Core.UXRefinement.UxServer, name: Raxol.Core.UXRefinement.UxServer}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
  """

  alias Raxol.Core.UXRefinement.UxServer

  @server Raxol.Core.UXRefinement.UxServer

  @doc """
  Initialize the UX refinement system.

  This now initializes the GenUxServer state instead of Process dictionary.
  """
  def init do
    ensure_server_started()
    UxServer.init_system(@server)
  end

  @doc """
  Enable a UX refinement feature.

  Delegates to the GenUxServer for state management.
  """
  def enable_feature(feature, opts \\ [], user_preferences_pid_or_name \\ nil) do
    ensure_server_started()

    UxServer.enable_feature(
      @server,
      feature,
      opts,
      user_preferences_pid_or_name
    )
  end

  @doc """
  Disable a previously enabled UX refinement feature.
  """
  def disable_feature(feature) do
    ensure_server_started()
    UxServer.disable_feature(@server, feature)
  end

  @doc """
  Check if a UX refinement feature is enabled.
  """
  def feature_enabled?(feature) do
    ensure_server_started()
    UxServer.feature_enabled?(@server, feature)
  end

  @doc """
  Register a hint for a component.
  """
  def register_hint(component_id, hint) when is_binary(hint) do
    ensure_server_started()
    ensure_feature_enabled(:hints, component_id)
    UxServer.register_hint(@server, component_id, hint)
  end

  @doc """
  Register comprehensive hints for a component with multiple detail levels.
  """
  def register_component_hint(component_id, hint_info) do
    ensure_server_started()
    ensure_feature_enabled(:hints, component_id)
    UxServer.register_component_hint(@server, component_id, hint_info)
  end

  @doc """
  Get the hint for a component.
  """
  def get_hint(component_id) do
    ensure_server_started()
    ensure_feature_enabled(:hints, component_id)
    UxServer.get_hint(@server, component_id)
  end

  @doc """
  Get a specific hint level for a component.
  """
  def get_component_hint(component_id, level)
      when level in [:basic, :detailed, :examples] do
    ensure_server_started()
    ensure_feature_enabled(:hints, component_id)
    UxServer.get_component_hint(@server, component_id, level)
  end

  @doc """
  Get shortcuts for a component.
  """
  def get_component_shortcuts(component_id) do
    ensure_server_started()
    ensure_feature_enabled(:hints, component_id)
    UxServer.get_component_shortcuts(@server, component_id)
  end

  @doc """
  Get accessibility metadata for a component.
  """
  def get_accessibility_metadata(component_id) do
    ensure_server_started()

    case feature_enabled?(:accessibility) do
      true ->
        UxServer.get_accessibility_metadata(@server, component_id)

      false ->
        Raxol.Core.Runtime.Log.debug(
          "[UXRefinement] Accessibility not enabled, metadata retrieval skipped for #{component_id}"
        )

        nil
    end
  end

  @doc """
  Register accessibility metadata for a component.
  """
  def register_accessibility_metadata(component_id, metadata) do
    ensure_server_started()
    UxServer.register_accessibility_metadata(@server, component_id, metadata)
  end

  @doc """
  Display help for available keyboard shortcuts.
  """
  def show_shortcuts_help(user_preferences_pid_or_name \\ nil) do
    ensure_server_started()
    ensure_feature_enabled(:keyboard_shortcuts, user_preferences_pid_or_name)

    keyboard_shortcuts_module().show_shortcuts_help(
      user_preferences_pid_or_name
    )
  end

  @doc """
  Set the active context for keyboard shortcuts.
  """
  def set_shortcuts_context(context) do
    ensure_server_started()
    ensure_feature_enabled(:keyboard_shortcuts, context)
    keyboard_shortcuts_module().set_context(context)
  end

  @doc """
  Get all available shortcuts for a given context.
  """
  def get_available_shortcuts(context \\ nil) do
    ensure_server_started()
    ensure_feature_enabled(:keyboard_shortcuts, context)
    keyboard_shortcuts_module().get_shortcuts_for_context(context)
  end

  @doc """
  Make an announcement for screen readers.
  """
  def announce(message, opts \\ [], user_preferences_pid_or_name) do
    ensure_server_started()

    case feature_enabled?(:accessibility) do
      true ->
        accessibility_module().announce(
          message,
          opts,
          user_preferences_pid_or_name
        )

      false ->
        Raxol.Core.Runtime.Log.debug(
          "[UXRefinement] Accessibility not enabled, announcement skipped: #{message}"
        )

        :ok
    end
  end

  # Private Functions

  defp ensure_server_started do
    Raxol.Core.Utils.GenServerHelpers.ensure_started(
      @server,
      fn -> GenServer.start(UxServer, [], name: @server) end
    )
  end

  defp ensure_feature_enabled(feature, context) do
    case feature_enabled?(feature) do
      false -> enable_feature(feature, [], context)
      true -> :ok
    end

    :ok
  end

  defp accessibility_module do
    Application.get_env(:raxol, :accessibility_impl, Raxol.Core.Accessibility)
  end

  defp keyboard_shortcuts_module do
    Application.get_env(
      :raxol,
      :keyboard_shortcuts_module,
      Raxol.Core.KeyboardShortcuts
    )
  end
end
