defmodule Raxol.Terminal.DriverInitOrderTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Writing the OSC 11 background query before `start_stdin_reader/1` races
  the prim_tty `tty => false` -> `tty => true` reinit that
  `start_stdin_reader/1` triggers via `user_drv`'s `:start_shell` call; under
  a real TTY that race can corrupt job control and crash the node before a
  frame renders.

  This lives entirely in `init_manager/1`'s TTY-detected branch, which is
  unreachable from ExUnit (`Env.test?/0` short-circuits before that branch
  runs, and there is no real TTY in CI). These tests assert the invariants
  directly against the source instead of driving the GenServer.
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

  # `start_stdin_reader/1`'s `:start_shell` call must pass the literal atom
  # `:noshell`, never an MFA. Any other value makes user_drv spawn a real
  # shell process that, if it exits immediately, drops user_drv into its JCL
  # prompt and hijacks all subsequent stdin. Unreachable from ExUnit for the
  # same reason as the test above, so it's asserted against the source.
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
