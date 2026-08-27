defmodule Githooks.PreCommitTest do
  @moduledoc """
  The pre-commit hook puts a directory on `PATH` and then runs `mix` and
  `elixir` from it, and it picks that directory using a value read out of
  `.tool-versions` -- a file the repository controls, and therefore a file any
  branch controls.

  That makes the version string untrusted input to a path that becomes
  executable search order, so it gets a test. Checking out someone else's branch
  and committing is an ordinary thing to do.

  The hook's own text is the subject: the toolchain block is extracted from
  `.githooks/pre-commit` and run, rather than restated here, so this cannot pass
  against a hook that no longer says what it says.
  """
  use ExUnit.Case, async: true

  @moduletag :unix_only

  @hook Path.expand("../../.githooks/pre-commit", __DIR__)

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol-hook-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # Everything from the toolchain header up to the first gate. Bounded by what
  # follows it rather than by a line count, so an edit inside the block does not
  # silently shrink what is under test.
  defp toolchain_block do
    source = File.read!(@hook)

    [_, block] =
      Regex.run(~r/(# --- toolchain.*?)\nstaged=/s, source) ||
        flunk("could not find the toolchain block in #{@hook}")

    block
  end

  # Runs the block with `cwd` as the repo and `mise_root` standing in for the
  # mise data dir, and returns the PATH it produced.
  defp resulting_path(cwd, mise_root, extra_env \\ []) do
    script = """
    set -euo pipefail
    cd #{cwd}
    #{toolchain_block()}
    printf '%s' "$PATH"
    """

    {out, 0} =
      System.cmd("bash", ["-c", script],
        env:
          [
            {"MISE_DATA_DIR", mise_root},
            {"PATH", "/usr/bin:/bin"},
            # Cleared explicitly. `System.cmd` MERGES with the caller's
            # environment rather than replacing it, so a developer who has the
            # escape hatch exported would otherwise turn every assertion below
            # into a no-op that still passes.
            {"RAXOL_HOOK_NO_TOOLCHAIN", nil}
          ] ++ extra_env,
        stderr_to_stdout: true
      )

    out
  end

  defp write_tool_versions(dir, elixir_version) do
    File.write!(dir, "erlang 29.0.3\nelixir #{elixir_version}\nnodejs latest\n")
  end

  describe "the toolchain block" do
    test "refuses a version that traverses out of the mise root", %{dir: dir} do
      # The exploit, verbatim: `<mise>/installs/elixir/<version>/bin` with a
      # `..`-laden version resolves to an attacker-chosen directory.
      escape = Path.join(dir, "escape")
      File.mkdir_p!(Path.join(escape, "bin"))

      repo = Path.join(dir, "repo")
      mise = Path.join(dir, "mise")
      File.mkdir_p!(repo)

      # The version is interpolated after this, so the climb starts here -- and
      # it has to EXIST, because `..` is resolved by the OS and a path whose
      # ancestors are missing does not resolve at all.
      base = Path.join([mise, "installs", "elixir"])
      File.mkdir_p!(base)

      hops = length(Path.split(base)) - 1

      traversal =
        String.duplicate("../", hops) <> String.trim_leading(escape, "/")

      # The premise, asserted rather than assumed: a candidate that does not
      # resolve is skipped by the UNFIXED hook too, so without this the test
      # passes whether or not the validation is there. It did, until this line.
      assert File.dir?(Path.join([base, traversal, "bin"])),
             "test premise broken: the traversal must reach a real directory"

      write_tool_versions(Path.join(repo, ".tool-versions"), traversal)

      path = resulting_path(repo, mise)

      refute path =~ escape,
             "a repo-controlled version escaped the mise root and reached PATH"
    end

    test "still prepends a real installed version", %{dir: dir} do
      # The fix must not cost the hook its job: the whole reason it exists is
      # that a Homebrew mix ahead of the mise one fails deep inside dep
      # resolution with `function Enum.__in__/2 is undefined`.
      repo = Path.join(dir, "repo")
      mise = Path.join(dir, "mise")
      File.mkdir_p!(repo)

      installed =
        Path.join([mise, "installs", "elixir", "1.20.2-otp-29", "bin"])

      File.mkdir_p!(installed)

      write_tool_versions(Path.join(repo, ".tool-versions"), "1.20.2-otp-29")

      assert resulting_path(repo, mise) =~ installed
    end

    # The override has to be checkable, or a developer deliberately running
    # against a different Elixir gets silently put back on the pinned one every
    # time they commit, with nothing on screen saying so.
    test "RAXOL_HOOK_NO_TOOLCHAIN leaves PATH alone even when installed", %{
      dir: dir
    } do
      repo = Path.join(dir, "repo")
      mise = Path.join(dir, "mise")
      File.mkdir_p!(repo)

      installed =
        Path.join([mise, "installs", "elixir", "1.20.2-otp-29", "bin"])

      File.mkdir_p!(installed)
      write_tool_versions(Path.join(repo, ".tool-versions"), "1.20.2-otp-29")

      # Same fixture as the test above, which DOES prepend -- so this pins the
      # override and not merely a version that was never going to resolve.
      assert resulting_path(repo, mise) =~ installed

      assert resulting_path(repo, mise, [{"RAXOL_HOOK_NO_TOOLCHAIN", "1"}]) ==
               "/usr/bin:/bin"
    end

    test "leaves PATH alone when the pinned version is not installed", %{
      dir: dir
    } do
      repo = Path.join(dir, "repo")
      mise = Path.join(dir, "mise")
      File.mkdir_p!(repo)

      write_tool_versions(Path.join(repo, ".tool-versions"), "9.9.9-otp-99")

      assert resulting_path(repo, mise) == "/usr/bin:/bin"
    end

    # `set -u` is on, so an unbound variable would abort the hook before any
    # gate ran, and a shell-metacharacter version must not be executed either.
    test "survives a malformed or absent version without aborting", %{dir: dir} do
      repo = Path.join(dir, "repo")
      mise = Path.join(dir, "mise")
      File.mkdir_p!(repo)

      for version <- [
            "",
            "$(touch #{dir}/pwned)",
            "../..",
            "; touch #{dir}/pwned"
          ] do
        write_tool_versions(Path.join(repo, ".tool-versions"), version)

        assert resulting_path(repo, mise) == "/usr/bin:/bin",
               "#{inspect(version)} should leave PATH untouched"
      end

      refute File.exists?(Path.join(dir, "pwned")),
             "a version string was executed as shell"
    end
  end
end
