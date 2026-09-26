defmodule Raxol.UI.StyleHelper do
  @moduledoc """
  Shared style/theme merging for UI components.

  Consolidates the repeated pattern of merging context theme, component theme,
  component-specific theme styles, and inline styles that was duplicated across
  11+ component render/2 functions.
  """

  alias Raxol.UI.Theming.Theme

  @doc """
  Merges theme and style for a component render pass.

  Precedence (lowest to highest):
    1. Context theme (from parent/app)
    2. Component-specific theme styles (via `Theme.component_style/2`)
    3. Component's inline `state.style`

  Returns the merged base style map.
  """
  @spec merge_component_styles(map(), map(), atom()) :: map()
  def merge_component_styles(state, context, component_name) do
    theme = Map.merge(context[:theme] || %{}, state[:theme] || %{})
    theme_style = Theme.component_style(theme, component_name)
    Map.merge(theme_style, state[:style] || %{})
  end

  @doc """
  Merges theme/style and applies focus styling if the component is focused.

  Combines `merge_component_styles/3` with `FocusHelper.maybe_focus_style/3`.
  """
  @spec merge_component_styles_with_focus(map(), map(), atom()) :: map()
  def merge_component_styles_with_focus(state, context, component_name) do
    base_style = merge_component_styles(state, context, component_name)
    Raxol.UI.FocusHelper.maybe_focus_style(state[:id], context, base_style)
  end

  @text_attributes [:bold, :italic, :underline, :strikethrough, :reverse, :dim]

  @doc """
  The text attributes (`:bold`, `:italic`, `:underline`, `:strikethrough`,
  `:reverse`, `:dim`) set in a merged component style, for a component that
  builds its own element style from it.
  """
  @spec text_attributes(map()) :: map()
  def text_attributes(style), do: Map.take(style, @text_attributes)
end
