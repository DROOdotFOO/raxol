defmodule Raxol.Harness.EditorPtyTest do
  @moduledoc """
  Full editor-handoff round trip under a REAL kernel pty: a harness
  driver (InlineDriver + Surface + the real EditorSession) runs under
  `Raxol.Test.PtyHarness`, Ctrl-E is injected as the raw 0x05 byte, a
  fake `$EDITOR` (a shell script appending a marker to the draft file)
  takes the tty, and the resumed harness repaints the composer with the
  edited draft.

  This is the tier reserved for facts a pure byte-capture cannot
  observe: the reader gate against the real prim_tty reader, `/dev/tty`
  stty transitions, and a real child process inheriting the pty via
  `:nouse_stdio`. Tagged `:skip_on_ci` (same rationale as the pty smoke
  suite: real-pty timing on shared CI runners flakes in the
  kernel/runner, not in the assertions) -- run locally with

      mix test --include skip_on_ci --include pty test/harness/editor_pty_test.exs

  Skips cleanly when `python3` is absent.
  """

  use ExUnit.Case, async: false

  alias Raxol.Test.PtyHarness

  @moduletag :pty
  @moduletag :unix_only
  @moduletag :skip_on_ci
  @moduletag timeout: 120_000

  setup_all do
    if PtyHarness.available?() do
      :ok
    else
      {:skip, "python3 not found on PATH"}
    end
  end

  # `stty -a` renders modes as bare tokens when set, minus-prefixed when
  # clear; exact token membership avoids the substring trap.
  defp stty_tokens(output), do: String.split(output, ~r/[\s;]+/, trim: true)

  defp write_fake_editor!(dir) do
    path = Path.join(dir, "fake_editor.sh")

    File.write!(path, """
    #!/bin/sh
    printf 'EDITED-BY-FAKE' >> "$1"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A minimal real-tty driver: InlineDriver raw input -> Surface with the
  # REAL EditorSession wired. Prints a READY sentinel once armed; quits on
  # a plain "q".
  defp write_driver_script!(dir) do
    path = Path.join(dir, "editor_pty_driver.exs")

    File.write!(path, """
    alias Raxol.Harness.Surface
    alias Raxol.UI.Harness.InputEvent

    {:ok, driver} =
      Raxol.Terminal.InlineDriver.start_link(
        subscriber: self(),
        device: :stdio,
        rows: 24,
        probe?: false,
        tty?: true
      )

    IO.write(:stdio, "HARNESS-READY\\r\\n")

    Surface.startup_push_up(:stdio, 24)

    model =
      Surface.new([],
        device: :stdio,
        width: 80,
        rows: 24,
        footer_rows: 6,
        tty?: true,
        mode: :inline_log,
        editor_session: Raxol.Harness.EditorSession
      )

    loop = fn loop, model ->
      receive do
        {:inline_input, event} ->
          norm = InputEvent.normalize(event)

          if InputEvent.printable_char(norm) == "q" do
            :ok
          else
            loop.(loop, Surface.handle_input(model, event))
          end
      after
        60_000 -> :ok
      end
    end

    loop.(loop, model)
    GenServer.stop(driver, :normal)
    """)

    path
  end

  test "Ctrl-E: suspend releases the region, the fake editor edits the draft, resume re-pins and repaints" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol_editor_pty_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    fake_editor = write_fake_editor!(dir)
    driver_script = write_driver_script!(dir)
    repo_root = File.cwd!()

    {:ok, session} =
      PtyHarness.start(
        [
          "sh",
          "-c",
          "cd '#{repo_root}' && exec mix run --no-start '#{driver_script}'"
        ],
        winsize: {24, 80},
        env: %{
          "EDITOR" => fake_editor,
          "VISUAL" => "",
          "MIX_ENV" => "test"
        }
      )

    on_exit(fn ->
      PtyHarness.stop(session)
      File.rm(session.capture_path)
      File.rm_rf!(dir)
    end)

    # mix startup under the pty can take a while on first load
    assert :ok = PtyHarness.await_capture(session, "HARNESS-READY", 60_000)

    # Ctrl-E: the raw 0x05 byte, exactly what a terminal sends
    assert :ok = PtyHarness.write(session, <<5>>)

    # the edited draft must come back through the resumed footer keyframe
    assert :ok = PtyHarness.await_capture(session, "EDITED-BY-FAKE", 30_000)

    # quit and drain to EOF (await is the capture-completeness barrier)
    assert :ok = PtyHarness.write(session, "q")
    assert {:ok, {:exit, 0}} = PtyHarness.await(session, 30_000)

    {:ok, output} = PtyHarness.read_output(session)

    # suspend released the region...
    assert output =~ "\e[r"
    # ...and resume re-pinned it (80x24, 6-row footer -> CSI 1;18r). The
    # pin appears at startup AND again after resume: at least twice.
    pin_matches = :binary.matches(output, "\e[1;18r")
    assert length(pin_matches) >= 2

    # the resume re-pin comes AFTER the suspend release
    {first_release, _} = :binary.match(output, "\e[r")
    {last_pin, _} = List.last(pin_matches)
    assert last_pin > first_release

    # the substrate law held across the whole session
    refute output =~ "\e[2J"
    refute output =~ "\e[3J"

    # post-mortem: the driver's teardown restored a cooked line
    # discipline (icanon as a bare token, not "-icanon")
    assert {:ok, stty_output} = PtyHarness.post_mortem(session)
    assert "icanon" in stty_tokens(stty_output)
  end
end
