defmodule Raxol.Terminal.Renderer do
  @moduledoc """
  Terminal renderer module.

  This module handles rendering of terminal output using ANSI escape codes,
  including:
  - Character cell rendering
  - Text styling (colors, bold, italic, underline)
  - Cursor rendering
  - Performance optimizations (style batching, caching)

  ## Integration with Other Modules

  The Renderer module works closely with several specialized modules:

  ### Manipulation Module
  - Receives text and style updates from the Manipulation module
  - Renders text with proper styling and positioning
  - Handles text insertion, deletion, and modification

  ### Selection Module
  - Renders text selections with visual highlighting
  - Supports multiple selections
  - Handles selection state changes

  ### Validation Module
  - Renders validation errors and warnings
  - Applies visual indicators for invalid input
  - Shows validation state through styling

  ## Performance Optimizations

  The renderer includes several optimizations:
  - Only renders changed cells
  - Batches style updates for consecutive cells
  - Minimizes terminal output
  - Caches rendered output when possible

  ## Usage

  ```elixir
  # Create a new renderer
  buffer = ScreenBuffer.new(80, 24)
  renderer = Renderer.new(buffer)

  # Render with selection
  selection = %{selection: {0, 0, 0, 5}}
  output = Renderer.render(renderer, selection: selection)

  # Render with validation
  validation = Validation.validate_input(buffer, 0, 0, "text")
  output = Renderer.render(renderer, validation: validation)
  ```
  """

  alias Raxol.Terminal.ScreenBuffer

  @type t :: %__MODULE__{
          screen_buffer: ScreenBuffer.t(),
          cursor: {non_neg_integer(), non_neg_integer()} | nil,
          theme: map(),
          font_settings: map(),
          style_cache: map()
        }

  defstruct [
    :screen_buffer,
    :cursor,
    :theme,
    :font_settings,
    :style_batching,
    style_cache: %{}
  ]

  # ANSI escape code constants
  @ansi_reset "\e[0m"
  @ansi_bold "\e[1m"
  @ansi_italic "\e[3m"
  @ansi_underline "\e[4m"

  # Standard foreground color codes
  @fg_color_codes %{
    black: "30",
    red: "31",
    green: "32",
    yellow: "33",
    blue: "34",
    magenta: "35",
    cyan: "36",
    white: "37",
    bright_black: "90",
    bright_red: "91",
    bright_green: "92",
    bright_yellow: "93",
    bright_blue: "94",
    bright_magenta: "95",
    bright_cyan: "96",
    bright_white: "97"
  }

  # Standard background color codes
  @bg_color_codes %{
    black: "40",
    red: "41",
    green: "42",
    yellow: "43",
    blue: "44",
    magenta: "45",
    cyan: "46",
    white: "47",
    bright_black: "100",
    bright_red: "101",
    bright_green: "102",
    bright_yellow: "103",
    bright_blue: "104",
    bright_magenta: "105",
    bright_cyan: "106",
    bright_white: "107"
  }

  @doc """
  Creates a new renderer with the given screen buffer.

  ## Examples

      iex> screen_buffer = ScreenBuffer.new(80, 24)
      iex> renderer = Renderer.new(screen_buffer)
      iex> renderer.screen_buffer
      %ScreenBuffer{}
  """
  def new(
        screen_buffer,
        theme \\ %{},
        font_settings \\ %{},
        style_batching \\ false
      ) do
    %__MODULE__{
      screen_buffer: screen_buffer,
      cursor: nil,
      theme: theme,
      font_settings: font_settings,
      style_batching: style_batching,
      style_cache: %{}
    }
  end

  @doc """
  Renders the terminal content. The optional `opts` arguments are currently
  unused (accepted for call-site compatibility).
  """
  def render(renderer, opts \\ [], additional_opts \\ [])

  def render(%__MODULE__{} = renderer, _opts, _additional_opts) do
    renderer.screen_buffer
    |> get_styled_content_optimized(renderer.theme, renderer.style_batching)
    |> apply_font_settings(renderer.font_settings)
    |> maybe_apply_cursor(renderer.cursor)
  end

  @doc """
  Renders each buffer row to its own ANSI string, in order.

  `render/1` is `Enum.join(render_rows(renderer), "\\n")` modulo the (currently
  no-op) font/cursor wrappers -- a property pinned by test. An incremental
  renderer diffs the grid and re-emits individual rows via this instead of
  rebuilding the whole frame string.
  """
  @spec render_rows(t()) :: [String.t()]
  def render_rows(%__MODULE__{} = renderer) do
    Enum.map(
      renderer.screen_buffer.cells,
      &render_row_optimized(&1, renderer.theme, renderer.style_batching)
    )
  end

  @doc """
  Renders a single row (0-based) to its ANSI string. Out-of-range rows render
  as `""`. A row is a pure function of its own cells -- it carries no pen state
  from the row above, so a row rendered in isolation is byte-identical to its
  slice of the full frame.
  """
  @spec render_row(t(), non_neg_integer()) :: String.t()
  def render_row(%__MODULE__{} = renderer, y) when is_integer(y) and y >= 0 do
    case Enum.at(renderer.screen_buffer.cells, y) do
      nil -> ""
      row -> render_row_optimized(row, renderer.theme, renderer.style_batching)
    end
  end

  defp get_styled_content_optimized(buffer, theme, style_batching) do
    buffer.cells
    |> Enum.map_join("\n", fn row ->
      render_row_optimized(row, theme, style_batching)
    end)
  end

  defp render_row_optimized(row, theme, style_batching) do
    # Group by hyperlink first so a contiguous run of cells sharing a URL is
    # wrapped in a single OSC 8 open/close pair, while SGR styling is free to
    # vary within the link. Runs with no hyperlink render exactly as before.
    row
    |> Enum.chunk_by(&cell_hyperlink/1)
    |> Enum.map_join("", fn chunk ->
      chunk
      |> render_style_runs(theme, style_batching)
      |> maybe_wrap_hyperlink(hd(chunk).style)
    end)
  end

  # Render a run of cells (all sharing one hyperlink) into SGR-styled text:
  # batched groups consecutive same-style cells, individual emits one at a time.
  defp render_style_runs(cells, theme, true) do
    cells
    |> Enum.chunk_by(& &1.style)
    |> Enum.map_join("", fn same_style ->
      style = hd(same_style).style
      chars = Enum.map_join(same_style, "", & &1.char)
      apply_sgr(build_ansi_prefix(style, theme), chars)
    end)
  end

  defp render_style_runs(cells, theme, _individual) do
    Enum.map_join(cells, "", fn cell ->
      apply_sgr(build_ansi_prefix(cell.style, theme), cell.char)
    end)
  end

  defp apply_sgr("", content), do: content
  defp apply_sgr(prefix, content), do: prefix <> content <> @ansi_reset

  defp cell_hyperlink(cell), do: hyperlink_url(cell.style)

  # Wrap already-styled content in a single OSC 8 hyperlink when the run carries
  # one. Bare form `ESC ] 8 ; ; URL ST  <content>  ESC ] 8 ; ; ST`; clickable in
  # OSC 8-aware terminals (iTerm2, kitty, WezTerm), ignored elsewhere. SGR may
  # vary inside; the link spans the whole run.
  defp maybe_wrap_hyperlink(content, style) do
    case hyperlink_url(style) do
      url when is_binary(url) and url != "" ->
        "\e]8;;" <> url <> "\e\\" <> content <> "\e]8;;\e\\"

      _ ->
        content
    end
  end

  defp hyperlink_url(%{__struct__: _} = style), do: Map.get(style, :hyperlink)
  defp hyperlink_url(style) when is_map(style), do: Map.get(style, :hyperlink)
  defp hyperlink_url(_style), do: nil

  # Build ANSI escape prefix from style and theme
  defp build_ansi_prefix(style, theme) do
    style_map = normalize_style(style)
    codes = []

    # Foreground color
    codes =
      case Map.get(style_map, :foreground) do
        nil ->
          case get_default_fg_ansi(theme) do
            nil -> codes
            code -> [code | codes]
          end

        color ->
          case resolve_fg_ansi(color, theme) do
            nil -> codes
            code -> [code | codes]
          end
      end

    # Background color. An unpainted background emits nothing: the cell keeps
    # the terminal's own background, which is what makes it transparent on a
    # terminal with transparency enabled. Falling back to the theme's default
    # background here would paint every unpainted cell -- and the theme's
    # "default background" is, by definition, the terminal's, so painting it
    # is a no-op on an opaque terminal and an opaque rectangle on a
    # transparent one.
    codes =
      case Map.get(style_map, :background) do
        nil ->
          codes

        color ->
          case resolve_bg_ansi(color, theme) do
            nil -> codes
            code -> [code | codes]
          end
      end

    # Text attributes
    codes =
      if Map.get(style_map, :bold, false),
        do: [@ansi_bold | codes],
        else: codes

    codes =
      if Map.get(style_map, :italic, false),
        do: [@ansi_italic | codes],
        else: codes

    codes =
      case underline_style_ansi(Map.get(style_map, :underline_style)) do
        nil ->
          if Map.get(style_map, :underline, false),
            do: [@ansi_underline | codes],
            else: codes

        code ->
          [code | codes]
      end

    codes =
      case underline_color_ansi(Map.get(style_map, :underline_color)) do
        nil -> codes
        code -> [code | codes]
      end

    case codes do
      [] -> ""
      _ -> codes |> Enum.reverse() |> Enum.join("")
    end
  end

  # Underline styles beyond plain/single are emitted via the colon-form SGR 4
  # subparameter; :single, :none, and unset styles fall back to the plain
  # boolean `:underline` handling above (byte-identical to prior behavior).
  defp underline_style_ansi(:double), do: "\e[4:2m"
  defp underline_style_ansi(:curly), do: "\e[4:3m"
  defp underline_style_ansi(:dotted), do: "\e[4:4m"
  defp underline_style_ansi(:dashed), do: "\e[4:5m"
  defp underline_style_ansi(_), do: nil

  defp underline_color_ansi({:rgb, r, g, b}), do: "\e[58;2;#{r};#{g};#{b}m"
  defp underline_color_ansi({:index, n}), do: "\e[58;5;#{n}m"
  defp underline_color_ansi(_), do: nil

  # Resolve foreground color to ANSI code
  defp resolve_fg_ansi(color, theme) when is_atom(color) do
    # Check theme first
    theme_color = get_in(theme, [:foreground, color])

    case theme_color do
      nil ->
        # Use standard ANSI color code
        case Map.get(@fg_color_codes, color) do
          nil -> nil
          code -> "\e[#{code}m"
        end

      hex when is_binary(hex) ->
        hex_to_ansi_fg(hex)
    end
  end

  defp resolve_fg_ansi(%{r: r, g: g, b: b}, _theme) do
    "\e[38;2;#{r};#{g};#{b}m"
  end

  # Plain {r, g, b} tuples (UI-stack/CellDim RGB shape -- distinct from the
  # %{r:, g:, b:} map clause above) must also resolve to truecolor SGR.
  defp resolve_fg_ansi({r, g, b}, _theme)
       when is_integer(r) and is_integer(g) and is_integer(b) do
    "\e[38;2;#{r};#{g};#{b}m"
  end

  defp resolve_fg_ansi(color, _theme)
       when is_integer(color) and color >= 0 and color <= 255 do
    "\e[38;5;#{color}m"
  end

  defp resolve_fg_ansi(color, _theme) when is_binary(color) do
    hex_to_ansi_fg(color)
  end

  defp resolve_fg_ansi(_, _), do: nil

  # Resolve background color to ANSI code
  defp resolve_bg_ansi(color, theme) when is_atom(color) do
    theme_color = get_in(theme, [:background, color])

    case theme_color do
      nil ->
        case Map.get(@bg_color_codes, color) do
          nil -> nil
          code -> "\e[#{code}m"
        end

      hex when is_binary(hex) ->
        hex_to_ansi_bg(hex)
    end
  end

  defp resolve_bg_ansi(%{r: r, g: g, b: b}, _theme) do
    "\e[48;2;#{r};#{g};#{b}m"
  end

  # Same as resolve_fg_ansi/2 for {r, g, b} tuples.
  defp resolve_bg_ansi({r, g, b}, _theme)
       when is_integer(r) and is_integer(g) and is_integer(b) do
    "\e[48;2;#{r};#{g};#{b}m"
  end

  defp resolve_bg_ansi(color, _theme)
       when is_integer(color) and color >= 0 and color <= 255 do
    "\e[48;5;#{color}m"
  end

  defp resolve_bg_ansi(color, _theme) when is_binary(color) do
    hex_to_ansi_bg(color)
  end

  defp resolve_bg_ansi(_, _), do: nil

  # Get default foreground ANSI from theme
  defp get_default_fg_ansi(theme) do
    case get_in(theme, [:foreground, :default]) do
      nil -> nil
      hex when is_binary(hex) -> hex_to_ansi_fg(hex)
      _ -> nil
    end
  end

  # Get default background ANSI from theme

  # Convert hex color string to ANSI 24-bit foreground escape
  defp hex_to_ansi_fg(hex) do
    case parse_hex_color(hex) do
      {:ok, r, g, b} -> "\e[38;2;#{r};#{g};#{b}m"
      :error -> nil
    end
  end

  # Convert hex color string to ANSI 24-bit background escape
  defp hex_to_ansi_bg(hex) do
    case parse_hex_color(hex) do
      {:ok, r, g, b} -> "\e[48;2;#{r};#{g};#{b}m"
      :error -> nil
    end
  end

  # Parse "#RRGGBB" or "#RGB" hex color strings
  defp parse_hex_color("#" <> hex), do: parse_hex_digits(hex)
  defp parse_hex_color(hex) when is_binary(hex), do: parse_hex_digits(hex)

  defp parse_hex_digits(
         <<_::binary-size(2), _::binary-size(2), _::binary-size(2)>> = hex
       ) do
    case Raxol.Terminal.Color.TrueColor.AnsiCodes.parse_hex_6(hex) do
      {:ok, r, g, b, _a} -> {:ok, r, g, b}
      {:error, _} -> :error
    end
  end

  defp parse_hex_digits(
         <<_::binary-size(1), _::binary-size(1), _::binary-size(1)>> = hex
       ) do
    case Raxol.Terminal.Color.TrueColor.AnsiCodes.parse_hex_3(hex) do
      {:ok, r, g, b, _a} -> {:ok, r, g, b}
      {:error, _} -> :error
    end
  end

  defp parse_hex_digits(_), do: :error

  defp normalize_style(%{__struct__: _} = style) do
    Map.from_struct(style)
  end

  defp normalize_style(style) when is_map(style) do
    style
  end

  defp normalize_style(_style) do
    %{}
  end

  defp apply_font_settings(content, _font_settings), do: content
  defp maybe_apply_cursor(content, nil), do: content
  defp maybe_apply_cursor(content, _cursor), do: content

  @doc """
  Sets the cursor position.

  ## Examples

      iex> screen_buffer = ScreenBuffer.new(80, 24)
      iex> renderer = Renderer.new(screen_buffer)
      iex> renderer = Renderer.set_cursor(renderer, {10, 5})
      iex> renderer.cursor
      {10, 5}
  """
  def set_cursor(%__MODULE__{} = renderer, position) do
    %{renderer | cursor: position}
  end

  @doc """
  Clears the cursor position.

  ## Examples

      iex> screen_buffer = ScreenBuffer.new(80, 24)
      iex> renderer = Renderer.new(screen_buffer)
      iex> renderer = Renderer.set_cursor(renderer, {10, 5})
      iex> renderer = Renderer.clear_cursor(renderer)
      iex> renderer.cursor
      nil
  """
  def clear_cursor(%__MODULE__{} = renderer) do
    %{renderer | cursor: nil}
  end

  @doc """
  Updates the theme settings.

  ## Examples

      iex> screen_buffer = ScreenBuffer.new(80, 24)
      iex> renderer = Renderer.new(screen_buffer)
      iex> theme = %{foreground: %{default: "#FFF"}}
      iex> renderer = Renderer.set_theme(renderer, theme)
      iex> renderer.theme
      %{foreground: %{default: "#FFF"}}
  """
  def set_theme(%__MODULE__{} = renderer, theme) do
    %{renderer | theme: theme}
  end

  @doc """
  Updates the font settings.

  ## Examples

      iex> screen_buffer = ScreenBuffer.new(80, 24)
      iex> renderer = Renderer.new(screen_buffer)
      iex> settings = %{family: "Fira Code"}
      iex> renderer = Renderer.set_font_settings(renderer, settings)
      iex> renderer.font_settings
      %{family: "Fira Code"}
  """
  def set_font_settings(%__MODULE__{} = renderer, settings) do
    %{renderer | font_settings: settings}
  end

  @doc """
  Starts a new renderer process.
  """
  def start_link(opts \\ []) do
    screen_buffer = Keyword.get(opts, :screen_buffer, ScreenBuffer.new(80, 24))
    theme = Keyword.get(opts, :theme, %{})
    font_settings = Keyword.get(opts, :font_settings, %{})

    renderer = new(screen_buffer, theme, font_settings)
    {:ok, renderer}
  end

  @doc """
  Stops the renderer process.
  """
  def stop(_renderer) do
    :ok
  end

  @doc """
  Gets the current content of the screen buffer.

  ## Parameters
    * `renderer` - The renderer to get content from
    * `opts` - Options for content retrieval
      * `:include_style` - Whether to include style information (default: false)
      * `:include_cursor` - Whether to include cursor position (default: false)

  ## Returns
    * `{:ok, content}` - The current content
    * `{:error, reason}` - If content retrieval fails

  ## Examples
      iex> get_content(renderer)
      {:ok, "Hello, World!"}
  """
  def get_content(renderer, opts \\ [])

  def get_content(%__MODULE__{} = renderer, opts) do
    _include_style = Keyword.get(opts, :include_style, true)
    include_cursor = Keyword.get(opts, :include_cursor, true)

    content =
      renderer.screen_buffer
      |> ScreenBuffer.get_content()

    apply_cursor_option(content, renderer.cursor, include_cursor)
  end

  # Handle ScreenBuffer structs (updated after buffer consolidation)
  def get_content(%Raxol.Terminal.ScreenBuffer{} = buffer, opts) do
    _include_style = Keyword.get(opts, :include_style, false)
    include_cursor = Keyword.get(opts, :include_cursor, false)

    content =
      buffer
      |> Raxol.Terminal.ScreenBuffer.get_lines()
      |> Enum.map_join("\n", &Enum.join/1)
      |> maybe_add_cursor(buffer.cursor_position, include_cursor)

    {:ok, content}
  end

  # Handle buffer manager PIDs (legacy support - deprecated after buffer consolidation)
  def get_content(manager_pid, _opts) when is_pid(manager_pid) do
    {:error, :deprecated_buffer_manager}
  end

  defp apply_cursor_option(content, cursor, true) do
    content |> maybe_add_cursor(cursor, true)
  end

  defp apply_cursor_option(content, _cursor, false), do: content

  defp maybe_add_cursor(content, nil, _include_cursor), do: content
  defp maybe_add_cursor(content, cursor, true), do: {content, cursor}
  defp maybe_add_cursor(content, _cursor, false), do: content
end
