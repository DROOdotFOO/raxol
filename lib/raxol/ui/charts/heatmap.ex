defmodule Raxol.UI.Charts.Heatmap do
  @moduledoc """
  2D heatmap with background-color intensity mapping.

  Renders a grid of values as colored cells, using built-in or custom
  color scales. Each grid cell maps to one terminal character with the
  heat value encoded as the background color.
  """

  alias Raxol.UI.Charts.ChartUtils

  @type cell :: ChartUtils.cell()

  @doc """
  Renders a heatmap from a 2D grid (list of lists, row-major).

  ## Options
  - `color_scale` -- `:warm`, `:cool`, `:diverging`, or a function
    `(value, min, max) -> {fg, bg}` (default: `:warm`)
  - `show_values` -- render truncated values in cells (default: false)
  - `min` -- explicit minimum (default: `:auto`)
  - `max` -- explicit maximum (default: `:auto`)
  - `cell_char` -- character to fill cells with (default: `" "`)
  """
  @spec render(
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()},
          [[number()]],
          keyword()
        ) :: [cell()]
  def render(region, data, opts \\ [])
  def render(_region, [], _opts), do: []

  def render({x, y, w, h}, data, opts) do
    all_values = List.flatten(data)
    render_nonempty({x, y, w, h}, data, all_values, opts)
  end

  defp render_nonempty(_region, _data, [], _opts), do: []

  defp render_nonempty({x, y, w, h}, data, all_values, opts) do
    ctx = build_heatmap_context({x, y, w, h}, data, all_values, opts)

    data
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, row_idx} ->
      render_heatmap_row(row, row_idx, ctx)
    end)
  end

  defp build_heatmap_context({x, y, w, h}, data, all_values, opts) do
    {val_min, val_max} = ChartUtils.resolve_range(all_values, opts)
    num_rows = length(data)
    num_cols = data |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    %{
      x: x,
      y: y,
      cell_w: max(div(w, max(num_cols, 1)), 1),
      cell_h: max(div(h, max(num_rows, 1)), 1),
      color_scale: Keyword.get(opts, :color_scale, :warm),
      show_values: Keyword.get(opts, :show_values, false),
      cell_char: Keyword.get(opts, :cell_char, " "),
      val_min: val_min,
      val_max: val_max
    }
  end

  defp render_heatmap_row(row, row_idx, ctx) do
    row
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, col_idx} ->
      cx = ctx.x + col_idx * ctx.cell_w
      cy = ctx.y + row_idx * ctx.cell_h
      {fg, bg} = resolve_color(ctx.color_scale, value, ctx.val_min, ctx.val_max)

      cell = %{cx: cx, cy: cy, w: ctx.cell_w, h: ctx.cell_h, fg: fg, bg: bg}
      render_heatmap_cell(ctx.show_values, cell, value, ctx.cell_char)
    end)
  end

  defp render_heatmap_cell(true, cell, value, _cell_char) do
    label =
      ChartUtils.format_number(value)
      |> String.slice(0, cell.w)
      |> String.pad_trailing(cell.w)

    render_heat_cell_with_text(
      cell.cx,
      cell.cy,
      cell.w,
      cell.h,
      label,
      cell.fg,
      cell.bg
    )
  end

  defp render_heatmap_cell(false, cell, _value, cell_char) do
    render_heat_cell(
      cell.cx,
      cell.cy,
      cell.w,
      cell.h,
      cell_char,
      cell.fg,
      cell.bg
    )
  end

  # -- Built-in color scales --

  @doc """
  Maps a normalized value (0.0-1.0) to a warm-scale color.
  Green -> Yellow -> Red.
  """
  @spec warm_scale(float()) :: atom()
  def warm_scale(t) when t < 0.25, do: :green
  def warm_scale(t) when t < 0.5, do: :yellow
  def warm_scale(t) when t < 0.75, do: :red
  def warm_scale(_t), do: :red

  @doc """
  Maps a normalized value (0.0-1.0) to a cool-scale color.
  Blue -> Cyan -> White.
  """
  @spec cool_scale(float()) :: atom()
  def cool_scale(t) when t < 0.33, do: :blue
  def cool_scale(t) when t < 0.66, do: :cyan
  def cool_scale(_t), do: :white

  @doc """
  Maps a normalized value (0.0-1.0) to a diverging-scale color.
  Blue -> White -> Red.
  """
  @spec diverging_scale(float()) :: atom()
  def diverging_scale(t) when t < 0.33, do: :blue
  def diverging_scale(t) when t < 0.66, do: :white
  def diverging_scale(_t), do: :red

  # -- Private --

  defp resolve_color(scale_fn, value, val_min, val_max)
       when is_function(scale_fn, 3) do
    scale_fn.(value, val_min, val_max)
  end

  defp resolve_color(scale_name, value, val_min, val_max)
       when is_atom(scale_name) do
    t = normalize_value(value, val_min, val_max)

    bg =
      case scale_name do
        :warm -> warm_scale(t)
        :cool -> cool_scale(t)
        :diverging -> diverging_scale(t)
        _ -> warm_scale(t)
      end

    # Use contrasting fg for readability
    fg = if bg in [:white, :yellow, :cyan], do: :black, else: :white
    {fg, bg}
  end

  defp normalize_value(_value, same, same), do: 0.5

  defp normalize_value(value, min, max) do
    ChartUtils.clamp((value - min) / (max - min), 0.0, 1.0)
  end

  defp render_heat_cell(cx, cy, cell_w, cell_h, cell_char, fg, bg) do
    for row <- 0..(cell_h - 1), col <- 0..(cell_w - 1) do
      {cx + col, cy + row, cell_char, fg, bg, %{}}
    end
  end

  defp render_heat_cell_with_text(cx, cy, cell_w, cell_h, label, fg, bg) do
    # First row gets the label, rest are filled
    label_cells =
      label
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.map(fn {char, offset} ->
        {cx + offset, cy, char, fg, bg, %{}}
      end)

    fill_cells =
      for row <- 1..(cell_h - 1), col <- 0..(cell_w - 1), cell_h > 1 do
        {cx + col, cy + row, " ", fg, bg, %{}}
      end

    label_cells ++ fill_cells
  end
end
