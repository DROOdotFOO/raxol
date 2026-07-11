defmodule Raxol.UI.Charts.LineChart do
  @moduledoc """
  Braille-resolution line chart with multicolor multi-series support.

  Renders data as connected lines using Bresenham's algorithm at braille
  dot resolution (2x width, 4x height), producing cell tuples compatible
  with the HUD rendering pattern.
  """

  alias Raxol.UI.Charts.{BrailleCanvas, ChartUtils}

  @compile {:no_warn_undefined, Raxol.MCP.ToolProvider}
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider

  @type cell :: ChartUtils.cell()

  @type series :: %{
          name: String.t(),
          data: list() | struct(),
          color: atom()
        }

  @doc """
  Renders a line chart into cell tuples.

  ## Options
  - `show_axes` -- render Y-axis labels and line (default: false)
  - `show_legend` -- render series legend below chart (default: false)
  - `min` -- Y-axis minimum (default: `:auto`)
  - `max` -- Y-axis maximum (default: `:auto`)
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
    {normalized, y_min, y_max} = normalize_series(series, opts)

    chart_cells = render_chart_cells(normalized, plot, y_min, y_max)

    axes_cells =
      render_optional_axes(show_axes, x, y, plot.axes_w, plot.h, y_min, y_max)

    legend_cells =
      render_optional_legend(show_legend, x, y + plot.h, normalized)

    axes_cells ++ chart_cells ++ legend_cells
  end

  defp normalize_series(series, opts) do
    normalized =
      Enum.map(series, fn s ->
        %{s | data: ChartUtils.normalize_data(s.data)}
      end)

    all_values = Enum.flat_map(normalized, & &1.data)
    {y_min, y_max} = ChartUtils.resolve_range(all_values, opts)
    {normalized, y_min, y_max}
  end

  defp render_chart_cells(normalized, plot, y_min, y_max) do
    canvas = BrailleCanvas.new(plot.w, plot.h)
    {dot_w, dot_h} = BrailleCanvas.get_dimensions(canvas)

    canvas =
      normalized
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {%{data: data}, layer_id}, acc ->
        draw_series_line(acc, data, layer_id, y_min, y_max, dot_w, dot_h)
      end)

    color_map =
      normalized
      |> Enum.with_index()
      |> Map.new(fn {%{color: color}, idx} -> {idx, color} end)

    BrailleCanvas.to_cells_multicolor(canvas, {plot.x, plot.y}, color_map)
  end

  defp render_optional_axes(false, _x, _y, _w, _h, _y_min, _y_max), do: []

  defp render_optional_axes(true, x, y, w, h, y_min, y_max),
    do: ChartUtils.render_axes({x, y, w, h}, {y_min, y_max})

  defp render_optional_legend(false, _x, _y, _normalized), do: []

  defp render_optional_legend(true, x, y, normalized),
    do: ChartUtils.render_legend(x, y, normalized)

  # -- Private --

  defp draw_series_line(canvas, [], _layer_id, _y_min, _y_max, _dot_w, _dot_h),
    do: canvas

  defp draw_series_line(canvas, [_], _layer_id, _y_min, _y_max, _dot_w, _dot_h),
    do: canvas

  defp draw_series_line(canvas, data, layer_id, y_min, y_max, dot_w, dot_h) do
    len = length(data)

    points =
      data
      |> Enum.with_index()
      |> Enum.map(fn {value, idx} ->
        px = scale_x(idx, len, dot_w)
        py = scale_y(value, y_min, y_max, dot_h)
        {px, py}
      end)

    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(canvas, fn [{x1, y1}, {x2, y2}], acc ->
      bresenham(acc, x1, y1, x2, y2, layer_id)
    end)
  end

  defp scale_x(idx, len, dot_w) when len > 1 do
    round(idx / (len - 1) * (dot_w - 1))
    |> ChartUtils.clamp(0, dot_w - 1)
  end

  defp scale_x(_idx, _len, _dot_w), do: 0

  defp scale_y(value, y_min, y_max, dot_h) do
    # Invert Y: high values at top (low dot_y)
    scaled = ChartUtils.scale_value(value, y_min, y_max, 0, dot_h - 1)
    (dot_h - 1 - round(scaled)) |> ChartUtils.clamp(0, dot_h - 1)
  end

  # Tail-recursive Bresenham line drawing
  defp bresenham(canvas, x1, y1, x2, y2, layer_id) do
    dx = abs(x2 - x1)
    dy = -abs(y2 - y1)
    sx = if x1 < x2, do: 1, else: -1
    sy = if y1 < y2, do: 1, else: -1
    err = dx + dy

    params = %{
      x2: x2,
      y2: y2,
      sx: sx,
      sy: sy,
      dx: dx,
      dy: dy,
      layer_id: layer_id
    }

    do_bresenham(canvas, x1, y1, err, params)
  end

  defp do_bresenham(canvas, x, y, err, %{x2: x2, y2: y2} = params) do
    canvas = BrailleCanvas.put_dot(canvas, x, y, params.layer_id)

    if x == x2 and y == y2 do
      canvas
    else
      e2 = 2 * err

      {next_x, next_err} =
        if e2 >= params.dy, do: {x + params.sx, err + params.dy}, else: {x, err}

      {next_y, next_err} =
        if e2 <= params.dx,
          do: {y + params.sy, next_err + params.dx},
          else: {y, next_err}

      do_bresenham(canvas, next_x, next_y, next_err, params)
    end
  end

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(state) do
    id = state[:id] || "line_chart"

    [
      %{
        name: "get_series",
        description: "Get all series data for line chart '#{id}'",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_range",
        description: "Get Y-axis min/max range for line chart '#{id}'",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_point_at",
        description:
          "Get the value at a given X index for each series in line chart '#{id}'",
        inputSchema: %{
          type: "object",
          properties: %{
            index: %{
              type: "integer",
              description: "X-axis index (0-based) into each series"
            }
          },
          required: ["index"]
        }
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("get_series", _args, context) do
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

    {y_min, y_max} = ChartUtils.resolve_range(all_values, chart_opts)
    {:ok, %{min: y_min, max: y_max}}
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("get_point_at", %{"index" => index}, context) do
    series = context.widget_state[:series] || []

    result =
      Enum.map(series, fn s ->
        data = ChartUtils.normalize_data(s[:data] || [])
        value = Enum.at(data, index)

        %{
          name: s[:name] || "unnamed",
          index: index,
          value: value
        }
      end)

    {:ok, result}
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  @impl Raxol.Core.Accessibility.Provider
  def a11y_node(node) do
    %{
      role: :img,
      label:
        node[:aria_label] || node[:title] || a11y_chart_id(node[:id]) ||
          "line chart"
    }
  end

  defp a11y_chart_id(id) when is_binary(id), do: id

  defp a11y_chart_id(id) when is_atom(id) and not is_nil(id),
    do: Atom.to_string(id)

  defp a11y_chart_id(_id), do: nil
end
