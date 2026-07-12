defmodule Raxol.Terminal.DriverInitOrderTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Regression test for a startup crash: writing the OSC 11 background query
  (`IO.write(BackgroundQuery.query_sequence())`) *before* `start_stdin_reader/1`
  raced the prim_tty `tty => false` -> `tty => true` reinit that
  `start_stdin_reader/1` triggers via `user_drv`'s `:start_shell` call. Under
  a real TTY (and reliably under a PTY harness, e.g. `expect`/`script`), that
  race corrupted job control and crashed the whole BEAM node before a single
  frame rendered — the "device has terminated" error the user saw in
  `TermboxLifecycle.cleanup_terminal/1` was a downstream symptom of stdio
  already being dead, not the root cause.

  This class of bug lives entirely in `init_manager/1`'s TTY-detected branch,
  which is unreachable from ExUnit (`Env.test?/0` short-circuits before that
  branch runs, and there is no real TTY in CI), so the failure can't be
  reproduced by driving the GenServer in-process. Instead, this test asserts
  the ordering invariant directly against the source: the OSC 11 query must
  never be written before the stdin reader is activated.
  """

  @driver_source Path.join([
                   Path.dirname(__ENV__.file),
                   "..",
                   "..",
                   "..",
                   "lib",
                   "raxol",
                   "terminal",
                   "driver.ex"
                 ])
                 |> Path.expand()

  test "OSC 11 background query is written after the stdin reader is activated" do
    source = File.read!(@driver_source)

    reader_index =
      :binary.match(source, "start_stdin_reader(self())")
      |> elem(0)

    query_write_index =
      case :binary.match(source, "write_background_query()") do
        {index, _len} ->
          index

        :nomatch ->
          # Fall back to the raw IO.write call in case the helper is
          # inlined again in the future — either way, it must come after.
          {index, _len} =
            :binary.match(source, "BackgroundQuery.query_sequence()")

          index
      end

    assert query_write_index > reader_index,
           "The OSC 11 background query must be written after start_stdin_reader/1 " <>
             "activates the prim_tty reader. Writing it earlier races the tty reinit " <>
             "and can crash the whole node on startup under a real terminal (see " <>
             "commit history around the H-K salience / OSC 11 background detection merge)."
  end
end
