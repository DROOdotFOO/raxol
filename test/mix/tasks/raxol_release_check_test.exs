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
end
