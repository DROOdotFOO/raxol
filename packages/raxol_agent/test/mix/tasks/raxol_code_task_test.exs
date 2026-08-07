defmodule Mix.Tasks.Raxol.CodeTaskTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # Flag-surface tests only: nothing here boots the app or launches the TUI.
  # The mix task is a thin shell over `Raxol.Agent.Code.Launcher` and always
  # exits with its return code; the launcher answers `--help`/usage errors
  # before the injected boot step runs.

  test "--help prints usage on stdout and exits 0" do
    out =
      capture_io(fn ->
        assert catch_exit(Mix.Tasks.Raxol.Code.run(["--help"])) ==
                 {:shutdown, 0}
      end)

    assert out =~ "Usage: raxol code"
    assert out =~ "--backend"
    assert out =~ "--resume ID"
    assert out =~ "--sessions"
  end

  test "-h is an alias for --help" do
    out =
      capture_io(fn ->
        assert catch_exit(Mix.Tasks.Raxol.Code.run(["-h"])) == {:shutdown, 0}
      end)

    assert out =~ "Usage: raxol code"
  end

  test "an unknown option prints the error plus usage and exits 64" do
    stderr =
      capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Raxol.Code.run(["--bogus"])) ==
                 {:shutdown, 64}
      end)

    assert stderr =~ ~s(unknown options: [{"--bogus", nil}])
    assert stderr =~ "Usage: raxol code"
  end

  test "--help wins over an unknown option" do
    out =
      capture_io(fn ->
        assert catch_exit(Mix.Tasks.Raxol.Code.run(["--help", "--bogus"])) ==
                 {:shutdown, 0}
      end)

    assert out =~ "Usage: raxol code"
  end

  test "an unknown backend errors fast, before the app boots" do
    stderr =
      capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Raxol.Code.run(["--backend", "nonsense"])) ==
                 {:shutdown, 64}
      end)

    assert stderr =~ ~s(unknown backend "nonsense")
    assert stderr =~ "supported:"
  end
end
