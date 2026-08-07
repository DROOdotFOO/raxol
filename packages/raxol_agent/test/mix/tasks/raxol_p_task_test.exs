defmodule Mix.Tasks.Raxol.PTaskTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # Flag-surface tests only: nothing here runs a turn. The mix task is a
  # thin shell over `Raxol.Agent.P` and always exits with its return code,
  # so every path is asserted via catch_exit.

  test "--help prints usage on stdout and exits 0" do
    out =
      capture_io(fn ->
        assert catch_exit(Mix.Tasks.Raxol.P.run(["--help"])) == {:shutdown, 0}
      end)

    assert out =~ "Usage: raxol p"
    assert out =~ "--backend"
    assert out =~ "--write"
    assert out =~ "Exit codes:"
  end

  test "-h is an alias for --help" do
    out =
      capture_io(fn ->
        assert catch_exit(Mix.Tasks.Raxol.P.run(["-h"])) == {:shutdown, 0}
      end)

    assert out =~ "Usage: raxol p"
  end

  test "an unknown option prints the error plus usage and exits 64" do
    stderr =
      capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Raxol.P.run(["--bogus", "hi"])) ==
                 {:shutdown, 64}
      end)

    assert stderr =~ ~s(unknown options: [{"--bogus", nil}])
    assert stderr =~ "Usage: raxol p"
  end

  test "a missing prompt prints the error plus usage and exits 64" do
    stderr =
      capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Raxol.P.run([])) == {:shutdown, 64}
      end)

    assert stderr =~ "no prompt given"
    assert stderr =~ "Usage: raxol p"
  end
end
