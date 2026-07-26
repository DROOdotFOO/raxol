defmodule Raxol.UI.Charts.ChartUtils do
  @moduledoc """
  Shared utilities for chart rendering: scaling, range computation,
  axis/legend cell generation, and data normalization.
  """

  @type cell ::
          {non_neg_integer(), non_neg_integer(), String.t(), atom(), atom(),
           map()}

  @doc """
  Computes a display range with 5% padding on each side.
  Returns `{min, max}`. Single-value and empty inputs are handled gracefully.
  """
  @spec auto_range([number()]) :: {number(), number()}
  def auto_range([]), do: {0.0, 1.0}
  def auto_range([v]), do: {v - 1.0, v + 1.0}

  def auto_range(values) do
    min_v = Enum.min(values)
    max_v = Enum.max(values)

    if min_v == max_v do
      {min_v - 1.0, max_v + 1.0}
    else
      padding = (max_v - min_v) * 0.05
      {min_v - padding, max_v + padding}
    end
  end

  @doc """
  Computes an auto range for 2D `{x, y}` data.
  Returns `{{x_min, x_max}, {y_min, y_max}}`.
  """
  @spec auto_range_2d([{number(), number()}]) ::
          {{number(), number()}, {number(), number()}}
  def auto_range_2d([]), do: {{0.0, 1.0}, {0.0, 1.0}}

  def auto_range_2d(points) do
    {xs, ys} = Enum.unzip(points)
    {auto_range(xs), auto_range(ys)}
  end

  @doc """
  Linearly scales a value from `[min, max]` to `[new_min, new_max]`.
  Returns `new_min` when `min == max` to avoid division by zero.
  """
  @spec scale_value(number(), number(), number(), number(), number()) :: float()
  def scale_value(_value, same, same, new_min, _new_max),
    do: new_min * 1.0

  def scale_value(value, min, max, new_min, new_max) do
    (value - min) / (max - min) * (new_max - new_min) + new_min
  end

  defdelegate clamp(val, lo, hi), to: Raxol.Core.Utils.Math

  @doc """
  Normalizes a list or CircularBuffer to a plain list of numbers.
  """
  @spec normalize_data(list() | struct()) :: [number()]
  def normalize_data(data) when is_list(data), do: data
  def normalize_data(data), do: Enum.to_list(data)

  @doc """
  Summarizes series for MCP tool output: name, color, and normalized 1D data.
  """
  @spec summarize_series([map()]) :: [map()]
  def summarize_series(series) do
    Enum.map(series, fn s ->
      %{
        name: s[:name] || "unnamed",
        color: s[:color] || :default,
        data: normalize_data(s[:data] || [])
      }
    end)
  end

  @doc """
  Summarizes series for MCP tool output with 2D `{x, y}` data.
  """
  @spec summarize_series_2d([map()]) :: [map()]
  def summarize_series_2d(series) do
    Enum.map(series, fn s ->
      %{
        name: s[:name] || "unnamed",
        color: s[:color] || :default,
        data: normalize_data_2d(s[:data] || [])
      }
    end)
  end

  @doc """
  Normalizes a list or CircularBuffer of `{x, y}` tuples to a plain list.
  """
  @spec normalize_data_2d(list() | struct()) :: [{number(), number()}]
  def normalize_data_2d(data) when is_list(data), do: data
  def normalize_data_2d(data), do: Enum.to_list(data)

  @doc """
  Renders Y-axis labels and X-axis line as cell tuples.
  """
  @spec render_axes(
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()},
          {number(), number()},
          keyword()
        ) :: [cell()]
  def render_axes({x, y, _w, h}, {y_min, y_max}, opts \\ []) do
    precision = Keyword.get(opts, :precision, 1)
    label_width = Keyword.get(opts, :label_width, 6)

    max_cells = render_axis_label(y_max, precision, label_width, x, y)
    min_cells = render_axis_label(y_min, precision, label_width, x, y + h - 1)

    axis_cells =
      for row <- 0..(h - 1) do
        {x + label_width, y + row, "|", :white, :default, %{}}
      end

    max_cells ++ min_cells ++ axis_cells
  end

  defp render_axis_label(value, precision, label_width, x, y) do
    value
    |> format_axis_label(precision)
    |> String.pad_leading(label_width)
    |> string_to_cells(x, y, :white, :default)
  end

  @doc """
  Computes the plot region within a chart area, reserving space for axes and legend.
  """
  @spec compute_plot_region(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          boolean(),
          boolean()
        ) :: map()
  def compute_plot_region(x, y, w, h, show_axes, show_legend) do
    axes_width = if show_axes, do: 7, else: 0
    legend_height = if show_legend, do: 1, else: 0

    %{
      w: max(w - axes_width, 1),
      h: max(h - legend_height, 1),
      x: x + axes_width,
      y: y,
      axes_w: axes_width
    }
  end

  @doc """
  Renders a legend showing series names with their colors.
  """
  @spec render_legend(non_neg_integer(), non_neg_integer(), [map()]) :: [cell()]
  def render_legend(x, y, series) do
    series
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{name: name, color: color}, idx} ->
      offset = idx * (Raxol.UI.TextMeasure.display_width(name) + 4)
      marker = string_to_cells("* ", x + offset, y, color, :default)
      label = string_to_cells(name, x + offset + 2, y, :white, :default)
      marker ++ label
    end)
  end

  @doc """
  Renders a legend when `show?` is true, otherwise returns `[]`.
  """
  @spec render_optional_legend(
          boolean(),
          non_neg_integer(),
          non_neg_integer(),
          [map()]
        ) :: [cell()]
  def render_optional_legend(false, _x, _y, _series), do: []

  def render_optional_legend(true, x, y, series),
    do: render_legend(x, y, series)

  @doc """
  Resolves a Y-axis range from data values and opts (`:min`, `:max`).
  Falls back to `auto_range/1` for `:auto` bounds. Empty data defaults to `{0.0, 1.0}`.
  """
  @spec resolve_range([number()], keyword()) :: {number(), number()}
  def resolve_range([], opts) do
    min_v = Keyword.get(opts, :min, :auto)
    max_v = Keyword.get(opts, :max, :auto)

    case {min_v, max_v} do
      {:auto, :auto} -> {0.0, 1.0}
      {:auto, m} -> {0.0, m}
      {m, :auto} -> {m, m + 1.0}
      {mn, mx} -> {mn, mx}
    end
  end

  def resolve_range(values, opts) do
    {auto_min, auto_max} = auto_range(values)
    min_v = Keyword.get(opts, :min, :auto)
    max_v = Keyword.get(opts, :max, :auto)

    {
      if(min_v == :auto, do: auto_min, else: min_v),
      if(max_v == :auto, do: auto_max, else: max_v)
    }
  end

  @doc """
  Formats a number with 1 decimal place.
  """
  @spec format_number(number()) :: String.t()
  def format_number(value) when is_number(value) do
    :erlang.float_to_binary(value * 1.0, decimals: 1)
  end

  @doc """
  Formats a number as an axis label string with configurable precision.
  """
  @spec format_axis_label(number(), 0..253) :: String.t()
  def format_axis_label(value, precision) when is_number(value) do
    :erlang.float_to_binary(value * 1.0, decimals: precision)
  end

  @doc """
  Converts a string into a list of cell tuples placed at consecutive X positions.
  """
  @spec string_to_cells(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          atom(),
          atom()
        ) ::
          [cell()]
  def string_to_cells(string, x, y, fg, bg) do
    string
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map(fn {char, offset} ->
      {x + offset, y, char, fg, bg, %{}}
    end)
  end

  @doc """
  Resolves a chart node id to a label string: a binary as-is, a non-nil atom
  via `Atom.to_string/1`, anything else `nil`.
  """
  @spec a11y_chart_id(term()) :: String.t() | nil
  def a11y_chart_id(id) when is_binary(id), do: id

  def a11y_chart_id(id) when is_atom(id) and not is_nil(id),
    do: Atom.to_string(id)

  def a11y_chart_id(_id), do: nil

  @doc """
  Builds the accessibility node for a chart. Uses `:aria_label`, then `:title`,
  then an id-derived label, falling back to `default_label`.
  """
  @spec a11y_node(map(), String.t()) :: %{role: :img, label: String.t()}
  def a11y_node(node, default_label) do
    %{
      role: :img,
      label:
        node[:aria_label] || node[:title] || a11y_chart_id(node[:id]) ||
          default_label
    }
  end
end
