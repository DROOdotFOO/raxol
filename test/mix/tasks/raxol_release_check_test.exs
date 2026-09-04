defmodule Mix.Tasks.Raxol.Release.CheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("raxol.release.check")
    :ok
  end

  test "metadata-only package selection passes without running Hex builds" do
    output =
      capture_io(fn ->
        Mix.Tasks.Raxol.Release.Check.run([
          "--metadata-only",
          "--only",
          "raxol_core"
        ])
      end)

    assert output =~ "package release check: 1 package(s)"
    # Matched loosely on purpose: pinning the version here turns every
    # raxol_core release into an unrelated test failure.
    assert output =~ ~r/\[ok\] raxol_core \d+\.\d+\.\d+ metadata/
    assert output =~ "package release check passed"
  end

  test "unknown packages fail before any build" do
    capture_io(:stderr, fn ->
      assert_raise Mix.Error, ~r/package release check failed/, fn ->
        capture_io(fn ->
          Mix.Tasks.Raxol.Release.Check.run([
            "--metadata-only",
            "--only",
            "not_a_package"
          ])
        end)
      end
    end)
  end

  test "a pre-alpha package name is rejected with an --all hint" do
    stderr =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Mix.Tasks.Raxol.Release.Check.run([
              "--metadata-only",
              "--only",
              "raxol_symphony"
            ])
          end)
        end
      end)

    assert stderr =~ "pass --all"
  end

  test "rejects an unknown switch instead of ignoring it" do
    assert_raise Mix.Error, ~r/invalid option/, fn ->
      Mix.Tasks.Raxol.Release.Check.run(["--publish"])
    end
  end

  # The documented publish workflow is `HEX_BUILD=1 mix hex.publish`, so reaching
  # for `HEX_BUILD=1 mix raxol.release.check` is the natural mistake. Left alone
  # it takes raxol_core off the code path and dies inside Boundary.Path with an
  # error that names nothing relevant.
  test "refuses to run under an ambient HEX_BUILD" do
    previous = System.get_env("HEX_BUILD")
    System.put_env("HEX_BUILD", "1")

    on_exit(fn ->
      if previous,
        do: System.put_env("HEX_BUILD", previous),
        else: System.delete_env("HEX_BUILD")
    end)

    assert_raise Mix.Error, ~r/HEX_BUILD is set in this environment/, fn ->
      Mix.Tasks.Raxol.Release.Check.run(["--metadata-only"])
    end
  end
end
