defmodule Raxol.Core.Runtime.Rendering.Backends do
  @moduledoc """
  Rendering backend implementations for different output targets.

  Handles converting cells to output for terminal, VSCode, LiveView, and SSH backends.
  Extracted from `Raxol.Core.Runtime.Rendering.Engine` to keep rendering dispatch
  separate from the GenServer lifecycle.
  """

  alias Raxol.Terminal.ScreenBuffer
  alias Raxol.UI.Rendering.PaintAuthority.Dialect

  # --- Backend Dispatch ---

  @doc """
  Renders cells to the terminal backend with ANSI output.

  `cursor` is an optional view-declared cursor park, normalized as
  `{row, col, visible?}` (0-based buffer coordinates) or the raw
  `{row, col}` / `{row, col, visible?}` declaration -- see
  `declared_cursor/1`. `nil` (the default, and every pre-existing caller)
  is byte-identical to the cursor-less pipeline: no cursor bytes are
  emitted and the fresh buffer's cursor fields keep their defaults.

  When a cursor is declared, the resulting buffer is stamped with the
  clamped `cursor_position` (`{x, y}` order, matching the ScreenBuffer
  field) and `cursor_visible` -- the buffer-level cursor contract that
  headless asserts read -- and the emitted frame carries the matching
  byte tail (see `build_terminal_frame/5`).
  """
  def render_to_terminal(cells, state, cursor \\ nil) do
    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine: Executing render_to_terminal"
    )

    updated_buffer =
      cells
      |> apply_cells_to_buffer(state)
      |> stamp_cursor(cursor)

    # style_batching: merge adjacent same-style cells into one SGR run instead
    # of one SGR + reset per cell. Round-trip-identical (each run still
    # \e[0m-terminated), 8-28x fewer bytes on styled UIs.
    renderer = Raxol.Terminal.Renderer.new(updated_buffer, %{}, %{}, true)

    frame =
      build_terminal_frame(
        state.buffer,
        updated_buffer,
        renderer,
        state,
        cursor
      )

    # Device seam (harness F0-env): an io_writer, when configured, IS the
    # output device -- the same frame bytes go through it instead of
    # stdout, so the harness pump and tests can own the tty. No :terminal
    # caller sets io_writer, so that path stays byte-identical. Map.get,
    # not dot access: test states may not carry the key (see below).
    case Map.get(state, :io_writer) do
      writer when is_function(writer, 1) ->
        write_output(writer, frame, state.sync_output)

      _ ->
        if state.sync_output do
          IO.write("\e[?2026h")
          IO.write(frame)
          IO.write("\e[?2026l")
        else
          IO.write(frame)
        end
    end

    # Send frame to recorder if active
    if pid = Process.whereis(Raxol.Recording.Recorder) do
      Raxol.Recording.Recorder.record_output(pid, frame)
    end

    # Map.put (not %{state | ...}) so the flag is set whether or not the caller's
    # state carries it -- the real Engine.State always does; test states may not.
    {:ok,
     state |> Map.put(:buffer, updated_buffer) |> Map.put(:force_repaint, false)}
  end

  # --- Incremental frame emission ---
  #
  # One absolute-CUP vocabulary for both frame kinds (ADR-0029 inv 5): every row
  # is emitted at \e[y;1H, so there are no \r\n row-joins and no full-screen
  # clear on the common path. A keyframe is that same emit over every row, with
  # a leading \e[2J; a diff emits only rows whose cells changed. `state.buffer`
  # is the previous frame, already in hand -- the grid is its own diff basis.
  #
  # Cursor park (F0-cursor, harness-tea-migration law 6): when a cursor is
  # declared, every frame kind -- keyframe, diff, even a zero-row diff --
  # ends with the park tail, because emitted rows move the physical cursor
  # and nothing else puts it back (the InlineAuthority park rationale:
  # "the rows moved the physical cursor, so the park CUP is what puts it
  # back at the edit point"). Visible parks as DECTCEM show + CUP (the
  # frame's last bytes are the CUP); hidden is DECTCEM hide alone. The
  # tail is part of the frame string, so it sits inside the DEC-2026
  # bracket whenever `render_to_terminal/3` opens one. No declaration
  # appends nothing -- byte-identity with the pre-cursor pipeline is by
  # construction.

  @doc false
  def build_terminal_frame(prev, next, renderer, state, cursor \\ nil) do
    body =
      if keyframe?(prev, next, state) do
        "\e[2J" <> emit_rows(renderer, all_rows(next))
      else
        emit_rows(renderer, changed_rows(prev, next))
      end

    body <> cursor_tail(cursor, next)
  end

  defp keyframe?(nil, _next, _state), do: true
  defp keyframe?(_prev, _next, %{force_repaint: true}), do: true

  defp keyframe?(prev, next, _state),
    do: prev.width != next.width or prev.height != next.height

  defp all_rows(buffer), do: Enum.to_list(0..(buffer.height - 1)//1)

  defp changed_rows(prev, next) do
    Enum.filter(0..(next.height - 1)//1, fn y ->
      Enum.at(prev.cells, y) != Enum.at(next.cells, y)
    end)
  end

  defp emit_rows(renderer, rows) do
    Enum.map_join(rows, "", fn y ->
      "\e[#{y + 1};1H\e[0m\e[2K" <>
        Raxol.Terminal.Renderer.render_row(renderer, y)
    end)
  end

  # --- Cursor park (F0-cursor) ---

  @typedoc """
  A normalized cursor declaration: 0-based buffer `{row, col}` plus
  visibility. `nil` means "no declaration" -- the pipeline emits no cursor
  bytes at all.
  """
  @type cursor_declaration ::
          {non_neg_integer(), non_neg_integer(), boolean()} | nil

  @doc """
  Extracts a cursor declaration from the root of the element tree that
  `view/1` returned.

  The declaration seam is a root-level `:cursor` key on that map --
  `{row, col}` (visible) or `{row, col, visible?}`, 0-based buffer
  coordinates, absolute. Total: any other shape (no key, malformed tuple,
  negative or non-integer coordinates, a non-map view) is `nil`, never a
  crash.

  Absence semantics: the declaration is per-frame and absence means
  "emit no cursor bytes", NOT "restore defaults" -- a frame without a
  declaration leaves the terminal in whatever DECTCEM/position state the
  previous frame set. An app that wants the cursor hidden (or parked)
  must keep declaring it every frame; the harness's `view/1` does this
  naturally since the declaration is a pure projection of the model.

  Decision record (F0-cursor, harness-tea-migration §5 law 6):

    * CHOSEN -- root-level view key. The view is the app -> pipeline
      interface, and the Engine already hands the raw view tree to backend
      dispatch, so the declaration rides plumbing that exists; `view/1`
      stays the single place where "what is shown" -- cursor included --
      is a pure projection of the model. Apps set it with
      `Map.put(tree, :cursor, {row, col})` or the
      `Raxol.Core.Renderer.View.view/2` macro's opts, which merge into
      the root.
    * REJECTED -- a `:cursor` attr on nested elements, resolved to
      absolutes by the LayoutEngine. Composability is real (a component
      could declare its caret relative to itself), but attrs demonstrably
      do not survive layout today: every `process_element` clause
      rebuilds its positioned output map by hand, so threading one attr
      means touching every clause plus a multiple-declaration policy.
      Revisit at Phase 2 if Composer-as-Component wants relative
      declaration; a later resolver can lower nested declarations into
      this same root contract without changing the byte tail.
    * REJECTED -- a reserved key on the app MODEL. Proven collision:
      `Raxol.Playground.Demos.CursorTrailDemo` already has
      `model.cursor = {x, y}` meaning mouse position; a reserved model
      key would silently repurpose it, and the model is app-private
      namespace the runtime should not claim.
  """
  @spec declared_cursor(term()) :: cursor_declaration()
  def declared_cursor(%{cursor: declaration}), do: normalize_cursor(declaration)
  def declared_cursor(_view), do: nil

  defp normalize_cursor({row, col}), do: normalize_cursor({row, col, true})

  defp normalize_cursor({row, col, visible?})
       when is_integer(row) and row >= 0 and is_integer(col) and col >= 0 and
              is_boolean(visible?),
       do: {row, col, visible?}

  defp normalize_cursor(_), do: nil

  # The byte tail appended after the row writes. Visible ends the frame
  # with DECTCEM show + the park CUP (1-based on the wire); hidden is
  # DECTCEM hide alone. Bytes come from the shared Dialect vocabulary,
  # never hand-rolled here.
  defp cursor_tail(cursor, buffer) do
    case clamp_cursor(normalize_cursor(cursor), buffer) do
      nil ->
        ""

      {row, col, true} ->
        Dialect.cursor_show() <> Dialect.cursor_position(row + 1, col + 1)

      {_row, _col, false} ->
        Dialect.cursor_hide()
    end
  end

  # Wrong states are unrepresentable downstream (same doctrine as
  # `sanitize_char/1`): a declaration beyond the grid clamps to the last
  # cell, so the emitted CUP and the stamped buffer cursor always agree
  # and always land inside the buffer.
  defp clamp_cursor(nil, _buffer), do: nil

  defp clamp_cursor({row, col, visible?}, buffer) do
    {min(row, buffer.height - 1), min(col, buffer.width - 1), visible?}
  end

  # Stamps the declared cursor onto the frame's buffer -- the buffer-level
  # half of the contract (`cursor_position` is {x, y}, matching the
  # ScreenBuffer field). No declaration leaves the fresh buffer's defaults
  # untouched.
  defp stamp_cursor(buffer, cursor) do
    case clamp_cursor(normalize_cursor(cursor), buffer) do
      nil ->
        buffer

      {row, col, visible?} ->
        %{buffer | cursor_position: {col, row}, cursor_visible: visible?}
    end
  end

  @doc """
  Renders cells to the VSCode backend via stdio interface.
  """
  def render_to_vscode(_cells, state) do
    case state.stdio_interface_pid do
      nil -> {:error, :stdio_not_available}
      _ -> {:ok, :rendered}
    end
  end

  @doc """
  Renders cells to the LiveView backend via PubSub broadcast.

  When `positioned_elements` carry animation hints, generates a companion
  `<style>` block with CSS transitions and broadcasts it alongside the
  terminal HTML. LiveView receives `{:render_update, html, animation_css}`.

  `a11y_map` is an `id -> accessibility_node` map (from
  `Raxol.Core.Accessibility.Projection.by_id/1`) that the bridge uses to emit
  per-element ARIA on spans whose `data-raxol-id` matches an entry.
  """
  @compile {:no_warn_undefined, [Raxol.LiveView.TerminalBridge, Phoenix.PubSub]}
  def render_to_liveview(
        cells,
        state,
        positioned_elements \\ [],
        a11y_map \\ %{}
      ) do
    updated_buffer = apply_cells_to_buffer(cells, state)

    if Code.ensure_loaded?(Raxol.LiveView.TerminalBridge) do
      element_id_map = build_element_id_map(positioned_elements)

      html =
        Raxol.LiveView.TerminalBridge.buffer_to_html(updated_buffer,
          use_inline_styles: true,
          element_id_map: element_id_map,
          a11y_map: a11y_map
        )

      animation_css =
        Raxol.LiveView.TerminalBridge.animation_css(positioned_elements)

      _ =
        if state.liveview_topic && Code.ensure_loaded?(Phoenix.PubSub) do
          Phoenix.PubSub.broadcast(
            Raxol.PubSub,
            state.liveview_topic,
            {:render_update, html, animation_css}
          )
        end

      {:ok, %{state | buffer: updated_buffer}}
    else
      {:ok, %{state | buffer: updated_buffer}}
    end
  end

  # Builds a map of {x, y} -> element_id from positioned elements.
  # Only includes elements that have a string :id field.
  # Used by TerminalBridge to emit data-raxol-id attributes on spans.
  defp build_element_id_map(elements) when is_list(elements) do
    elements
    |> Enum.reduce(%{}, fn element, acc ->
      acc = fill_element_coords(element, acc)

      children = Map.get(element, :children, [])

      if is_list(children) do
        Enum.reduce(children, acc, fn child, inner_acc ->
          fill_element_coords(child, inner_acc)
        end)
      else
        acc
      end
    end)
  end

  defp build_element_id_map(_), do: %{}

  defp fill_element_coords(%{id: id, x: x, y: y, width: w, height: h}, acc)
       when is_binary(id) and is_integer(x) and is_integer(y) and
              is_integer(w) and is_integer(h) do
    for row <- y..(y + h - 1)//1,
        col <- x..(x + w - 1)//1,
        reduce: acc do
      acc -> Map.put_new(acc, {col, row}, id)
    end
  end

  defp fill_element_coords(_, acc), do: acc

  @doc """
  Renders cells to a Telegram chat via an io_writer function.

  Converts the buffer to plain text (no ANSI) and delivers it to
  the session's io_writer callback, which sends/edits the Telegram message.
  """
  @spec render_to_telegram(list(), map()) :: {:ok, map()}
  def render_to_telegram(cells, state) do
    updated_buffer = apply_cells_to_buffer(cells, state)

    # Deliver buffer to io_writer -- the Session will format for Telegram
    if is_function(state.io_writer, 1) do
      state.io_writer.(%{buffer: updated_buffer, view_tree: state[:view_tree]})
    end

    {:ok, %{state | buffer: updated_buffer}}
  end

  @doc """
  Renders cells to an SSH channel via an io_writer function.
  """
  def render_to_ssh(cells, state) do
    updated_buffer = apply_cells_to_buffer(cells, state)

    # style_batching: merge adjacent same-style cells into one SGR run instead
    # of one SGR + reset per cell. Round-trip-identical (each run still
    # \e[0m-terminated), 8-28x fewer bytes on styled UIs.
    renderer = Raxol.Terminal.Renderer.new(updated_buffer, %{}, %{}, true)
    output_string = Raxol.Terminal.Renderer.render(renderer)

    # Home cursor and clear screen before each frame, matching render_to_terminal
    frame = normalize_frame("\e[H\e[2J" <> output_string)

    write_output(state.io_writer, frame, state.sync_output)

    {:ok, %{state | buffer: updated_buffer}}
  end

  # --- Output Helpers ---

  @doc """
  Normalizes bare `\\n` row joins in a rendered frame to `\\r\\n`.

  `Raxol.Terminal.Renderer.render/1` joins rows with a bare `\\n`, relying on
  the terminal driver to cook LF into CRLF. The driver runs prim_tty in raw
  output mode (see `Raxol.Terminal.Driver.start_stdin_reader/1`), where a
  bare `\\n` only advances the line without returning to column 0 -- every
  row after the first drifts one column right, and combined with DECAWM
  autowrap on full-width rows this doubles the frame's vertical extent.
  `\\r\\n` is mode-independent: raw mode gets a real CR+LF, and cooked
  mode's LF->CRLF translation just turns it into a harmless `\\r\\r\\n`.
  """
  @spec normalize_frame(String.t()) :: String.t()
  def normalize_frame(output_string) when is_binary(output_string) do
    String.replace(output_string, "\n", "\r\n")
  end

  @doc false
  def write_output(writer, output, true) when is_function(writer, 1) do
    writer.("\e[?2026h")
    writer.(output)
    writer.("\e[?2026l")
  end

  def write_output(writer, output, _sync) when is_function(writer, 1) do
    writer.(output)
  end

  def write_output(_, _, _) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "SSH render: no io_writer configured",
      %{}
    )
  end

  # --- Cell Processing ---

  @doc """
  Transforms raw cells and writes them into a fresh ScreenBuffer.

  A new buffer is created each frame so stale cells from previous views don't
  persist. The fill goes through `ScreenBuffer.fill_cells/3` -- one pass per
  touched row instead of one `write_char` row-rebuild per cell -- with
  `inherit_background/2` as the per-write style resolver, preserving the
  sequential fold's semantics exactly (F0-buffer).
  """
  def apply_cells_to_buffer(cells, state) do
    screen_buffer = ScreenBuffer.new(state.width, state.height)

    ScreenBuffer.fill_cells(
      screen_buffer,
      cell_writes(cells),
      &inherit_background/2
    )
  end

  # Cells do not composite -- writing one replaces what was there -- so a cell
  # with an unpainted background would ERASE the background already beneath it,
  # punching a hole through a filled parent (a button drawn on a modal would
  # show the desktop through it). An unpainted background means "show what is
  # beneath", so inherit the background already at that coordinate -- including
  # from a cell written earlier in this same batch, which is how a child's
  # transparent cells pick up the background run its parent just painted.
  # At the top there is nothing beneath, so it stays nil and the terminal shows
  # through -- which is what keeps a transparent terminal transparent.
  defp inherit_background(style, current_cell) when is_map(style) do
    case Map.get(style, :background) do
      nil -> Map.put(style, :background, cell_background(current_cell))
      _painted -> style
    end
  end

  defp inherit_background(style, _current_cell), do: style

  defp cell_background(%{style: %{background: bg}}), do: bg
  defp cell_background(_), do: nil

  # --- Color Conversion ---

  # Terminal color code mapping
  @terminal_color_map %{
    0 => "black",
    1 => "red",
    2 => "green",
    3 => "yellow",
    4 => "blue",
    5 => "magenta",
    6 => "cyan",
    7 => "white",
    8 => "brightBlack",
    9 => "brightRed",
    10 => "brightGreen",
    11 => "brightYellow",
    12 => "brightBlue",
    13 => "brightMagenta",
    14 => "brightCyan",
    15 => "brightWhite"
  }

  @doc false
  def convert_color_to_vscode(color) when is_integer(color) do
    @terminal_color_map[color] || "default"
  end

  def convert_color_to_vscode({r, g, b})
      when is_integer(r) and is_integer(g) and is_integer(b) do
    "rgb(#{r},#{g},#{b})"
  end

  def convert_color_to_vscode(color) when is_binary(color), do: color
  def convert_color_to_vscode(_), do: "default"

  # --- Private Helpers ---

  # Raw renderer cells -> `{x, y, char, style}` write tuples for
  # `ScreenBuffer.fill_cells/3`. Same transform the old per-cell fold ran
  # (sanitize, fg/bg, bold/underline/italic, hyperlink), minus the
  # intermediate Cell struct it built only to unpack again.
  defp cell_writes(cells) when is_list(cells) do
    Enum.map(cells, fn {x, y, char, fg, bg, attrs_list} ->
      {hyperlink, style_atoms} = split_hyperlink(attrs_list || [])
      attrs_map = Enum.into(style_atoms, %{}, fn atom -> {atom, true} end)

      style =
        %{
          foreground: fg,
          background: bg
        }
        |> Map.merge(Map.take(attrs_map, [:bold, :underline, :italic]))
        |> put_faint(attrs_map)
        |> put_hyperlink(hyperlink)

      {x, y, sanitize_char(char) || " ", style}
    end)
  end

  # A cell holds one glyph. A control byte here -- an in-cell \n, \e, \t -- would
  # under incremental rendering corrupt its row and bleed onto the next, and
  # unlike the old clear-every-frame path nothing repaints the victim row. Blank
  # it at the write boundary so the invalid cell is unrepresentable downstream.
  defp sanitize_char(<<c::utf8>>) when c < 0x20 or c == 0x7F, do: " "
  defp sanitize_char(char), do: char

  # Pull a tagged `{:hyperlink, url}` entry out of the cell attrs list; the
  # remaining entries are plain style atoms. Returns {url_or_nil, atoms}.
  defp split_hyperlink(attrs_list) do
    Enum.reduce(attrs_list, {nil, []}, fn
      {:hyperlink, url}, {_url, atoms} -> {url, atoms}
      other, {url, atoms} -> {url, [other | atoms]}
    end)
  end

  defp put_hyperlink(style, nil), do: style
  defp put_hyperlink(style, url), do: Map.put(style, :hyperlink, url)

  # The View-DSL attribute is `:dim`; the cell's `TextFormatting` field is
  # `:faint` (SGR 2's name). Without this translation the prominence
  # channel silently died at the buffer-write boundary: a `%{dim: true}`
  # element rendered, but `get_buffer` cell styles showed `faint: false`,
  # making buffer-level dim asserts (harness §7 prominence pins)
  # unfalsifiable. Pinned by the harness block demo headless tests.
  defp put_faint(style, %{dim: true}), do: Map.put(style, :faint, true)
  defp put_faint(style, _attrs_map), do: style
end
