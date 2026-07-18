defmodule Raxol.UI.Charts.ScatterChart do
  @moduledoc """
  Braille-resolution scatter plot for 2D `{x, y}` data.

  Each data point becomes a single braille dot. Multiple series are
  rendered as separate layers with independent colors. Points that
  fall outside the display range are silently clipped.
  """

  alias Raxol.UI.Charts.{BrailleCanvas, ChartUtils}

  @compile {:no_warn_undefined, Raxol.MCP.ToolProvider}
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider

  @type cell :: ChartUtils.cell()

  @type series :: %{
          name: String.t(),
          data: [{number(), number()}] | struct(),
          color: atom()
        }

  @doc """
  Renders a scatter chart into cell tuples.

  ## Options
  - `show_axes` -- render Y-axis labels and line (default: false)
  - `show_legend` -- render series legend below chart (default: false)
  - `x_range` -- `{min, max}` or `:auto` (default: `:auto`)
  - `y_range` -- `{min, max}` or `:auto` (default: `:auto`)
  """
  @spec render(
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()},
          [series()],
          keyword()
        ) :: [cell()]
  def render({x, y, w, h}, series, opts \\ []) do
    show_axes = Keyword.get(opts, :show_axes, false)
    show_legend = Keyword.get(opts, :show_legend, false)
    plot = ChartUtils.compute_plot_region(x, y, w, h, show_axes, show_legend)
    {normalized, x_range, y_range} = normalize_series(series, opts)

    chart_cells = render_scatter_cells(normalized, plot, x_range, y_range)

    axes_cells =
      render_optional_axes(show_axes, x, y, plot.axes_w, plot.h, y_range)

    legend_cells =
      ChartUtils.render_optional_legend(show_legend, x, y + plot.h, normalized)

    axes_cells ++ chart_cells ++ legend_cells
  end

  defp normalize_series(series, opts) do
    normalized =
      Enum.map(series, fn s ->
        %{s | data: ChartUtils.normalize_data_2d(s.data)}
      end)

    all_points = Enum.flat_map(normalized, & &1.data)
    {x_range, y_range} = resolve_ranges(all_points, opts)
    {normalized, x_range, y_range}
  end

  defp render_scatter_cells(normalized, plot, x_range, y_range) do
    canvas = BrailleCanvas.new(plot.w, plot.h)
    {dot_w, dot_h} = BrailleCanvas.get_dimensions(canvas)

    canvas =
      normalized
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {%{data: data}, layer_id}, acc ->
        place_dots(acc, data, layer_id, x_range, y_range, dot_w, dot_h)
      end)

    color_map =
      normalized
      |> Enum.with_index()
      |> Map.new(fn {%{color: color}, idx} -> {idx, color} end)

    BrailleCanvas.to_cells_multicolor(canvas, {plot.x, plot.y}, color_map)
  end

  defp render_optional_axes(false, _x, _y, _w, _h, _y_range), do: []

  defp render_optional_axes(true, x, y, w, h, y_range),
    do: ChartUtils.render_axes({x, y, w, h}, y_range)

  # -- Private --

  defp resolve_ranges([], opts) do
    {
      resolve_or_auto(Keyword.get(opts, :x_range, :auto), {0.0, 1.0}),
      resolve_or_auto(Keyword.get(opts, :y_range, :auto), {0.0, 1.0})
    }
  end

  defp resolve_ranges(points, opts) do
    {auto_x, auto_y} = ChartUtils.auto_range_2d(points)

    {
      resolve_or_auto(Keyword.get(opts, :x_range, :auto), auto_x),
      resolve_or_auto(Keyword.get(opts, :y_range, :auto), auto_y)
    }
  end

  defp resolve_or_auto(:auto, computed), do: computed
  defp resolve_or_auto(explicit, _computed), do: explicit

  defp place_dots(
         canvas,
         data,
         layer_id,
         {x_min, x_max},
         {y_min, y_max},
         dot_w,
         dot_h
       ) do
    Enum.reduce(data, canvas, fn {px, py}, acc ->
      dx =
        ChartUtils.scale_value(px, x_min, x_max, 0, dot_w - 1)
        |> round()
        |> ChartUtils.clamp(0, dot_w - 1)

      # Invert Y: high values at top
      dy =
        ChartUtils.scale_value(py, y_min, y_max, 0, dot_h - 1)
        |> round()
        |> ChartUtils.clamp(0, dot_h - 1)
        |> then(&(dot_h - 1 - &1))

      BrailleCanvas.put_dot(acc, dx, dy, layer_id)
    end)
  end

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(state) do
    id = state[:id] || "scatter_chart"

    [
      %{
        name: "get_points",
        description: "Get all data points for scatter chart '#{id}'",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_range",
        description: "Get X and Y axis ranges for scatter chart '#{id}'",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_cluster_info",
        description:
          "Get point density summary (count, centroid, spread) per series in scatter chart '#{id}'",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("get_points", _args, context) do
    series = context.widget_state[:series] || []
    {:ok, ChartUtils.summarize_series_2d(series)}
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("get_range", _args, context) do
    series = context.widget_state[:series] || []
    chart_opts = context.widget_state[:chart_opts] || []

    all_points =
      series
      |> Enum.flat_map(fn s -> ChartUtils.normalize_data_2d(s[:data] || []) end)

    {x_range, y_range} = resolve_ranges(all_points, chart_opts)

    {:ok,
     %{
       x: %{min: elem(x_range, 0), max: elem(x_range, 1)},
       y: %{min: elem(y_range, 0), max: elem(y_range, 1)}
     }}
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("get_cluster_info", _args, context) do
    series = context.widget_state[:series] || []
    result = Enum.map(series, &series_cluster_stats/1)
    {:ok, result}
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  @impl Raxol.Core.Accessibility.Provider
  def a11y_node(node), do: ChartUtils.a11y_node(node, "scatter chart")

  defp series_cluster_stats(s) do
    points = ChartUtils.normalize_data_2d(s[:data] || [])
    name = s[:name] || "unnamed"
    count = length(points)

    if count == 0 do
      %{name: name, count: 0, centroid: nil, spread: nil}
    else
      {cx, cy, std_x, std_y} = compute_centroid_and_spread(points, count)

      %{
        name: name,
        count: count,
        centroid: %{x: Float.round(cx, 4), y: Float.round(cy, 4)},
        spread: %{x: Float.round(std_x, 4), y: Float.round(std_y, 4)}
      }
    end
  end

  defp compute_centroid_and_spread(points, count) do
    {cx, cy} = centroid(points, count)
    {std_x, std_y} = std_deviation(points, cx, cy, count)
    {cx, cy, std_x, std_y}
  end

  defp centroid(points, count) do
    {sum_x, sum_y} =
      Enum.reduce(points, {0.0, 0.0}, fn {px, py}, {ax, ay} ->
        {ax + px, ay + py}
      end)

    {sum_x / count, sum_y / count}
  end

  defp std_deviation(points, cx, cy, count) do
    {var_x, var_y} =
      Enum.reduce(points, {0.0, 0.0}, fn {px, py}, {sx, sy} ->
        {sx + (px - cx) * (px - cx), sy + (py - cy) * (py - cy)}
      end)

    {:math.sqrt(var_x / count), :math.sqrt(var_y / count)}
  end
end
