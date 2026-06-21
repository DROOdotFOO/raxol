# Records the axol.io landing hero scene to an 80x24 asciicast.
#
#   mix run demos/record_landing_scene.exs
#
# Drives Raxol.Demo.LandingScene (self-advancing) under a headless 80x24 session
# and repaints the full frame on each change. Writes demos/raxol-showcase.cast
# (asciicast v2, 80x24) -- the same filename the axol landing player loads.

alias Raxol.Core.Buffer
alias Raxol.Core.Renderer
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
              bold: style.bold
            }
          }
        end)

      %{cells: cells}
    end)

  %{width: screen.width, height: screen.height, lines: lines}
end

blank = Buffer.create_blank_buffer(width, height)

# Full-frame repaint on each changed frame keeps phases from overlapping; only
# changed frames are recorded, so the cast stays small.
sample = fn prev ->
  case Headless.get_buffer(session) do
    {:ok, screen} ->
      frame = to_lines.(screen)

      if frame == prev do
        prev
      else
        ansi =
          blank
          |> then(&Renderer.render_diff(&1, frame))
          |> Renderer.apply_diff()

        Recorder.record_output("\e[2J\e[H" <> ansi)
        frame
      end

    _ ->
      prev
  end
end

# The scene self-stops at ~26s; sample a touch longer to catch the final frame.
prev = blank

_ =
  Enum.reduce(1..div(28_000, tick), prev, fn _i, acc ->
    Process.sleep(tick)
    sample.(acc)
  end)

session_struct = Recorder.stop()

frames = Raxol.Recording.Session.event_count(session_struct)
duration = Raxol.Recording.Session.duration(session_struct)
size = File.stat!(out).size

IO.puts(
  "saved #{out}: #{frames} frames, #{Float.round(duration, 1)}s, #{size} bytes"
)
