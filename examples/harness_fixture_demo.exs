# Harness fixture demo (the assembled harness — golden-fixture assembly).
#
# Runs the assembled `Raxol.Harness.Surface` against a golden fixture
# session, replayed on a real tty: blocks seal into native scrollback one
# event at a time, the status strip + composer stay pinned in the footer,
# and `z`/`j`/`k` (fold/jump) + Tab (steer stub) + ESC (interrupt stub)
# work via the real `Raxol.Terminal.InlineDriver` raw-mode input
# path -- the same canonical event route `Raxol.UI.Harness.Keymap`
# resolves in production.
#
# Usage (run from the repo root, or this worktree's root):
#
#   mix run --no-start examples/harness_fixture_demo.exs
#   mix run --no-start examples/harness_fixture_demo.exs multi-tool-turn
#   mix run --no-start examples/harness_fixture_demo.exs simple-chat --speed 250
#
# `--no-start` avoids interleaving `:raxol` application boot logs into the
# byte stream -- InlineAuthority and Surface are plain modules, no
# supervision tree required.
#
# Keys while running: `z` fold/unfold the focused block, `j`/`k` move
# focus (once off the composer -- see `Surface.focus_transcript/1`), `Tab`
# queues a steer stub, `Ctrl-E` opens the composer draft in $VISUAL/$EDITOR
# (the harness suspends its terminal claim while the editor owns the tty,
# then resumes and reloads the edited draft -- see
# `Raxol.Harness.EditorSession`), `Esc` shows an interrupt stub (no agent lane in
# fixture mode -- see `Raxol.Harness.Surface`'s moduledoc, precondition
# #6), `q` quits cleanly WHEN THE COMPOSER BUFFER IS EMPTY (Ctrl-C does
# not: raw mode disables SIGINT delivery, per `Raxol.Terminal.InlineDriver`'s
# own moduledoc) -- a non-empty buffer means `q` is just a character the
# composer is focused to receive, same as any other letter; quitting mid-
# typed-message on that same keystroke silently ate every "q" that would
# ever end up in a prompt (see `loop/3`/`linger/3` below, both call sites).

alias Raxol.Harness.{Fixture, Surface}
alias Raxol.Terminal.InlineDriver
alias Raxol.UI.Components.Harness.Composer
alias Raxol.UI.Harness.InputEvent

