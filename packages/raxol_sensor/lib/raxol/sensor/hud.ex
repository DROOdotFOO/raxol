defmodule Raxol.Sensor.HUD do
  @moduledoc """
  Pure functional HUD rendering for sensor data.

  All functions take a region `{x, y, w, h}`, data, and options,
  and return a list of `{x, y, char, fg, bg, attrs}` cell tuples.
  """

  @type cell ::
          {non_neg_integer(), non_neg_integer(), String.t(), atom(), atom(), map()}
  @type region ::
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @spark_chars ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

  @doc """
  Renders a horizontal gauge bar.

  Options:
  - `label` -- prefix label (default: "")
  - `min` -- minimum value (default: 0.0)
  - `max` -- maximum value (default: 100.0)
  - `thresholds` -- `{warn, crit}` percentages (default: `{0.6, 0.85}`)
  """
  @spec render_gauge(region(), number(), keyword()) :: [cell()]
  def render_gauge({x, y, w, _h}, value, opts \\ []) do
    label = Keyword.get(opts, :label, "")
    min_val = Keyword.get(opts, :min, 0.0)
    max_val = Keyword.get(opts, :max, 100.0)
    {warn_pct, crit_pct} = Keyword.get(opts, :thresholds, {0.6, 0.85})

    range = max_val - min_val
    raw_pct = if range > 0, do: (value - min_val) / range, else: 0.0
    pct = clamp(raw_pct, 0.0, 1.0)

    prefix = if label != "", do: "#{label} ", else: ""
    suffix = " #{round(pct * 100)}%"
    bar_width = max(w - String.length(prefix) - String.length(suffix) - 2, 1)

    filled = round(pct * bar_width)
    empty = bar_width - filled

    fg = gauge_color(pct, warn_pct, crit_pct)

    line =
      prefix <>
        "[" <>
        String.duplicate("█", filled) <>
        String.duplicate("░", empty) <>
        "]" <>
        suffix

    line
    |> String.slice(0, w)
    |> string_to_cells(x, y, fg, :default)
  end

  @doc """
  Renders a sparkline from a list of numeric values.

  Options:
  - `label` -- prefix label (default: "")
  - `min` -- explicit minimum (default: auto from data)
  - `max` -- explicit maximum (default: auto from data)
  """
  @spec render_sparkline(region(), [number()], keyword()) :: [cell()]
  def render_sparkline(region, values, opts \\ [])
  def render_sparkline({_x, _y, _w, _h}, [], _opts), do: []

  def render_sparkline({x, y, w, _h}, values, opts) do
    label = Keyword.get(opts, :label, "")
    data_min = Keyword.get_lazy(opts, :min, fn -> Enum.min(values) end)
    data_max = Keyword.get_lazy(opts, :max, fn -> Enum.max(values) end)

    prefix = if label != "", do: "#{label} ", else: ""
    spark_width = max(w - String.length(prefix), 1)

    # Take the last spark_width values
    display_values = Enum.take(values, -spark_width)

    range = data_max - data_min
    last_idx = length(@spark_chars) - 1

    spark_str =
      Enum.map_join(display_values, fn v ->
        normalized = if range > 0, do: (v - data_min) / range, else: 0.5
        idx = clamp(round(normalized * last_idx), 0, last_idx)
        Enum.at(@spark_chars, idx)
      end)

    line = prefix <> spark_str
    string_to_cells(line, x, y, :cyan, :default)
  end

  @doc """
  Renders a threat indicator with level and bearing.

  Options:
  - `label` -- prefix (default: "THREAT")

  Levels: `:none`, `:low`, `:medium`, `:high`, `:critical`
  """
  @spec render_threat(region(), atom(), number(), keyword()) :: [cell()]
  def render_threat({x, y, w, _h}, level, bearing_deg, opts \\ []) do
    label = Keyword.get(opts, :label, "THREAT")
    {icon, fg} = threat_style(level)

    bearing_str =
      bearing_deg
      |> round()
      |> Integer.to_string()
      |> String.pad_leading(3, "0")

    line =
      "#{icon} #{label} #{level_str(level)} #{bearing_str}deg"
      |> String.pad_trailing(w)
      |> String.slice(0, w)

    string_to_cells(line, x, y, fg, :default)
  end

  @doc """
  Renders a minimap using braille dot patterns.

  Entities: `[%{x: 0.0..1.0, y: 0.0..1.0, char: "x"}]`
  Maps normalized coordinates into a braille grid (2 dots wide x 4 dots tall per character).

  Options:
  - `border` -- draw border (default: true)
  """
  @spec render_minimap(region(), [map()], keyword()) :: [cell()]
  def render_minimap({x, y, w, h}, entities, opts \\ []) do
    border = Keyword.get(opts, :border, true)

    {inner_x, inner_y, inner_w, inner_h} =
      if border do
        {x + 1, y + 1, max(w - 2, 1), max(h - 2, 1)}
      else
        {x, y, w, h}
      end

    # Braille grid: each char is 2 dots wide, 4 dots tall
    dot_w = inner_w * 2
    dot_h = inner_h * 4

    # Build dot grid
    dots = :array.new(dot_w * dot_h, default: false)

    dots =
      Enum.reduce(entities, dots, fn entity, acc ->
        dx = round(Map.get(entity, :x, 0.0) * (dot_w - 1))
        dy = round(Map.get(entity, :y, 0.0) * (dot_h - 1))

        if dx >= 0 and dx < dot_w and dy >= 0 and dy < dot_h do
          :array.set(dy * dot_w + dx, true, acc)
        else
          acc
        end
      end)

    # Convert dot grid to braille characters
    braille_cells =
      for cy <- 0..(inner_h - 1), cx <- 0..(inner_w - 1) do
        codepoint = braille_codepoint(dots, cx * 2, cy * 4, dot_w)
        char = <<codepoint::utf8>>
        {inner_x + cx, inner_y + cy, char, :green, :default, %{}}
      end

    if border do
      border_cells(x, y, w, h) ++ braille_cells
    else
      braille_cells
    end
  end

  # -- Private --

  defp gauge_color(pct, _warn, crit) when pct >= crit, do: :red
  defp gauge_color(pct, warn, _crit) when pct >= warn, do: :yellow
  defp gauge_color(_pct, _warn, _crit), do: :green

  defp threat_style(:none), do: {"[ ]", :green}
  defp threat_style(:low), do: {"[.]", :green}
  defp threat_style(:medium), do: {"[*]", :yellow}
  defp threat_style(:high), do: {"[!]", :red}
  defp threat_style(:critical), do: {"[!]", :red}
  defp threat_style(_), do: {"[?]", :white}

  defp level_str(:none), do: "NONE"
  defp level_str(:low), do: "LOW"
  defp level_str(:medium), do: "MED"
  defp level_str(:high), do: "HIGH"
  defp level_str(:critical), do: "CRIT"
  defp level_str(other), do: to_string(other)

  # Braille dot positions within a character cell:
  # (0,0) (1,0)    bits: 0x01 0x08
  # (0,1) (1,1)          0x02 0x10
  # (0,2) (1,2)          0x04 0x20
  # (0,3) (1,3)          0x40 0x80
  @braille_offsets [
    {0, 0, 0x01},
    {0, 1, 0x02},
    {0, 2, 0x04},
    {0, 3, 0x40},
    {1, 0, 0x08},
    {1, 1, 0x10},
    {1, 2, 0x20},
    {1, 3, 0x80}
  ]

  defp braille_codepoint(dots, bx, by, dot_w) do
    Enum.reduce(@braille_offsets, 0x2800, fn {dx, dy, bit}, acc ->
      px = bx + dx
      py = by + dy

      if :array.get(py * dot_w + px, dots) do
        Bitwise.bor(acc, bit)
      else
        acc
      end
    end)
  end

  defp border_cells(x, y, w, h) do
    top =
      for cx <- 0..(w - 1) do
        char =
          cond do
            cx == 0 -> "┌"
            cx == w - 1 -> "┐"
            true -> "─"
          end

        {x + cx, y, char, :white, :default, %{}}
      end

    bottom =
      for cx <- 0..(w - 1) do
        char =
          cond do
            cx == 0 -> "└"
            cx == w - 1 -> "┘"
            true -> "─"
          end

        {x + cx, y + h - 1, char, :white, :default, %{}}
      end

    sides =
      for cy <- 1..(h - 2) do
        [
          {x, y + cy, "│", :white, :default, %{}},
          {x + w - 1, y + cy, "│", :white, :default, %{}}
        ]
      end

    top ++ bottom ++ List.flatten(sides)
  end

  # Local clamp -- raxol_sensor has zero deps, cannot import from raxol_core
  defp clamp(val, lo, hi), do: val |> max(lo) |> min(hi)

  defp string_to_cells(string, x, y, fg, bg) do
    string
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map(fn {char, offset} ->
      {x + offset, y, char, fg, bg, %{}}
    end)
  end
end
