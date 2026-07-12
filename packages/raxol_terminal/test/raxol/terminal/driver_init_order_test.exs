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

  # Second regression: `start_stdin_reader/1`'s `:start_shell` call must
  # pass the literal atom `:noshell`, never an MFA — even a no-op one that
  # returns immediately. Any non-`:noshell` value makes user_drv spawn a
  # real shell process via `group:start/3`. If that process exits right
  # away (as a no-op MFA shell does), user_drv prints "*** ERROR: Shell
  # process terminated! ***" and drops into its JCL "User switch command
  # -->" prompt for the rest of the session — every subsequent byte read
  # from stdin, including the terminal's own reply to our OSC 11 / DA
  # startup query, gets interpreted as a job-control command instead of
  # reaching our trace, and the JCL handler killing/reassigning stdio
  # crashes the whole node before a frame ever renders. This is
  # unreachable from ExUnit for the same reason as the ordering test above
  # (no real TTY in CI), so it's asserted directly against the source.
  test "start_stdin_reader's :start_shell call uses :noshell, not a shell MFA" do
    source = File.read!(@driver_source)

    # Anchor on the tuple construction itself, not just the atom — ":start_shell"
    # alone also appears earlier in explanatory comments.
    {start_shell_index, _len} = :binary.match(source, "{:start_shell,")

    # Grab a window of source after the :start_shell call site — enough to
    # contain the Args map literal — and confirm it pins `initial_shell` to
    # the atom :noshell rather than any other value (MFA tuple, module
    # capture, etc).
    window = binary_part(source, start_shell_index, 200)

    assert window =~ ~r/initial_shell:\s*:noshell/,
           "start_stdin_reader/1's {:start_shell, Args} call must set " <>
             "initial_shell: :noshell literally. Any other value (including a " <>
             "custom no-op shell MFA) makes user_drv spawn a real shell process " <>
             "that immediately exits, triggering the JCL 'User switch command' " <>
             "prompt and hijacking all subsequent stdin — including the terminal's " <>
             "OSC 11 / DA reply — which crashes the node. See the comment on " <>
             "start_stdin_reader/1 in driver.ex for the full mechanism."

    refute source =~ "noop_shell",
           "noop_shell/0 should no longer exist — it was the MFA shell that " <>
             "caused the JCL hijack described above. If you're reintroducing a " <>
             "custom shell MFA, re-read the comment on start_stdin_reader/1 first."
  end
end
