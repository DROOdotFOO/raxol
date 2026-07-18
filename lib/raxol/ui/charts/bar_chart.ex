defmodule Raxol.UI.Charts.BarChart do
  @moduledoc """
  Block-character bar chart with sub-character precision.

  Uses `█▇▆▅▄▃▂▁` for 8 levels of fill per character height, giving
  smooth bar rendering. Supports vertical and horizontal orientation,
  grouped multi-series, and optional value labels.
  """

  alias Raxol.UI.Charts.ChartUtils

  @compile {:no_warn_undefined, Raxol.MCP.ToolProvider}
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider

  @type cell :: ChartUtils.cell()

  @type series :: %{
          name: String.t(),
          data: list() | struct(),
          color: atom()
        }

  @block_chars ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

  @doc """
  Renders a bar chart into cell tuples.

  ## Options
  - `orientation` -- `:vertical` or `:horizontal` (default: `:vertical`)
  - `show_axes` -- render axis labels (default: false)
  - `show_legend` -- render series legend (default: false)
  - `show_values` -- render value labels above bars (default: false)
  - `bar_gap` -- gap between bars in a group (default: 0)
  - `group_gap` -- gap between groups (default: 1)
  - `min` -- Y-axis minimum (default: `:auto`)
  - `max` -- Y-axis maximum (default: `:auto`)
  """
  @spec render(
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()},
          [series()],
          keyword()
        ) :: [cell()]
  def render(region, series, opts \\ []) do
    config = parse_opts(opts)
    normalized = normalize_series(series)

    {val_min, val_max} =
      resolve_range(Enum.flat_map(normalized, & &1.data), opts)

    case config.orientation do
      :vertical ->
        render_vertical_chart(region, normalized, val_min, val_max, config)

      :horizontal ->
        render_horizontal_chart(region, normalized, val_min, val_max, config)
    end
  end

  # -- Private --

  defp parse_opts(opts) do
    show_axes = Keyword.get(opts, :show_axes, false)
    show_legend = Keyword.get(opts, :show_legend, false)
    show_values = Keyword.get(opts, :show_values, false)

    %{
      orientation: Keyword.get(opts, :orientation, :vertical),
      show_axes: show_axes,
      show_legend: show_legend,
      show_values: show_values,
      bar_gap: Keyword.get(opts, :bar_gap, 0),
      group_gap: Keyword.get(opts, :group_gap, 1),
      axes_space: if(show_axes, do: 7, else: 0),
      legend_space: if(show_legend, do: 1, else: 0),
      value_space: if(show_values, do: 1, else: 0)
    }
  end

  defp normalize_series(series) do
    Enum.map(series, fn s ->
      %{s | data: ChartUtils.normalize_data(s.data)}
    end)
  end

  defp render_vertical_chart({x, y, w, h}, normalized, val_min, val_max, config) do
    plot_w = max(w - config.axes_space, 1)
    plot_h = max(h - config.legend_space - config.value_space, 1)
    plot_x = x + config.axes_space
    plot_y = y + config.value_space

    bar_cells =
      render_vertical(
        normalized,
        {plot_x, plot_y, plot_w, plot_h},
        val_min,
        val_max,
        config.bar_gap,
        config.group_gap,
        config.show_values
      )

    axes_cells =
      if config.show_axes,
        do:
          ChartUtils.render_axes(
            {x, y + config.value_space, config.axes_space, plot_h},
            {val_min, val_max}
          ),
        else: []

    legend_cells =
      if config.show_legend,
        do:
          ChartUtils.render_legend(
            x,
            y + config.value_space + plot_h,
            normalized
          ),
        else: []

    axes_cells ++ bar_cells ++ legend_cells
  end

  defp render_horizontal_chart(
         {x, y, w, h},
         normalized,
         val_min,
         val_max,
         config
       ) do
    plot_w = max(w - config.axes_space, 1)
    plot_h = max(h - config.legend_space, 1)
    plot_x = x + config.axes_space
    plot_y = y

    bar_cells =
      render_horizontal(
        normalized,
        {plot_x, plot_y, plot_w, plot_h},
        val_min,
        val_max,
        config.bar_gap,
        config.group_gap,
        config.show_values
      )

    legend_cells =
      if config.show_legend,
        do: ChartUtils.render_legend(x, y + plot_h, normalized),
        else: []

    bar_cells ++ legend_cells
  end

  # Bars should include 0 in the range (unlike line/scatter charts)
  defp resolve_range(values, opts) do
    {range_min, range_max} = ChartUtils.resolve_range(values, opts)
    {min(0, range_min), max(0, range_max)}
  end

  defp render_vertical(
         [],
         _region,
         _val_min,
         _val_max,
         _bar_gap,
         _group_gap,
         _show_values
       ),
       do: []

  defp render_vertical(
         series_list,
         region,
         val_min,
         val_max,
         bar_gap,
         group_gap,
         show_values
       ) do
    num_series = length(series_list)

    num_groups =
      series_list
      |> Enum.map(fn s -> length(s.data) end)
      |> Enum.max(fn -> 0 end)

    if num_groups == 0 do
      []
    else
      layout =
        vertical_layout(num_series, num_groups, bar_gap, group_gap, region)

      series_list
      |> Enum.with_index()
      |> Enum.flat_map(fn {%{data: data, color: color}, s_idx} ->
        render_vertical_series(
          data,
          layout,
          s_idx,
          color,
          val_min,
          val_max,
          show_values
        )
      end)
    end
  end

  defp render_vertical_series(
         data,
         layout,
         s_idx,
         color,
         val_min,
         val_max,
         show_values
       ) do
    data
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, g_idx} ->
      render_single_vertical_bar(
        layout,
        value,
        g_idx,
        s_idx,
        color,
        val_min,
        val_max,
        show_values
      )
    end)
  end

  defp vertical_layout(
         num_series,
         num_groups,
         bar_gap,
         group_gap,
         {px, py, pw, ph}
       ) do
    group_width = bars_per_group_width(num_series, bar_gap, group_gap)
    total_width = num_groups * group_width - group_gap
    scale = if total_width > 0, do: pw / total_width, else: 1

    %{
      px: px,
      py: py,
      ph: ph,
      group_width: group_width,
      scale: scale,
      bar_gap: bar_gap
    }
  end

  defp render_single_vertical_bar(
         layout,
         value,
         g_idx,
         s_idx,
         color,
         val_min,
         val_max,
         show_values
       ) do
    bar_x =
      layout.px +
        round(
          (g_idx * layout.group_width + s_idx * (1 + layout.bar_gap)) *
            layout.scale
        )

    bar_w = max(round(layout.scale), 1)

    normalized =
      ChartUtils.scale_value(value, val_min, val_max, 0, layout.ph * 8)

    sub_height =
      round(normalized) |> ChartUtils.clamp(0, layout.ph * 8) |> trunc()

    full_blocks = div(sub_height, 8)
    remainder = rem(sub_height, 8)

    bar_cells =
      render_vertical_bar_cells(
        bar_x,
        layout.py,
        bar_w,
        layout.ph,
        full_blocks,
        remainder,
        color
      )

    value_cells =
      vertical_value_label(
        show_values,
        %{
          bar_x: bar_x,
          py: layout.py,
          ph: layout.ph,
          bar_w: bar_w,
          full_blocks: full_blocks,
          remainder: remainder
        },
        value,
        color
      )

    bar_cells ++ value_cells
  end

  defp vertical_value_label(false, _geom, _val, _color), do: []

  defp vertical_value_label(true, geom, value, color) do
    partial_offset = if geom.remainder > 0, do: 1, else: 0
    label_y = geom.py + geom.ph - geom.full_blocks - partial_offset - 1

    if label_y >= geom.py do
      label = ChartUtils.format_number(value)

      ChartUtils.string_to_cells(
        String.slice(label, 0, geom.bar_w),
        geom.bar_x,
        label_y,
        color,
        :default
      )
    else
      []
    end
  end

  defp render_horizontal(
         [],
         _region,
         _val_min,
         _val_max,
         _bar_gap,
         _group_gap,
         _show_values
       ),
       do: []

  defp render_horizontal(
         series_list,
         region,
         val_min,
         val_max,
         bar_gap,
         group_gap,
         show_values
       ) do
    num_series = length(series_list)

    num_groups =
      series_list
      |> Enum.map(fn s -> length(s.data) end)
      |> Enum.max(fn -> 0 end)

    if num_groups == 0 do
      []
    else
      layout =
        horizontal_layout(num_series, num_groups, bar_gap, group_gap, region)

      series_list
      |> Enum.with_index()
      |> Enum.flat_map(fn {%{data: data, color: color}, s_idx} ->
        render_horizontal_series(
          data,
          layout,
          s_idx,
          color,
          val_min,
          val_max,
          show_values
        )
      end)
    end
  end

  defp render_horizontal_series(
         data,
         layout,
         s_idx,
         color,
         val_min,
         val_max,
         show_values
       ) do
    data
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, g_idx} ->
      render_single_horizontal_bar(
        layout,
        value,
        g_idx,
        s_idx,
        color,
        val_min,
        val_max,
        show_values
      )
    end)
  end

  defp horizontal_layout(
         num_series,
         num_groups,
         bar_gap,
         group_gap,
         {px, py, pw, ph}
       ) do
    group_height = bars_per_group_width(num_series, bar_gap, group_gap)
    total_height = num_groups * group_height - group_gap
    scale = if total_height > 0, do: ph / total_height, else: 1

    %{
      px: px,
      py: py,
      pw: pw,
      group_height: group_height,
      scale: scale,
      bar_gap: bar_gap
    }
  end

  defp render_single_horizontal_bar(
         layout,
         value,
         g_idx,
         s_idx,
         color,
         val_min,
         val_max,
         show_values
       ) do
    bar_y =
      layout.py +
        round(
          (g_idx * layout.group_height + s_idx * (1 + layout.bar_gap)) *
            layout.scale
        )

    bar_h = max(round(layout.scale), 1)

    normalized = ChartUtils.scale_value(value, val_min, val_max, 0, layout.pw)
    bar_len = round(normalized) |> ChartUtils.clamp(0, layout.pw) |> trunc()

    bar_cells =
      for col <- 0..(bar_len - 1), row <- 0..(bar_h - 1), bar_len > 0 do
        {layout.px + col, bar_y + row, "█", color, :default, %{}}
      end

    value_cells =
      horizontal_value_label(
        show_values,
        layout.px,
        bar_y,
        layout.pw,
        bar_len,
        value,
        color
      )

    bar_cells ++ value_cells
  end

  defp horizontal_value_label(false, _px, _by, _pw, _bl, _val, _color), do: []

  defp horizontal_value_label(true, _px, _by, pw, bar_len, _val, _color)
       when bar_len >= pw, do: []

  defp horizontal_value_label(true, px, bar_y, pw, bar_len, value, color) do
    label = " #{ChartUtils.format_number(value)}"

    ChartUtils.string_to_cells(
      String.slice(label, 0, pw - bar_len),
      px + bar_len,
      bar_y,
      color,
      :default
    )
  end

  defp render_vertical_bar_cells(
         bar_x,
         region_y,
         bar_w,
         region_h,
         full_blocks,
         remainder,
         color
       ) do
    # Full blocks from bottom
    full_cells =
      for row <- 0..(full_blocks - 1), col <- 0..(bar_w - 1), full_blocks > 0 do
        {bar_x + col, region_y + region_h - 1 - row, "█", color, :default, %{}}
      end

    # Partial block
    partial_cells =
      if remainder > 0 do
        char = Enum.at(@block_chars, remainder - 1)
        partial_y = region_y + region_h - 1 - full_blocks

        for col <- 0..(bar_w - 1) do
          {bar_x + col, partial_y, char, color, :default, %{}}
        end
      else
        []
      end

    full_cells ++ partial_cells
  end

  defp bars_per_group_width(num_series, bar_gap, group_gap) do
    num_series + (num_series - 1) * bar_gap + group_gap
  end

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(state) do
    id = state[:id] || "bar_chart"

    [
      %{
        name: "get_data",
        description: "Get current data series for bar chart '#{id}'",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_range",
        description: "Get axis min/max range for bar chart '#{id}'",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("get_data", _args, context) do
    series = context.widget_state[:series] || []
    {:ok, ChartUtils.summarize_series(series)}
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("get_range", _args, context) do
    series = context.widget_state[:series] || []
    chart_opts = context.widget_state[:chart_opts] || []

    all_values =
      series
      |> Enum.flat_map(fn s -> ChartUtils.normalize_data(s[:data] || []) end)

    {range_min, range_max} = ChartUtils.resolve_range(all_values, chart_opts)
    # Bar charts include 0 in range
    {:ok, %{min: min(0, range_min), max: max(0, range_max)}}
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  @impl Raxol.Core.Accessibility.Provider
  def a11y_node(node), do: ChartUtils.a11y_node(node, "bar chart")
end
