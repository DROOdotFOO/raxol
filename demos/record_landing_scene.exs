# Records the axol.io landing hero scene to an 80x24 asciicast.
#
#   mix run demos/record_landing_scene.exs
#
# Drives Raxol.Demo.LandingScene (self-advancing) under a headless 80x24 session
# and repaints the full frame on each change. Writes demos/raxol-showcase.cast
# (asciicast v2, 80x24) -- the same filename the axol landing player loads.

alias Raxol.Core.Style
alias Raxol.Headless
alias Raxol.Recording.Recorder

width = 80
height = 24
out = "demos/raxol-showcase.cast"
session = :landing_rec
tick = 90

{:ok, _rec} =
  Recorder.start_link(
    title: "Raxol -- agent runtime for on-chain commerce",
    command: "mix run demos/record_landing_scene.exs",
    width: width,
    height: height,
    auto_save: out
  )

{:ok, _sess} =
  Headless.start(Raxol.Demo.LandingScene,
    id: session,
    width: width,
    height: height
  )

Recorder.record_output("\e[2J\e[H")

to_lines = fn screen ->
  lines =
    Enum.map(screen.cells, fn row ->
      cells =
        Enum.map(row, fn cell ->
          style = cell.style

          %{
            char: cell.char || " ",
            style: %{
              fg_color: style.foreground,
              bg_color: style.background,
              bold: style.bold,
              underline: style.underline,
              italic: style.italic
            }
          }
        end)

      %{cells: cells}
    end)

  %{width: screen.width, height: screen.height, lines: lines}
end

# Render one line style-aware: chunk consecutive cells by identical style and
# emit one SGR run each (with reset), so truecolor + underline + italic survive.
# (Renderer.render_diff/2 against a blank buffer collapses each row into a single
# run and keeps only the first cell's style, which strips all color -- the chunk
# below is what carries the axol palette and the link's underline/italic affordance.)
render_cells = fn cells ->
  cells
  |> Enum.chunk_by(& &1.style)
  |> Enum.map_join("", fn run ->
    text = Enum.map_join(run, "", & &1.char)

    case Style.to_ansi(hd(run).style) do
      "" -> text
      prefix -> prefix <> text <> Style.reset()
    end
  end)
end

# Absolute cursor move per line (no "\n", which would stair-step in playback).
render_frame = fn frame ->
  frame.lines
  |> Enum.with_index()
  |> Enum.map_join("", fn {line, y} ->
    "\e[#{y + 1};1H" <> render_cells.(line.cells)
  end)
end

# Full-frame repaint on each changed frame keeps phases from overlapping; only
# changed frames are recorded, so the cast stays small.
sample = fn prev ->
  case Headless.get_buffer(session) do
    {:ok, screen} ->
      frame = to_lines.(screen)

      if frame == prev do
        prev
      else
        Recorder.record_output("\e[2J\e[H" <> render_frame.(frame))
        frame
      end

    _ ->
      prev
  end
end

# nil sentinel: the first sampled frame (a map) never equals it, so it renders.
prev = nil

# The scene self-stops at ~13.5s, which tears down the session; halt sampling
# when the engine is gone rather than crashing on the next read.
_ =
  Enum.reduce_while(1..div(20_000, tick), prev, fn _i, acc ->
    Process.sleep(tick)

    try do
      {:cont, sample.(acc)}
    catch
      :exit, _ -> {:halt, acc}
    end
  end)

session_struct = Recorder.stop()

frames = Raxol.Recording.Session.event_count(session_struct)
duration = Raxol.Recording.Session.duration(session_struct)
size = File.stat!(out).size

IO.puts(
  "saved #{out}: #{frames} frames, #{Float.round(duration, 1)}s, #{size} bytes"
)
