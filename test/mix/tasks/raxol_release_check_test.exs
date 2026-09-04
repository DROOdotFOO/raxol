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
    assert output =~ "[ok] raxol_core 2.6.0 metadata"
    assert output =~ "package release check passed"
  end

  test "unknown packages fail before any build" do
    assert_raise Mix.Error, ~r/package release check failed/, fn ->
      capture_io(:stderr, fn ->
        Mix.Tasks.Raxol.Release.Check.run([
          "--metadata-only",
          "--only",
          "not_a_package"
        ])
      end)
    end
  end
end
