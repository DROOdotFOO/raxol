defmodule Mix.Tasks.Raxol.CodeTaskTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # Flag-surface tests only: nothing here boots the app or launches the TUI.
  # `--help` returns before `launch/1`; unknown options exit before it.

  test "--help prints usage on stdout and exits 0" do
    out = capture_io(fn -> assert :ok = Mix.Tasks.Raxol.Code.run(["--help"]) end)

    assert out =~ "Usage: mix raxol.code"
    assert out =~ "--backend"
    assert out =~ "--resume ID"
    assert out =~ "--sessions"
  end

  test "-h is an alias for --help" do
    out = capture_io(fn -> assert :ok = Mix.Tasks.Raxol.Code.run(["-h"]) end)
    assert out =~ "Usage: mix raxol.code"
  end

  test "an unknown option prints the error plus usage and exits 64" do
    stderr =
      capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Raxol.Code.run(["--bogus"])) ==
                 {:shutdown, 64}
      end)

    assert stderr =~ ~s(unknown options: [{"--bogus", nil}])
    assert stderr =~ "Usage: mix raxol.code"
  end

  test "--help wins over an unknown option" do
    out =
      capture_io(fn ->
        assert :ok = Mix.Tasks.Raxol.Code.run(["--help", "--bogus"])
      end)

    assert out =~ "Usage: mix raxol.code"
  end

  test "an unknown backend errors fast, before the app boots" do
    stderr =
      capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Raxol.Code.run(["--backend", "nonsense"])) == {:shutdown, 64}
      end)

    assert stderr =~ ~s(unknown backend "nonsense")
    assert stderr =~ "supported:"
  end
end