defmodule Raxol.Examples.HarnessFixtureDemo do
  @moduledoc false

  @default_fixture "simple-chat"
  @default_speed_ms 500
  @footer_rows 6
  @post_done_linger_ms 15_000

  def run(argv) do
    {fixture_name, speed_ms} = parse_args(argv)
    path = fixture_path(fixture_name)

    session =
      case Fixture.load(path) do
        {:ok, session} ->
          session

        {:error, reason} ->
          IO.puts(:stderr, "failed to load fixture #{path}: #{inspect(reason)}")
          System.halt(1)
      end

    {width, rows} = geometry()
    tty? = Raxol.Terminal.TerminalUtils.has_terminal_device?()

    # The driver's raw-mode + real key-event input path -- until the
    # assembled harness wires the real Dispatcher, this seam is the whole
    # contract (InlineDriver's own moduledoc). `subscriber: self()` routes every
    # parsed keypress here as `{:inline_input, %Event{}}`. Same `tty?`
    # fact both InlineDriver AND Surface's own `ModeSelect.select/3` pick
    # (a non-tty run -- piped/CI -- degrades InlineDriver's stty/reader
    # AND Surface's own render mode consistently to :flat, never one
    # without the other).
    {:ok, driver_pid} =
      InlineDriver.start_link(
        subscriber: self(),
        device: :stdio,
        rows: rows,
        probe?: false,
        tty?: tty?
      )

    # GUEST-BOOT: ask the terminal where the shell left the cursor
    # (`CSI 6n`; the CPR reply is consumed inside the driver and never
    # reaches this process's input stream). On a reply the surface
    # starts exactly there -- floating under the prompt, or
    # bottom-anchored from the first frame when the prompt sits near
    # the screen bottom (the normal shell). No reply (pipe, dumb
    # terminal): honest fallback to the top boot, sealed as a line
    # below so the record says why.
    boot =
      case InlineDriver.probe_cursor(driver_pid) do
        {:ok, pos} -> {:guest, pos}
        {:error, _no_reply} -> :top
      end

    # Startup discipline (:top boot only): push whatever is currently
    # on screen up into scrollback via plain newlines -- never `\e[2J`.
    # A guest boot starts at the prompt instead -- pushing first would
    # move the cursor out from under the probed position.
    if boot == :top, do: Surface.startup_push_up(:stdio, rows)

    model =
      Surface.new(session,
        device: :stdio,
        width: width,
        rows: rows,
        footer_rows: @footer_rows,
        tty?: tty?,
        # FOOTER-FOLLOWS-CONTENT: start with the footer floating directly
        # below the (empty) history instead of claiming the whole screen
        # -- it pins itself at the bottom once content reaches it.
        pin: :adaptive,
        boot: boot,
        # Ctrl-E hands the composer draft to $VISUAL/$EDITOR (real tty
        # runs only -- a piped/CI run has no terminal to hand over, and
        # Surface renders its honest stub notice instead).
        editor_session: if(tty?, do: Raxol.Harness.EditorSession)
      )

    model =
      case boot do
        {:guest, _pos} ->
          model

        :top ->
          Surface.seal_marker(
            model,
            "» cursor probe: no reply — starting at top"
          )
      end

    try do
      loop(model, driver_pid, speed_ms)
    after
      GenServer.stop(driver_pid, :normal)
    end
  end

  defp loop(model, driver_pid, speed_ms) do
    receive do
      {:inline_input, event} ->
        norm = InputEvent.normalize(event)

        if quit_key?(norm, model) do
          :ok
        else
          model |> Surface.handle_input(event) |> loop(driver_pid, speed_ms)
        end
    after
      speed_ms ->
        case Surface.advance(model, System.monotonic_time(:millisecond)) do
          {model, :ok} -> loop(model, driver_pid, speed_ms)
          {model, :done} -> linger(model, driver_pid)
        end
    end
  end

  # Fixture fully replayed: keep the elapsed ticker honest and keep
  # listening for fold/jump/quit for a while before exiting on its own,
  # rather than snapping the terminal away the instant the last block
  # seals.
  defp linger(model, driver_pid, remaining_ms \\ @post_done_linger_ms)

  defp linger(_model, _driver_pid, remaining_ms) when remaining_ms <= 0, do: :ok

  defp linger(model, driver_pid, remaining_ms) do
    tick_ms = 1_000

    receive do
      {:inline_input, event} ->
        norm = InputEvent.normalize(event)

        if quit_key?(norm, model) do
          :ok
        else
          model
          |> Surface.handle_input(event)
          |> linger(driver_pid, remaining_ms)
        end
    after
      tick_ms ->
        model
        |> Surface.tick(System.monotonic_time(:millisecond))
        |> linger(driver_pid, remaining_ms - tick_ms)
    end
  end

  # `q` quits ONLY while the composer buffer is empty -- otherwise it is
  # just a character the focused composer is entitled to receive, same as
  # any other letter (a message that legitimately contains "q" could never
  # be typed before this fix: the very first "q" keystroke of ANY prompt
  # exited the demo, at both call sites above, before `Surface.handle_input/2`
  # ever saw it).
  defp quit_key?(norm, model) do
    InputEvent.printable_char(norm) == "q" and
      String.trim(Composer.value(model.composer)) == ""
  end

  defp parse_args(argv) do
    {opts, positional, _invalid} =
      OptionParser.parse(argv, strict: [speed: :integer])

    fixture_name = List.first(positional, @default_fixture)
    speed_ms = Keyword.get(opts, :speed, @default_speed_ms)
    {fixture_name, speed_ms}
  end

  defp fixture_path(name) do
    Path.join(["test", "fixtures", "harness", "sessions", "#{name}.jsonl"])
  end

  defp geometry do
    width =
      case :io.columns() do
        {:ok, cols} -> cols
        _ -> 80
      end

    rows =
      case :io.rows() do
        {:ok, rows} -> rows
        _ -> 24
      end

    {width, rows}
  end
end

Raxol.Examples.HarnessFixtureDemo.run(System.argv())
