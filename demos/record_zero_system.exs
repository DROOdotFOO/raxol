# Records the ZERO System cockpit to an 80x24 asciicast for the axol.io hero.
#
# Drives the deterministic mock-AI path through its beats -- boot self-check,
# swarm funnel deploy, private cross-chain settlement with streaming reasoning,
# crash-mid-settlement resume -- and samples the rendered buffer at tick cadence,
# encoding each frame diff as terminal output.
#
#   RAXOL_FLIGHT_INSPECT=1 mix run demos/record_zero_system.exs
#
# Writes demos/zero_system.cast (asciicast v2, 80x24). RAXOL_FLIGHT_INSPECT skips
# the cockpit's own interactive boot so this script owns the session.

alias Raxol.Core.Buffer
alias Raxol.Core.Renderer
alias Raxol.Headless
alias Raxol.Recording.Recorder

Code.require_file("examples/agents/zero_system.exs")
Process.sleep(200)

# The cockpit's two side-by-side panels are 44 + 50 cols plus gap and padding
# (~97), and the reasoning text wraps at 86, so it needs ~100 cols. A narrower
# capture clips the panels and wraps text off the edges.
width = 100
height = 32
out = "demos/zero_system.cast"
session = :zero_rec
tick = 100

{:ok, _rec} =
  Recorder.start_link(
    title: "RAXOL // ZERO SYSTEM",
    command: "mix run demos/record_zero_system.exs",
    width: width,
    height: height,
    auto_save: out
  )

{:ok, _sess} = Headless.start(ZeroSystem, id: session, width: width, height: height)

# Start the player on a cleared screen.
Recorder.record_output("\e[2J\e[H")

# The engine returns a Raxol.Terminal.ScreenBuffer (cells: [[%Cell{}]]); the
# Core.Renderer diff wants lines of cells with a flat style map.
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

# Repaint the whole frame each time it changes. The cockpit's phases (boot ->
# cockpit) have different layouts, so an incremental diff would leave the prior
# phase's text on screen; a full clear + repaint keeps frames from overlapping.
# Only changed frames are recorded, so the cast stays small.
blank = Buffer.create_blank_buffer(width, height)

sample = fn prev ->
  case Headless.get_buffer(session) do
    {:ok, screen} ->
      frame = to_lines.(screen)

      if frame == prev do
        prev
      else
        ansi = blank |> then(&Renderer.render_diff(&1, frame)) |> Renderer.apply_diff()
        Recorder.record_output("\e[2J\e[H" <> ansi)
        frame
      end

    _ ->
      prev
  end
end

play = fn prev, ms ->
  Enum.reduce(1..div(ms, tick), prev, fn _i, acc ->
    Process.sleep(tick)
    sample.(acc)
  end)
end

prev = blank

# boot self-check -> swarm funnel deploy -> ready
prev = play.(prev, 4500)

# settle: sign + dispatch the private cross-chain intent, stream the reasoning
Headless.send_key(session, "s")
prev = play.(prev, 4500)

# crash mid-settlement: the checkpoint holds, the resume settles to one debit
Headless.send_key(session, "x")
prev = play.(prev, 3200)

# hold the reconciled ledger
_prev = play.(prev, 2200)

session_struct = Recorder.stop()

frames = Raxol.Recording.Session.event_count(session_struct)
duration = Raxol.Recording.Session.duration(session_struct)
size = File.stat!(out).size

IO.puts("saved #{out}: #{frames} frames, #{Float.round(duration, 1)}s, #{size} bytes")
