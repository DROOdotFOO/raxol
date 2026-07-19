defmodule Raxol.UI.Components.Input.MultiLineInput.RenderHelper do
  @moduledoc """
  Rendering helper functions for MultiLineInput component.

  Emits modern element maps (`%{type: :text, content: ..., style: ...}`) so the
  prepare/layout pipeline accepts them. Each line is a single `:view` node whose
  children are the styled text segments for that line (cursor / selection splits).
  """

  alias Raxol.UI.Components.Input.MultiLineInput
  alias Raxol.UI.Components.Input.MultiLineInput.NavigationHelper

  @doc """
  Renders a single line with proper styling for cursor and selection.

  Returns a `%{type: :row, children: [...]}` element (one row of text segments).
  `:view` stacks children at the same origin (overlay); `:row` lays them out
  left-to-right so cursor/selection splits stay on one line.
  """
  @spec render_line(integer(), String.t(), MultiLineInput.t(), map()) :: map()
  def render_line(line_index, line_content, state, theme) do
    text_style =
      get_theme_style(theme, [:components, :multi_line_input, :text_style], %{})

    cursor_style =
      get_theme_style(theme, [:components, :multi_line_input, :cursor_style], %{
        background: :red
      })

    selection_style =
      get_theme_style(
        theme,
        [:components, :multi_line_input, :selection_style],
        %{background: :blue}
      )

    {cursor_row, cursor_col} = state.cursor_pos
    has_cursor = line_index == cursor_row and state.focused

    {selection_start, selection_end} = normalize_selection(state)

    line_has_selection =
      line_in_selection?(line_index, selection_start, selection_end)

    segments =
      if line_has_selection do
        render_line_with_selection(
          line_content,
          line_index,
          state,
          text_style,
          selection_style,
          cursor_style,
          has_cursor,
          cursor_col
        )
      else
        render_line_simple(
          line_content,
          text_style,
          cursor_style,
          has_cursor,
          cursor_col
        )
      end

    # gap: 0 — Containers :row dialect defaults layout gap to 1, which would
    # insert a space between cursor/selection segments.
    %{type: :row, gap: 0, style: %{}, children: segments}
  end

  defp text_node(content, style) do
    %{type: :text, content: content, style: style || %{}}
  end

  defp render_line_simple(
         line_content,
         text_style,
         cursor_style,
         has_cursor,
         cursor_col
       ) do
    line_length = String.length(line_content)

    if has_cursor and cursor_col <= line_length do
      {before_cursor, at_and_after} = String.split_at(line_content, cursor_col)

      {cursor_char, after_cursor} =
        case at_and_after do
          "" -> {" ", ""}
          rest -> String.split_at(rest, 1)
        end

      [
        if(before_cursor != "", do: text_node(before_cursor, text_style)),
        text_node(cursor_char, cursor_style),
        if(after_cursor != "", do: text_node(after_cursor, text_style))
      ]
      |> Enum.reject(&is_nil/1)
    else
      if line_content != "" do
        [text_node(line_content, text_style)]
      else
        [text_node(" ", text_style)]
      end
    end
  end

  defp render_line_with_selection(
         line_content,
         line_index,
         state,
         text_style,
         selection_style,
         cursor_style,
         has_cursor,
         cursor_col
       ) do
    {selection_start, selection_end} = normalize_selection(state)
    {start_row, start_col} = selection_start
    {end_row, end_col} = selection_end

    line_length = String.length(line_content)

    sel_start = if line_index == start_row, do: start_col, else: 0
    sel_end = if line_index == end_row, do: end_col, else: line_length

    sel_start = Raxol.Core.Utils.Math.clamp(sel_start, 0, line_length)
    sel_end = Raxol.Core.Utils.Math.clamp(sel_end, sel_start, line_length)

    parts = []

    parts =
      if sel_start > 0 do
        before_sel = String.slice(line_content, 0, sel_start)
        [text_node(before_sel, text_style) | parts]
      else
        parts
      end

    parts =
      if sel_end > sel_start do
        selected_text =
          String.slice(line_content, sel_start, sel_end - sel_start)

        [text_node(selected_text, selection_style) | parts]
      else
        parts
      end

    parts =
      if sel_end < line_length do
        after_sel = String.slice(line_content, sel_end, line_length - sel_end)
        [text_node(after_sel, text_style) | parts]
      else
        parts
      end

    parts =
      if has_cursor do
        add_cursor_to_parts_reversed(parts, cursor_col, cursor_style)
      else
        parts
      end

    parts_final = Enum.reverse(parts)

    if parts_final == [] do
      [text_node(" ", text_style)]
    else
      parts_final
    end
  end

  defp add_cursor_to_parts_reversed(parts, _cursor_col, cursor_style) do
    # Simplified: prepend a cursor glyph (parts are reverse-order here).
    [text_node(" ", cursor_style) | parts]
  end

  defp normalize_selection(state),
    do: NavigationHelper.normalize_selection(state)

  defp line_in_selection?(_line_index, nil, _), do: false
  defp line_in_selection?(_line_index, _, nil), do: false

  defp line_in_selection?(line_index, {start_row, _}, {end_row, _}) do
    line_index >= start_row and line_index <= end_row
  end

  defp get_theme_style(theme, path, default) do
    case get_in(theme, path) do
      nil -> default
      style -> style
    end
  end
end
