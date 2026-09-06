defmodule Raxol.Plugins.Testing.Assertions do
  @moduledoc """
  Assertion helpers for plugin testing
  """

  import ExUnit.Assertions

  # Map-based stub, not the GenServer `Raxol.Plugins.Testing.MockTerminal`; see
  # the note at the top of plugin_test_framework.ex. Previously this resolved
  # to an unnamespaced top-level `MockTerminal`.
  alias Raxol.Plugins.Testing.StubTerminal

  @doc """
  Asserts that a plugin is loaded in the terminal
  """
  def assert_plugin_loaded(terminal, plugin_name) do
    loaded_plugins = StubTerminal.get_loaded_plugins(terminal)

    unless plugin_name in loaded_plugins do
      flunk(
        "Expected plugin '#{plugin_name}' to be loaded, but got: #{inspect(loaded_plugins)}"
      )
    end

    :ok
  end

  @doc """
  Asserts that a panel is visible for a plugin
  """
  def assert_panel_visible(terminal, plugin_name) do
    visible_panels = StubTerminal.get_visible_panels(terminal)

    unless plugin_name in visible_panels do
      flunk(
        "Expected panel for '#{plugin_name}' to be visible, but got: #{inspect(visible_panels)}"
      )
    end

    :ok
  end

  @doc """
  Asserts the terminal buffer contains specific content
  """
  def assert_buffer_contains(terminal, expected_content) do
    buffer = StubTerminal.get_buffer(terminal)
    buffer_text = buffer_to_text(buffer)

    unless String.contains?(buffer_text, expected_content) do
      flunk(
        "Expected buffer to contain '#{expected_content}', but got: #{buffer_text}"
      )
    end

    :ok
  end

  @doc """
  Asserts status line contains specific content
  """
  def assert_status_line_contains(terminal, expected_content) do
    status_line = StubTerminal.get_status_line(terminal)

    unless String.contains?(status_line, expected_content) do
      flunk(
        "Expected status line to contain '#{expected_content}', but got: #{status_line}"
      )
    end

    :ok
  end

  # Helper to convert buffer to text
  defp buffer_to_text(buffer) when is_map(buffer) do
    buffer
    |> Map.values()
    |> Enum.join("\n")
  end

  defp buffer_to_text(buffer), do: to_string(buffer)
end
