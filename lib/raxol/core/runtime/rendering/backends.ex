defmodule Raxol.Core.Runtime.Rendering.Backends do
  @moduledoc """
  Rendering backend implementations for different output targets.

  Handles converting cells to output for terminal, VSCode, LiveView, and SSH backends.
  Extracted from `Raxol.Core.Runtime.Rendering.Engine` to keep rendering dispatch
  separate from the GenServer lifecycle.
  """

  require Raxol.Core.Runtime.Log

  alias Raxol.Terminal.ScreenBuffer

  # --- Backend Dispatch ---

  @doc """
  Renders cells to the terminal backend with ANSI output.
  """
  def render_to_terminal(cells, state) do
    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine: Executing render_to_terminal"
    )

    updated_buffer = apply_cells_to_buffer(cells, state)

    renderer = Raxol.Terminal.Renderer.new(updated_buffer)
    output_string = Raxol.Terminal.Renderer.render(renderer)

    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine: Terminal output generated (length: #{String.length(output_string)})"
    )

    # Move cursor to top-left and clear screen before each frame
    frame = "\e[H\e[2J" <> output_string

    if state.sync_output do
      IO.write("\e[?2026h")
      IO.write(frame)
      IO.write("\e[?2026l")
    else
      IO.write(frame)
    end

    # Send frame to recorder if active
    if pid = Process.whereis(Raxol.Recording.Recorder) do
      Raxol.Recording.Recorder.record_output(pid, frame)
    end

    {:ok, %{state | buffer: updated_buffer}}
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
  """
  @compile {:no_warn_undefined, [Raxol.LiveView.TerminalBridge, Phoenix.PubSub]}
  def render_to_liveview(cells, state, positioned_elements \\ []) do
    updated_buffer = apply_cells_to_buffer(cells, state)

    if Code.ensure_loaded?(Raxol.LiveView.TerminalBridge) do
      element_id_map = build_element_id_map(positioned_elements)

      html =
        Raxol.LiveView.TerminalBridge.buffer_to_html(updated_buffer,
          use_inline_styles: true,
          element_id_map: element_id_map
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

    renderer = Raxol.Terminal.Renderer.new(updated_buffer)
    output_string = Raxol.Terminal.Renderer.render(renderer)

    # Home cursor and clear screen before each frame, matching render_to_terminal
    frame = "\e[H\e[2J" <> output_string

    write_output(state.io_writer, frame, state.sync_output)

    {:ok, %{state | buffer: updated_buffer}}
  end

  # --- Output Helpers ---

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

  A new buffer is created each frame so stale cells from previous views don't persist.
  """
  def apply_cells_to_buffer(cells, state) do
    screen_buffer = ScreenBuffer.new(state.width, state.height)
    transformed_cells = transform_cells_for_update(cells)

    Enum.reduce(transformed_cells, screen_buffer, fn {x, y, cell}, buffer ->
      style = extract_cell_style(cell)
      ScreenBuffer.write_char(buffer, x, y, cell.char || " ", style)
    end)
  end

  @doc false
  def extract_cell_style(cell) do
    case Map.get(cell, :style) do
      nil ->
        %{
          foreground: Map.get(cell, :foreground),
          background: Map.get(cell, :background)
        }

      cell_style when is_map(cell_style) ->
        cell_style

      _ ->
        nil
    end
  end

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

  defp transform_cells_for_update(cells) when is_list(cells) do
    Enum.map(cells, fn {x, y, char, fg, bg, attrs_list} ->
      {hyperlink, style_atoms} = split_hyperlink(attrs_list || [])
      attrs_map = Enum.into(style_atoms, %{}, fn atom -> {atom, true} end)

      cell_attrs =
        %{
          foreground: fg,
          background: bg
        }
        |> Map.merge(Map.take(attrs_map, [:bold, :underline, :italic]))
        |> put_hyperlink(hyperlink)

      cell = %Raxol.Terminal.Cell{char: char, style: cell_attrs}
      {x, y, cell}
    end)
  end

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
end
