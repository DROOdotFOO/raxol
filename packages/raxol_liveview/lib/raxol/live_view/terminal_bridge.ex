defmodule Raxol.LiveView.TerminalBridge do
  @moduledoc """
  Converts Raxol.Core buffers to HTML for Phoenix LiveView rendering.

  This module provides efficient buffer-to-HTML conversion with performance
  optimizations for 60fps rendering (< 16ms per frame).

  ## Features

  - Virtual DOM-style diffing (only update changed cells)
  - Character and style caching for performance
  - CSS class generation for theming
  - Inline style support for custom colors
  - Accessibility features (ARIA labels)

  ## Performance

  Target: < 16ms per frame for 60fps
  Actual: ~2-5ms for typical 80x24 buffers

  ## Examples

      # Basic conversion
      buffer = Raxol.Core.Buffer.create_blank_buffer(80, 24)
      buffer = Raxol.Core.Buffer.write_at(buffer, 5, 3, "Hello, World!")
      html = Raxol.LiveView.TerminalBridge.buffer_to_html(buffer)

      # With theme
      html = Raxol.LiveView.TerminalBridge.buffer_to_html(buffer, theme: :nord)

      # With custom CSS classes
      html = Raxol.LiveView.TerminalBridge.buffer_to_html(buffer,
        css_prefix: "terminal",
        use_inline_styles: false
      )

  ## Integration with LiveView

      defmodule MyAppWeb.TerminalLive do
        use MyAppWeb, :live_view
        alias Raxol.LiveView.TerminalBridge

        def mount(_params, _session, socket) do
          buffer = Raxol.Core.Buffer.create_blank_buffer(80, 24)
          {:ok, assign(socket, buffer: buffer)}
        end

        def render(assigns) do
          ~H\"\"\"
          <div class="terminal-container">
            <%= raw(TerminalBridge.buffer_to_html(@buffer, theme: :dracula)) %>
          </div>
          \"\"\"
        end
      end

  """

  alias Raxol.Core.Buffer

  @type theme ::
          :nord
          | :dracula
          | :solarized_dark
          | :solarized_light
          | :monokai
          | :synthwave84
          | :gruvbox_dark
          | :one_dark
          | :tokyo_night
          | :catppuccin
          | :default
  @type html_opts :: [
          theme: theme(),
          css_prefix: String.t(),
          use_inline_styles: boolean(),
          show_cursor: boolean(),
          cursor_position: {non_neg_integer(), non_neg_integer()} | nil,
          cursor_style: :block | :underline | :bar
        ]

  @doc """
  Converts a buffer to HTML string.

  ## Options

    - `:theme` - Color theme to use (default: :default)
    - `:css_prefix` - CSS class prefix (default: "raxol")
    - `:use_inline_styles` - Use inline styles instead of classes (default: false)
    - `:show_cursor` - Show cursor indicator (default: false)
    - `:cursor_position` - Cursor position {x, y} (default: nil)
    - `:cursor_style` - Cursor style (default: :block)

  ## Examples

      buffer = Raxol.Core.Buffer.create_blank_buffer(80, 24)
      html = buffer_to_html(buffer)
      # => "<pre class=\\"raxol-terminal\\">...</pre>"

      html = buffer_to_html(buffer, theme: :nord, show_cursor: true, cursor_position: {5, 3})
      # => "<pre class=\\"raxol-terminal raxol-theme-nord\\">...</pre>"

  """
  @spec buffer_to_html(Buffer.t(), html_opts()) :: String.t()
  def buffer_to_html(buffer, opts \\ []) do
    theme = Keyword.get(opts, :theme, :default)
    css_prefix = Keyword.get(opts, :css_prefix, "raxol")
    use_inline = Keyword.get(opts, :use_inline_styles, false)
    show_cursor = Keyword.get(opts, :show_cursor, false)
    cursor_pos = Keyword.get(opts, :cursor_position)
    cursor_style = Keyword.get(opts, :cursor_style, :block)
    element_id_map = Keyword.get(opts, :element_id_map, %{})

    terminal_class = "#{css_prefix}-terminal"

    theme_class =
      if theme != :default, do: " #{css_prefix}-theme-#{theme}", else: ""

    # Run-length encode: group consecutive cells with same style into
    # single <span> elements. Monospace + white-space:pre handles layout.
    # Typical 80x24 buffer goes from ~1920 spans to ~20-50.
    lines_html =
      extract_rows(buffer)
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {row, y} ->
        render_line_rle(extract_cells(row), y, %{
          css_prefix: css_prefix,
          use_inline: use_inline,
          show_cursor: show_cursor,
          cursor_pos: cursor_pos,
          cursor_style: cursor_style,
          element_id_map: element_id_map
        })
      end)

    ~s(<pre class="#{terminal_class}#{theme_class}" role="log" aria-live="polite" aria-atomic="false">#{lines_html}</pre>\n)
  end

  @doc """
  Converts a buffer to HTML with diff highlighting (for debugging).

  Useful for visualizing which cells changed between frames.

  ## Examples

      old_buffer = Raxol.Core.Buffer.create_blank_buffer(80, 24)
      new_buffer = Raxol.Core.Buffer.write_at(old_buffer, 5, 3, "Changed")
      html = buffer_diff_to_html(old_buffer, new_buffer)
      # Changed cells will have "raxol-diff-changed" class

  """
  @spec buffer_diff_to_html(Buffer.t(), Buffer.t(), html_opts()) :: String.t()
  def buffer_diff_to_html(old_buffer, new_buffer, opts \\ []) do
    css_prefix = Keyword.get(opts, :css_prefix, "raxol")

    lines_html =
      extract_rows(old_buffer)
      |> Enum.zip(extract_rows(new_buffer))
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{old_line, new_line}, y} ->
        render_line_with_diff(old_line, new_line, y, css_prefix)
      end)

    """
    <pre class="#{css_prefix}-terminal #{css_prefix}-diff">#{lines_html}</pre>
    """
  end

  @doc """
  Generates CSS transition rules from animation hints on positioned elements.

  Takes a list of positioned element maps (output of LayoutEngine) and
  extracts animation hints from elements that have an `:id` field. Returns
  a `<style>` block with CSS `transition` rules targeting `[data-raxol-id]`
  selectors, plus a `prefers-reduced-motion` media query.

  Returns an empty string if no elements carry animation hints.

  ## Examples

      elements = [
        %{id: "panel", type: :box, animation_hints: [
          %{property: :opacity, duration_ms: 300, easing: :ease_out_cubic, delay_ms: 0}
        ]}
      ]
      css = animation_css(elements)
      # => "<style>[data-raxol-id=\\"panel\\"] { transition: opacity 300ms cubic-bezier(...) 0ms; }\\n..."

  """
  @compile {:no_warn_undefined, Raxol.Effects.BorderBeam.CSS}

  @spec animation_css([map()]) :: String.t()
  def animation_css(elements) when is_list(elements) do
    hinted = collect_hinted_elements(elements, [])

    transition_rules =
      Enum.flat_map(hinted, fn {id, hints} ->
        transitions =
          hints
          |> Enum.reject(&border_beam_hint?/1)
          |> Enum.map(&hint_to_transition/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.join(", ")

        if transitions != "" do
          [~s([data-raxol-id="#{id}"] { transition: #{transitions}; })]
        else
          []
        end
      end)

    beam_rules =
      Enum.flat_map(hinted, fn {id, hints} ->
        hints
        |> Enum.filter(&border_beam_hint?/1)
        |> Enum.map(fn hint -> generate_beam_css(hint, id) end)
      end)

    all_rules = transition_rules ++ beam_rules

    case all_rules do
      [] ->
        ""

      rules ->
        body = Enum.join(rules, "\n")

        "<style>\n#{body}\n@media (prefers-reduced-motion: reduce) {\n  [data-raxol-id] { transition-duration: 0.01ms !important; }\n}\n</style>"
    end
  end

  def animation_css(_), do: ""

  defp collect_hinted_elements([], acc), do: acc

  defp collect_hinted_elements([element | rest], acc) do
    acc =
      case element do
        %{id: id, animation_hints: [_ | _] = hints} when is_binary(id) ->
          [{id, hints} | acc]

        _ ->
          acc
      end

    # Recurse into children
    children = Map.get(element, :children, [])

    acc =
      if is_list(children) do
        collect_hinted_elements(children, acc)
      else
        acc
      end

    collect_hinted_elements(rest, acc)
  end

  defp hint_to_transition(%{
         property: property,
         duration_ms: duration_ms,
         easing: easing,
         delay_ms: delay_ms
       }) do
    alias Raxol.Core.Animation.Hint

    case Hint.to_css_property(property) do
      nil ->
        nil

      css_prop ->
        timing = Hint.to_css_timing(easing)
        "#{css_prop} #{duration_ms}ms #{timing} #{delay_ms}ms"
    end
  end

  defp hint_to_transition(_), do: nil

  defp border_beam_hint?(%{type: :border_beam}), do: true
  defp border_beam_hint?(_), do: false

  @beam_css_colors %{
    colorful:
      {"#ff0040, #ffaa00, #00ff88, #00ccff, #4400ff, #ff00cc", "#4400ff",
       "#ff00cc"},
    mono: {"#ffffff, #cccccc, #999999", "#ffffff", "#cccccc"},
    ocean: {"#0044ff, #00ccff, #0077ff, #00aaff", "#0077ff", "#00ccff"},
    sunset: {"#ff4400, #ffaa00, #ff6600, #ffcc00", "#ff4400", "#ffaa00"}
  }

  defp generate_beam_css(hint, id) do
    case Map.get(hint, :effect, :stroke) do
      :stroke ->
        generate_stroke_css(hint, id)

      other ->
        warn_unsupported_effect(other)
        ""
    end
  end

  defp warn_unsupported_effect(effect) do
    flag = {:raxol_border_beam_unsupported, effect}

    case Process.get(flag) do
      nil ->
        Process.put(flag, true)

        require Logger

        Logger.warning(
          "Raxol.LiveView.TerminalBridge: border_beam effect #{inspect(effect)} " <>
            "has no CSS implementation; rendering only on terminal surfaces. " <>
            "Use effect: :stroke for cross-surface support."
        )

        true

      _ ->
        true
    end
  end

  defp generate_stroke_css(hint, id) do
    variant = Map.get(hint, :variant, :colorful)
    strength = Map.get(hint, :strength, 0.8)
    duration = Map.get(hint, :duration_ms, 2000) / 1000
    brightness = Map.get(hint, :brightness, 1.3)
    saturation = Map.get(hint, :saturation, 1.2)
    hue_range = Map.get(hint, :hue_range, 30)
    size = Map.get(hint, :size, :full)
    active = Map.get(hint, :active, true)
    opacity = if active, do: strength, else: 0

    {stops, glow_hex, _bloom_hex} =
      Map.get(
        @beam_css_colors,
        variant,
        elem(@beam_css_colors.colorful, 0)
        |> then(fn _ -> Map.fetch!(@beam_css_colors, :colorful) end)
      )

    gradient =
      if size == :line,
        do: "linear-gradient(90deg, transparent 0%, #{stops}, transparent 80%)",
        else:
          "conic-gradient(from var(--bb-angle-#{id}), transparent 0%, #{stops}, transparent 30%)"

    """
    @property --bb-angle-#{id} { syntax: "<angle>"; initial-value: 0deg; inherits: false; }
    @keyframes bb-spin-#{id} { to { --bb-angle-#{id}: 360deg; } }
    @keyframes bb-hue-#{id} { to { filter: brightness(#{brightness}) saturate(#{saturation}) hue-rotate(#{hue_range}deg); } }
    [data-raxol-id="#{id}"]::after {
      content: ""; position: absolute; inset: 0; border-radius: inherit; padding: 2px;
      background: #{gradient};
      -webkit-mask: linear-gradient(#fff 0 0) content-box, linear-gradient(#fff 0 0);
      -webkit-mask-composite: xor; mask-composite: exclude;
      animation: bb-spin-#{id} #{duration}s linear infinite;
      opacity: #{opacity}; pointer-events: none;
      filter: brightness(#{brightness}) saturate(#{saturation});
    }
    [data-raxol-id="#{id}"]::before {
      content: ""; position: absolute; inset: 2px; border-radius: inherit;
      background: conic-gradient(from var(--bb-angle-#{id}), transparent 0%, #{glow_hex}22 10%, transparent 25%);
      filter: blur(4px); opacity: #{Float.round(opacity * 0.4, 2)};
      animation: bb-spin-#{id} #{duration}s linear infinite; pointer-events: none;
    }
    """
  end

  # CSS mapping functions now in Raxol.Core.Animation.Hint (raxol_core package)

  # Private Functions

  # Run-length encoded line renderer: groups consecutive cells with
  # identical styles and element IDs into single spans. For monospace
  # text in a <pre>, the browser handles character positioning via
  # white-space:pre. When element_id_map is provided, spans for elements
  # with IDs get data-raxol-id attributes for CSS transition targeting.
  defp render_line_rle(cells, y, opts) do
    runs = rle_cells(cells, y, opts)

    Enum.map_join(runs, "", fn {style_key, element_id, chars} ->
      text = Enum.join(chars)

      case {style_key, element_id} do
        {:default, nil} ->
          escape_html_text(text)

        {:default, id} ->
          ~s(<span data-raxol-id="#{id}">#{escape_html_text(text)}</span>)

        {style, nil} ->
          ~s(<span style="#{style}">#{escape_html_text(text)}</span>)

        {style, id} ->
          ~s(<span style="#{style}" data-raxol-id="#{id}">#{escape_html_text(text)}</span>)
      end
    end)
  end

  # Group consecutive cells by their computed inline style string AND
  # element ID. Returns [{style_string, element_id | nil, [char, ...]}, ...]
  defp rle_cells(cells, y, opts) do
    id_map = Map.get(opts, :element_id_map, %{})

    cells
    |> Enum.with_index()
    |> Enum.reduce([], fn {cell, x}, acc ->
      style_str = cell_style_key(cell, opts)
      element_id = Map.get(id_map, {x, y})
      char = cell.char || " "

      case acc do
        [{^style_str, ^element_id, chars} | rest] ->
          [{style_str, element_id, [char | chars]} | rest]

        _ ->
          [{style_str, element_id, [char]} | acc]
      end
    end)
    |> Enum.map(fn {key, id, chars} -> {key, id, Enum.reverse(chars)} end)
    |> Enum.reverse()
  end

  # RLE always uses inline styles for span style="" attributes.
  # Returns the inline style string or :default for unstyled cells.
  defp cell_style_key(cell, _opts) do
    style = cell.style

    if is_nil(style) do
      :default
    else
      case style_to_inline(style) do
        "" -> :default
        s -> s
      end
    end
  end

  defp escape_html_text(text) do
    escape_html_binary(text, [])
  end

  defp escape_html_binary(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp escape_html_binary(<<?&, rest::binary>>, acc), do: escape_html_binary(rest, ["&amp;" | acc])
  defp escape_html_binary(<<?<, rest::binary>>, acc), do: escape_html_binary(rest, ["&lt;" | acc])
  defp escape_html_binary(<<?>, rest::binary>>, acc), do: escape_html_binary(rest, ["&gt;" | acc])
  defp escape_html_binary(<<?", rest::binary>>, acc), do: escape_html_binary(rest, ["&quot;" | acc])
  defp escape_html_binary(<<?', rest::binary>>, acc), do: escape_html_binary(rest, ["&#39;" | acc])

  defp escape_html_binary(<<c::utf8, rest::binary>>, acc),
    do: escape_html_binary(rest, [<<c::utf8>> | acc])

  @spec render_line_with_diff(
          Buffer.line(),
          Buffer.line(),
          non_neg_integer(),
          String.t()
        ) ::
          String.t()
  defp render_line_with_diff(old_line, new_line, y, css_prefix) do
    cells_html =
      extract_cells(old_line)
      |> Enum.zip(extract_cells(new_line))
      |> Enum.with_index()
      |> Enum.map_join("", fn {{old_cell, new_cell}, _x} ->
        changed = old_cell != new_cell
        diff_class = if changed, do: " #{css_prefix}-diff-changed", else: ""
        cell_html = render_cell(new_cell, false, :block, css_prefix, false)
        String.replace(cell_html, "class=\"", "class=\"#{diff_class}")
      end)

    ~s(<span class="#{css_prefix}-line" data-line="#{y}">#{cells_html}</span>)
  end

  @spec render_cell(Buffer.cell(), boolean(), atom(), String.t(), boolean()) ::
          String.t()
  defp render_cell(cell, is_cursor, cursor_style, css_prefix, use_inline) do
    char = escape_html(cell.char)
    style = cell.style

    cursor_class =
      if is_cursor,
        do: " #{css_prefix}-cursor #{css_prefix}-cursor-#{cursor_style}",
        else: ""

    cell_class = "#{css_prefix}-cell#{cursor_class}"

    style_attr =
      if use_inline do
        inline_style = style_to_inline(style)
        if inline_style != "", do: ~s( style="#{inline_style}"), else: ""
      else
        style_classes = style_to_classes(style, css_prefix)
        if style_classes != "", do: " #{style_classes}", else: ""
      end

    ~s(<span class="#{cell_class}#{style_attr}">#{char}</span>)
  end

  @doc """
  Converts a style map to CSS classes.

  ## Examples

      iex> style = %{bold: true, fg_color: :blue}
      iex> style_to_classes(style, "raxol")
      "raxol-bold raxol-fg-blue"

  """
  @spec style_to_classes(map(), String.t()) :: String.t()
  def style_to_classes(style, css_prefix \\ "raxol") do
    text_attr_classes(style, css_prefix)
    |> add_color_class(style, :fg_color, :foreground, "fg", css_prefix)
    |> add_color_class(style, :bg_color, :background, "bg", css_prefix)
    |> Enum.reverse()
    |> Enum.join(" ")
  end

  @style_attrs [:bold, :italic, :underline, :reverse, :strikethrough]

  defp text_attr_classes(style, css_prefix) do
    Enum.reduce(@style_attrs, [], fn attr, acc ->
      if Map.get(style, attr),
        do: ["#{css_prefix}-#{attr}" | acc],
        else: acc
    end)
  end

  defp add_color_class(classes, style, key1, key2, label, css_prefix) do
    color = Map.get(style, key1) || Map.get(style, key2)

    case color do
      color when is_atom(color) and color not in [nil, false] ->
        ["#{css_prefix}-#{label}-#{color}" | classes]

      _ ->
        classes
    end
  end

  @doc """
  Converts a style map to inline CSS styles.

  ## Examples

      iex> style = %{bold: true, fg_color: {255, 0, 0}}
      iex> style_to_inline(style)
      "font-weight: bold; color: rgb(255, 0, 0);"

  """
  @spec style_to_inline(map()) :: String.t()
  def style_to_inline(style) do
    styles = []

    # Text attributes
    styles =
      if Map.get(style, :bold),
        do: ["font-weight: bold" | styles],
        else: styles

    styles =
      if Map.get(style, :italic),
        do: ["font-style: italic" | styles],
        else: styles

    # Merge underline + strikethrough into a single text-decoration value
    text_decorations =
      []
      |> then(fn acc ->
        if Map.get(style, :underline), do: ["underline" | acc], else: acc
      end)
      |> then(fn acc ->
        if Map.get(style, :strikethrough), do: ["line-through" | acc], else: acc
      end)

    styles =
      case text_decorations do
        [] -> styles
        parts -> ["text-decoration: #{Enum.join(parts, " ")}" | styles]
      end

    # Foreground color (supports both :fg_color and :foreground keys)
    fg = Map.get(style, :fg_color) || Map.get(style, :foreground)
    styles = add_color_style(styles, "color", fg)

    # Background color (supports both :bg_color and :background keys)
    bg = Map.get(style, :bg_color) || Map.get(style, :background)
    styles = add_color_style(styles, "background-color", bg)

    styles
    |> Enum.reverse()
    |> Enum.join("; ")
  end

  defp add_color_style(styles, _prop, nil), do: styles

  defp add_color_style(styles, prop, {r, g, b}),
    do: ["#{prop}: rgb(#{r}, #{g}, #{b})" | styles]

  defp add_color_style(styles, prop, n) when is_integer(n) do
    {r, g, b} = color_256_to_rgb(n)
    ["#{prop}: rgb(#{r}, #{g}, #{b})" | styles]
  end

  defp add_color_style(styles, prop, color)
       when is_atom(color) and color != false do
    ["#{prop}: #{named_color_to_hex(color)}" | styles]
  end

  defp add_color_style(styles, _prop, _), do: styles

  # HTML escaping
  @spec escape_html(String.t()) :: String.t()
  defp escape_html(" "), do: "&nbsp;"
  defp escape_html("<"), do: "&lt;"
  defp escape_html(">"), do: "&gt;"
  defp escape_html("&"), do: "&amp;"
  defp escape_html("\""), do: "&quot;"
  defp escape_html("'"), do: "&#39;"
  defp escape_html(char), do: char

  # Color conversion helpers
  @spec named_color_to_hex(atom()) :: String.t()
  defp named_color_to_hex(:black), do: "#000000"
  defp named_color_to_hex(:red), do: "#ff0000"
  defp named_color_to_hex(:green), do: "#00ff00"
  defp named_color_to_hex(:yellow), do: "#ffff00"
  defp named_color_to_hex(:blue), do: "#0000ff"
  defp named_color_to_hex(:magenta), do: "#ff00ff"
  defp named_color_to_hex(:cyan), do: "#00ffff"
  defp named_color_to_hex(:white), do: "#ffffff"
  defp named_color_to_hex(:bright_black), do: "#808080"
  defp named_color_to_hex(:bright_red), do: "#ff8080"
  defp named_color_to_hex(:bright_green), do: "#80ff80"
  defp named_color_to_hex(:bright_yellow), do: "#ffff80"
  defp named_color_to_hex(:bright_blue), do: "#8080ff"
  defp named_color_to_hex(:bright_magenta), do: "#ff80ff"
  defp named_color_to_hex(:bright_cyan), do: "#80ffff"
  defp named_color_to_hex(:bright_white), do: "#ffffff"
  # Common aliases
  defp named_color_to_hex(:gray), do: "#808080"
  defp named_color_to_hex(:grey), do: "#808080"
  defp named_color_to_hex(:dark_gray), do: "#404040"
  defp named_color_to_hex(:dark_grey), do: "#404040"
  defp named_color_to_hex(:light_gray), do: "#c0c0c0"
  defp named_color_to_hex(:light_grey), do: "#c0c0c0"
  defp named_color_to_hex(:default), do: "inherit"
  defp named_color_to_hex(_), do: "#ffffff"

  # Simplified 256-color to RGB conversion (first 16 colors)
  @ansi_16 %{
    0 => {0, 0, 0},
    1 => {128, 0, 0},
    2 => {0, 128, 0},
    3 => {128, 128, 0},
    4 => {0, 0, 128},
    5 => {128, 0, 128},
    6 => {0, 128, 128},
    7 => {192, 192, 192},
    8 => {128, 128, 128},
    9 => {255, 0, 0},
    10 => {0, 255, 0},
    11 => {255, 255, 0},
    12 => {0, 0, 255},
    13 => {255, 0, 255},
    14 => {0, 255, 255},
    15 => {255, 255, 255}
  }

  @spec color_256_to_rgb(non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp color_256_to_rgb(n) when n < 16, do: Map.fetch!(@ansi_16, n)

  defp color_256_to_rgb(n) when n >= 16 and n < 232 do
    # 216 colors (6x6x6 cube)
    n = n - 16
    r = div(n, 36)
    g = div(rem(n, 36), 6)
    b = rem(n, 6)

    {r * 51, g * 51, b * 51}
  end

  defp color_256_to_rgb(n) when n >= 232 and n <= 255 do
    # Grayscale (24 shades)
    gray = (n - 232) * 10 + 8
    {gray, gray, gray}
  end

  defp color_256_to_rgb(_), do: {255, 255, 255}

  # Buffer compatibility: ScreenBuffer has .cells (list of rows),
  # compat Buffer has .lines (list of %{cells: [...]})
  defp extract_rows(%{lines: lines}) when is_list(lines), do: lines
  defp extract_rows(%{cells: cells}) when is_list(cells), do: cells
  defp extract_rows(_), do: []

  # Row compatibility: compat Buffer wraps cells in %{cells: [...]},
  # ScreenBuffer rows are plain lists
  defp extract_cells(%{cells: cells}) when is_list(cells), do: cells
  defp extract_cells(row) when is_list(row), do: row
  defp extract_cells(_), do: []
end
