defmodule Raxol.Harness.GuestBootPtyTest do
  @moduledoc """
  GUEST-BOOT end-to-end under a REAL kernel pty: a driver script prints
  10 shell-style lines (pre-existing screen content), starts
  `Raxol.Terminal.InlineDriver`, DSR-probes the cursor, and boots a
  `Raxol.Harness.Surface` with `boot: {:guest, pos}`. THIS TEST plays
  the terminal's half of the DSR round trip: it waits for `CSI 6n` in
  the pty capture and writes the CPR reply (`\\e[24;1R` -- prompt at the
  screen bottom, the normal shell) into the pty master.

  Asserted from the capture (byte oracle on the real wire):

    * the probe request is emitted exactly once;
    * the bottom-row reply takes the scroll-entry path: the surface is
      bottom-anchored from the first frame (`CSI 1;18r` claimed, footer
      painted in rows 19..24);
    * shell content is never repainted -- after the probe, no absolute
      CUP addresses any row above the content start (row 18);
    * the substrate law holds (`\\e[2J`/`\\e[3J` never emitted).

  Tagged like the other pty suites (`:skip_on_ci` -- real-pty timing on
  shared runners flakes in the kernel, not the assertions); run locally:

      mix test --include skip_on_ci --include pty test/harness/guest_boot_pty_test.exs

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

  defp write_driver_script!(dir) do
    path = Path.join(dir, "guest_boot_pty_driver.exs")

    File.write!(path, """
    alias Raxol.Harness.Surface
    alias Raxol.Terminal.InlineDriver
    alias Raxol.UI.Harness.InputEvent

    # Pre-existing screen content: what a shell session leaves behind.
    for i <- 1..10, do: IO.write("SHELL-LINE-\#{i}\\r\\n")
    IO.write("HARNESS-READY\\r\\n")

    {:ok, driver} =
      InlineDriver.start_link(
        subscriber: self(),
        device: :stdio,
        rows: 24,
        probe?: false,
        tty?: true
      )

    # The test process on the other side of the pty answers the probe;
    # give it a generous liveness bound (capture polling + scheduling).
    boot =
      case InlineDriver.probe_cursor(driver, budget_ms: 20_000) do
        {:ok, pos} -> {:guest, pos}
        {:error, _no_reply} -> :top
      end

    if boot == :top, do: Surface.startup_push_up(:stdio, 24)

    model =
      Surface.new([],
        device: :stdio,
        width: 80,
        rows: 24,
        footer_rows: 6,
        tty?: true,
        mode: :inline_log,
        pin: :adaptive,
        boot: boot
      )

    model = Surface.seal_marker(model, "GUEST-BOOT-SEALED")

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

  defp cup_rows_at_or_after(output, marker) do
    {at, _len} = :binary.match(output, marker)
    tail = binary_part(output, at, byte_size(output) - at)

    Regex.scan(~r/\e\[(\d{1,4});\d{1,4}H/, tail)
    |> Enum.map(fn [_all, row] -> String.to_integer(row) end)
  end

  test "bottom-prompt guest boot: probed once, bottom-anchored first frame, shell rows never re-addressed" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol_guest_boot_pty_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
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
        env: %{"MIX_ENV" => "test"}
      )

    on_exit(fn ->
      PtyHarness.stop(session)
      File.rm(session.capture_path)
      File.rm_rf!(dir)
    end)

    # mix startup under the pty can take a while on first load
    assert :ok = PtyHarness.await_capture(session, "HARNESS-READY", 60_000)

    # Play the terminal: wait for the DSR request, answer "prompt on the
    # bottom row" -- the normal shell launch state.
    assert :ok = PtyHarness.await_capture(session, "\e[6n", 30_000)
    assert :ok = PtyHarness.write(session, "\e[24;1R")

    # The surface booted and sealed its first history line.
    assert :ok = PtyHarness.await_capture(session, "GUEST-BOOT-SEALED", 30_000)

    # quit and drain to EOF (await is the capture-completeness barrier)
    assert :ok = PtyHarness.write(session, "q")
    assert {:ok, {:exit, 0}} = PtyHarness.await(session, 30_000)

    {:ok, output} = PtyHarness.read_output(session)

    # The shell content made it to the wire (and the CPR we injected is
    # INPUT -- it must never appear in the child's output).
    for i <- 1..10, do: assert(output =~ "SHELL-LINE-#{i}")
    refute output =~ "\e[24;1R"

    # Probe emitted exactly once, pre-first-paint by construction.
    assert length(:binary.matches(output, "\e[6n")) == 1

    # Bottom-anchored from the first frame: the scroll-entry path
    # claimed today's exact split for 24 rows / 6 footer rows.
    assert output =~ "\e[1;18r"

    # Shell rows are never re-addressed: from the probe on, every
    # absolute CUP stays at or below the content start (row 18) -- the
    # rows above hold the shell's own history, honestly scrolled, never
    # repainted. (The scan covers teardown too: its park at 24;1 is in
    # range.)
    rows = cup_rows_at_or_after(output, "\e[6n")
    assert rows != []
    assert Enum.min(rows) >= 18
    # ...and the footer really did paint in the bottom rows.
    assert Enum.max(rows) == 24

    # The substrate law held across the whole session.
    refute output =~ "\e[2J"
    refute output =~ "\e[3J"
  end
end
