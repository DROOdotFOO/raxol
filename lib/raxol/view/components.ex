defmodule Raxol.View.Components do
  @moduledoc """
  Basic view components for Raxol UI rendering.

  This module provides fundamental components for building terminal UIs,
  including text, boxes, rows, columns, and other layout elements.
  """

  # Charts module may compile after this one
  @compile {:no_warn_undefined, Raxol.UI.Charts.ViewBridge}
  @compile {:no_warn_undefined, Raxol.UI.Charts.LineChart}
  @compile {:no_warn_undefined, Raxol.UI.Charts.BarChart}
  @compile {:no_warn_undefined, Raxol.UI.Charts.ScatterChart}
  @compile {:no_warn_undefined, Raxol.UI.Charts.Heatmap}

  @doc """
  Creates a text component with the given content.

  ## Options
  - `:content` - The text content to display
  - `:style` - Optional style attributes
  - `:id` - Optional component identifier
  """
  @spec text(keyword() | map()) :: map()
  def text(opts) when is_list(opts) do
    text(Map.new(opts))
  end

  def text(%{content: content} = opts) do
    %{
      type: :text,
      content: content,
      fg: Map.get(opts, :fg),
      bg: Map.get(opts, :bg),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id)
    }
  end

  def text(_opts) do
    %{
      type: :text,
      content: "",
      style: %{}
    }
  end

  @doc """
  Creates a box component.
  """
  @spec box(keyword() | map()) :: map()
  def box(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :box,
      style: Map.get(opts, :style, %{}),
      children: Map.get(opts, :children, []),
      id: Map.get(opts, :id)
    }
  end

  @doc """
  Creates a row layout component.
  """
  @spec row(keyword() | map()) :: map()
  def row(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :row,
      style: Map.get(opts, :style, %{}),
      children: Map.get(opts, :children, []),
      id: Map.get(opts, :id),
      gap: Map.get(opts, :gap, 0)
    }
  end

  @doc """
  Creates a column layout component.
  """
  @spec column(keyword() | map()) :: map()
  def column(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :column,
      style: Map.get(opts, :style, %{}),
      children: Map.get(opts, :children, []),
      id: Map.get(opts, :id),
      gap: Map.get(opts, :gap, 0)
    }
  end

  @doc """
  Creates a label component.
  """
  @spec label(keyword() | map()) :: map()
  def label(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :label,
      attrs: [
        content: Map.get(opts, :content, ""),
        style: Map.get(opts, :style, %{})
      ],
      id: Map.get(opts, :id)
    }
  end

  @doc """
  Creates a button component.
  """
  @spec button(keyword() | map()) :: map()
  def button(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :button,
      content: Map.get(opts, :content, "Button"),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id),
      on_click: Map.get(opts, :on_click)
    }
  end

  @doc """
  Creates an input field component.
  """
  @spec input(keyword() | map()) :: map()
  def input(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :input,
      value: Map.get(opts, :value, ""),
      placeholder: Map.get(opts, :placeholder, ""),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id),
      on_change: Map.get(opts, :on_change)
    }
  end

  @doc """
  Creates a list component.
  """
  @spec list(keyword() | map()) :: map()
  def list(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :list,
      items: Map.get(opts, :items, []),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id),
      selected: Map.get(opts, :selected)
    }
  end

  @doc """
  Creates a spacer component.
  """
  @spec spacer(keyword() | map()) :: map()
  def spacer(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :spacer,
      size: Map.get(opts, :size, 1),
      direction: Map.get(opts, :direction, :vertical)
    }
  end

  @doc """
  Creates a divider component.
  """
  @spec divider(keyword() | map()) :: map()
  def divider(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :divider,
      style: Map.get(opts, :style, %{}),
      char: divider_char(opts)
    }
  end

  # A divider is a border's horizontal run, so it draws with the same charset:
  # `variant: :single` matches a `:single` border exactly (─ ═ -). An explicit
  # `char:` still wins, so callers can draw a divider out of anything.
  #
  # Only known variants are forwarded to BorderRenderer: its catch-all maps
  # anything unrecognised to `:none`, whose horizontal run is a space -- a typo
  # would silently render an invisible divider. Unknown variants draw `:single`.
  @divider_variants [:single, :double, :rounded, :ascii, :none]

  defp divider_char(opts) do
    case Map.get(opts, :char) do
      nil ->
        opts
        |> Map.get(:variant, :single)
        |> then(&if &1 in @divider_variants, do: &1, else: :single)
        |> Raxol.UI.BorderRenderer.get_border_chars()
        |> Map.fetch!(:horizontal)

      char ->
        char
    end
  end

  @doc """
  Creates an image component for inline terminal image display.

  ## Options
  - `:src` - File path or raw binary image data (required)
  - `:width` - Width in terminal cells (default: 20)
  - `:height` - Height in terminal cells (default: 10)
  - `:protocol` - Override protocol (:kitty, :iterm2, :sixel)
  - `:preserve_aspect` - Preserve aspect ratio (default: true)
  - `:style` - Optional style attributes
  - `:id` - Optional component identifier
  """
  @spec image(keyword() | map()) :: map()
  def image(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :image,
      src: Map.get(opts, :src),
      width: Map.get(opts, :width, 20),
      height: Map.get(opts, :height, 10),
      protocol: Map.get(opts, :protocol),
      preserve_aspect: Map.get(opts, :preserve_aspect, true),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id)
    }
  end

  @doc """
  Creates a progress bar component.
  """
  @spec progress(keyword() | map()) :: map()
  def progress(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :progress,
      value: Map.get(opts, :value, 0),
      max: Map.get(opts, :max, 100),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id)
    }
  end

  @doc """
  Creates a modal component.
  """
  @spec modal(keyword() | map()) :: map()
  def modal(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :modal,
      title: Map.get(opts, :title, ""),
      content: Map.get(opts, :content),
      visible: Map.get(opts, :visible, false),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id)
    }
  end

  @doc """
  Creates a table component.
  """
  @spec table(keyword() | map()) :: map()
  def table(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :table,
      headers: Map.get(opts, :headers, []),
      rows: Map.get(opts, :rows, []),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id)
    }
  end

  @doc """
  Creates a select/dropdown component.
  """
  @spec select(keyword() | map()) :: map()
  def select(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :select,
      options: Map.get(opts, :options, []),
      selected: Map.get(opts, :selected),
      placeholder: Map.get(opts, :placeholder, "Select..."),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id),
      on_change: Map.get(opts, :on_change)
    }
  end

  @doc """
  Creates a checkbox component.
  """
  @spec checkbox(keyword() | map()) :: map()
  def checkbox(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :checkbox,
      checked: Map.get(opts, :checked, false),
      label: Map.get(opts, :label, ""),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id),
      on_change: Map.get(opts, :on_change)
    }
  end

  @doc """
  Creates a radio button group component.
  """
  @spec radio_group(keyword() | map()) :: map()
  def radio_group(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :radio_group,
      options: Map.get(opts, :options, []),
      selected: Map.get(opts, :selected),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id),
      on_change: Map.get(opts, :on_change)
    }
  end

  @doc """
  Creates a textarea component.
  """
  @spec textarea(keyword() | map()) :: map()
  def textarea(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :textarea,
      value: Map.get(opts, :value, ""),
      placeholder: Map.get(opts, :placeholder, ""),
      rows: Map.get(opts, :rows, 5),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id),
      on_change: Map.get(opts, :on_change)
    }
  end

  @doc """
  Creates a container component with optional scrolling.
  """
  @spec container(keyword() | map()) :: map()
  def container(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :container,
      children: Map.get(opts, :children, []),
      scrollable: Map.get(opts, :scrollable, false),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id)
    }
  end

  @doc """
  Creates a tabs component.
  """
  @spec tabs(keyword() | map()) :: map()
  def tabs(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %{
      type: :tabs,
      tabs: Map.get(opts, :tabs, []),
      active: Map.get(opts, :active, 0),
      style: Map.get(opts, :style, %{}),
      id: Map.get(opts, :id),
      on_change: Map.get(opts, :on_change)
    }
  end

  @doc """
  Creates a split pane layout component.

  ## Options

    * `:direction` - `:horizontal` or `:vertical` (default `:horizontal`)
    * `:ratio` - Tuple for space distribution (default `{1, 1}`)
    * `:min_size` - Minimum pane dimension (default `5`)
    * `:id` - Optional identifier
    * `:children` - Child elements (one per pane)
  """
  @spec split_pane(keyword() | map()) :: map()
  def split_pane(opts \\ []) do
    Raxol.UI.Layout.SplitPane.new(opts)
  end

  @doc """
  Helper to wrap content in a styled span.
  """
  @spec span(binary(), keyword()) :: map()
  def span(content, opts \\ []) do
    text(Keyword.merge([content: content], opts))
  end

  # -- Chart Components --
  # These render chart cell tuples and convert them to View DSL elements
  # via ViewBridge, so they compose naturally in view/1 functions.

  @doc """
  Creates a braille line chart component.

  ## Options
  - `:series` - List of `%{name: string, data: list, color: atom}` (required)
  - `:width` - Chart width in terminal columns (default: 40)
  - `:height` - Chart height in terminal rows (default: 10)
  - `:show_axes` - Show Y-axis labels (default: false)
  - `:show_legend` - Show series legend (default: false)
  - `:min` / `:max` - Y-axis range (default: :auto)
  - `:style` - Box style for the wrapper
  - `:id` - Optional component identifier
  """
  @spec line_chart(keyword() | map()) :: map()
  def line_chart(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts
    render_chart(:line, opts)
  end

  @doc """
  Creates a block-character bar chart component.

  ## Options
  - `:series` - List of `%{name: string, data: list, color: atom}` (required)
  - `:width` - Chart width in terminal columns (default: 40)
  - `:height` - Chart height in terminal rows (default: 10)
  - `:orientation` - `:vertical` or `:horizontal` (default: :vertical)
  - `:show_axes` - Show axis labels (default: false)
  - `:show_legend` - Show series legend (default: false)
  - `:show_values` - Show value labels on bars (default: false)
  - `:bar_gap` - Gap between bars within a group (default: 0)
  - `:group_gap` - Gap between groups (default: 1)
  - `:min` / `:max` - Value range (default: :auto)
  - `:style` - Box style for the wrapper
  - `:id` - Optional component identifier
  """
  @spec bar_chart(keyword() | map()) :: map()
  def bar_chart(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts
    render_chart(:bar, opts)
  end

  @doc """
  Creates a braille scatter plot component.

  ## Options
  - `:series` - List of `%{name: string, data: [{x, y}], color: atom}` (required)
  - `:width` - Chart width in terminal columns (default: 40)
  - `:height` - Chart height in terminal rows (default: 10)
  - `:show_axes` - Show axis labels (default: false)
  - `:show_legend` - Show series legend (default: false)
  - `:x_range` / `:y_range` - Axis ranges as `{min, max}` or `:auto` (default: :auto)
  - `:style` - Box style for the wrapper
  - `:id` - Optional component identifier
  """
  @spec scatter_chart(keyword() | map()) :: map()
  def scatter_chart(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts
    render_chart(:scatter, opts)
  end

  @doc """
  Creates a heatmap component.

  ## Options
  - `:data` - 2D grid as `[[number]]` row-major (required)
  - `:width` - Chart width in terminal columns (default: 40)
  - `:height` - Chart height in terminal rows (default: 10)
  - `:color_scale` - `:warm`, `:cool`, `:diverging`, or `fn/3` (default: :warm)
  - `:show_values` - Show value labels in cells (default: false)
  - `:min` / `:max` - Value range (default: :auto)
  - `:style` - Box style for the wrapper
  - `:id` - Optional component identifier
  """
  @spec heatmap(keyword() | map()) :: map()
  def heatmap(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts
    render_chart(:heatmap, opts)
  end

  @doc """
  Creates a minimal sparkline (line chart with no axes or legend).

  ## Options
  - `:data` - List of numbers (required)
  - `:width` - Width in terminal columns (default: 20)
  - `:height` - Height in terminal rows (default: 3)
  - `:color` - Line color (default: :cyan)
  - `:min` / `:max` - Y-axis range (default: :auto)
  - `:style` - Box style for the wrapper
  - `:id` - Optional component identifier
  """
  @spec sparkline(keyword() | map()) :: map()
  def sparkline(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    data = Map.get(opts, :data, [])
    color = Map.get(opts, :color, :cyan)
    series = [%{name: "spark", data: data, color: color}]

    chart_opts =
      opts
      |> Map.put(:series, series)
      |> Map.put(:show_axes, false)
      |> Map.put(:show_legend, false)

    render_chart(:line, chart_opts)
  end

  # -- Chart rendering internals --

  defp render_chart(chart_type, opts) do
    w = Map.get(opts, :width, 40)
    h = Map.get(opts, :height, 10)
    style = Map.get(opts, :style, %{})
    region = {0, 0, w, h}

    chart_opts = chart_render_opts(chart_type, opts)

    cells =
      case chart_type do
        :line ->
          Raxol.UI.Charts.LineChart.render(
            region,
            Map.get(opts, :series, []),
            chart_opts
          )

        :bar ->
          Raxol.UI.Charts.BarChart.render(
            region,
            Map.get(opts, :series, []),
            chart_opts
          )

        :scatter ->
          Raxol.UI.Charts.ScatterChart.render(
            region,
            Map.get(opts, :series, []),
            chart_opts
          )

        :heatmap ->
          Raxol.UI.Charts.Heatmap.render(
            region,
            Map.get(opts, :data, []),
            chart_opts
          )
      end

    view =
      Raxol.UI.Charts.ViewBridge.cells_to_view(cells,
        style: style,
        region: region
      )

    # Preserve chart type, series, and render opts so MCP ToolProvider
    # can expose chart data as read-only tools via TreeWalker.
    view =
      view
      |> Map.put(:type, chart_view_type(chart_type))
      |> Map.put(:series, Map.get(opts, :series, Map.get(opts, :data, [])))
      |> Map.put(:chart_opts, chart_opts)

    case Map.get(opts, :id) do
      nil -> view
      id -> Map.put(view, :id, id)
    end
  end

  defp chart_view_type(:line), do: :line_chart
  defp chart_view_type(:bar), do: :bar_chart
  defp chart_view_type(:scatter), do: :scatter_chart
  defp chart_view_type(:heatmap), do: :heatmap

  defp chart_render_opts(:line, opts) do
    [
      show_axes: Map.get(opts, :show_axes, false),
      show_legend: Map.get(opts, :show_legend, false),
      min: Map.get(opts, :min, :auto),
      max: Map.get(opts, :max, :auto)
    ]
  end

  defp chart_render_opts(:bar, opts) do
    [
      orientation: Map.get(opts, :orientation, :vertical),
      show_axes: Map.get(opts, :show_axes, false),
      show_legend: Map.get(opts, :show_legend, false),
      show_values: Map.get(opts, :show_values, false),
      bar_gap: Map.get(opts, :bar_gap, 0),
      group_gap: Map.get(opts, :group_gap, 1),
      min: Map.get(opts, :min, :auto),
      max: Map.get(opts, :max, :auto)
    ]
  end

  defp chart_render_opts(:scatter, opts) do
    [
      show_axes: Map.get(opts, :show_axes, false),
      show_legend: Map.get(opts, :show_legend, false),
      x_range: Map.get(opts, :x_range, :auto),
      y_range: Map.get(opts, :y_range, :auto)
    ]
  end

  defp chart_render_opts(:heatmap, opts) do
    [
      color_scale: Map.get(opts, :color_scale, :warm),
      show_values: Map.get(opts, :show_values, false),
      min: Map.get(opts, :min, :auto),
      max: Map.get(opts, :max, :auto)
    ]
  end
end
