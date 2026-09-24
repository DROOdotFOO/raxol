defmodule Raxol.CLI.UpdateTest do
  @moduledoc """
  `raxol update` end to end against a real HTTP release channel on loopback
  (`Raxol.Test.UpdaterReleaseServer`), installing into a scratch file.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Raxol.CLI.Update
  alias Raxol.Test.UpdaterReleaseServer, as: Server

  @repo "DROOdotFOO/raxol"
  @platform "darwin-arm64"
  @asset "raxol_cli_macos"
  @old "old raxol binary\n"
  @binary "new raxol binary\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "raxol-update-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    exe = Path.join(dir, @asset)
    File.write!(exe, @old)
    File.chmod!(exe, 0o755)

    %{dir: dir, exe: exe}
  end

  defp serve(assets \\ %{@asset => @binary}, opts \\ []) do
    Server.start(Server.release_routes(@repo, "raxol-cli-v0.2.7", assets, opts))
  end

  defp runtime(base, ctx, overrides \\ []) do
    Keyword.merge(
      [
        manifest: [api_base: base, download_base: base],
        platform: @platform,
        current_version: "0.2.6+abc",
        current_executable: ctx.exe,
        backup_dir: Path.join(ctx.dir, "backups"),
        work_dir: Path.join(ctx.dir, "work")
      ],
      overrides
    )
  end

  test "check reports the newest CLI release without installing", ctx do
    base = serve()

    out = capture_io(fn -> assert Update.run(["--check"], runtime(base, ctx)) == 0 end)

    assert out =~ "Current version: 0.2.6"
    assert out =~ "New version available: 0.2.7"
    assert File.read!(ctx.exe) == @old
  end

  test "update verifies and replaces the current binary, keeping the old one", ctx do
    base = serve()

    out = capture_io(fn -> assert Update.run([], runtime(base, ctx)) == 0 end)

    assert out =~ "Updated to 0.2.7"
    assert File.read!(ctx.exe) == @binary
    assert File.read!(Path.join([ctx.dir, "backups", "previous_version"])) == @old
  end

  test "checksum mismatch leaves the installed binary untouched", ctx do
    base = serve(%{@asset => @binary}, checksums: Server.sha256sums(%{@asset => "published"}))

    stderr =
      capture_io(:stderr, fn ->
        _stdout = capture_io(fn -> assert Update.run([], runtime(base, ctx)) == 1 end)
      end)

    assert stderr =~ "checksum mismatch for #{@asset}"
    assert File.read!(ctx.exe) == @old
  end

  test "a specific version installs that release", ctx do
    base = serve()

    out =
      capture_io(fn -> assert Update.run(["--version", "0.2.7"], runtime(base, ctx)) == 0 end)

    assert out =~ "Updated to 0.2.7"
    assert File.read!(ctx.exe) == @binary
  end

  test "an unpublished version is an error, not an install", ctx do
    base = serve()

    stderr =
      capture_io(:stderr, fn ->
        _stdout =
          capture_io(fn -> assert Update.run(["--version", "9.9.9"], runtime(base, ctx)) == 1 end)
      end)

    assert stderr =~ "no such release"
    assert File.read!(ctx.exe) == @old
  end

  test "source builds fail clearly when installation needs a binary path", ctx do
    base = serve()
    opts = base |> runtime(ctx) |> Keyword.delete(:current_executable)

    stderr =
      capture_io(:stderr, fn ->
        _stdout = capture_io(fn -> assert Update.run([], opts) == 1 end)
      end)

    assert stderr =~ "not running as a Burrito binary"
  end

  test "auto prompt installs the update when the user accepts", ctx do
    base = serve()

    out =
      capture_io([input: "y\n"], fn ->
        assert Update.auto_prompt(auto_opts(base, ctx)) == :updated
      end)

    assert out =~ "Raxol 0.2.7 is available (current 0.2.6)."
    assert File.read!(ctx.exe) == @binary
  end

  test "auto prompt skips the update when the user declines", ctx do
    base = serve()

    out =
      capture_io([input: "n\n"], fn ->
        assert Update.auto_prompt(auto_opts(base, ctx)) == :ok
      end)

    assert out =~ "Skipping update. Run `raxol update` later."
    assert File.read!(ctx.exe) == @old
  end

  test "auto prompt honors a fresh check cache", ctx do
    base = serve()
    cache = Path.join(ctx.dir, "check.json")
    File.write!(cache, Jason.encode!(%{"last_checked_at" => 1_000}))

    out =
      capture_io([input: "y\n"], fn ->
        assert Update.auto_prompt(auto_opts(base, ctx, now_s: 1_100, auto_check_path: cache)) ==
                 :ok
      end)

    assert out == ""
    refute_received {:release_request, _path}
  end

  test "bad options are usage errors", ctx do
    stderr =
      capture_io(:stderr, fn ->
        assert Update.run(["--wat"], runtime("http://127.0.0.1:1", ctx)) == 64
      end)

    assert stderr =~ "unknown options"
  end

  defp auto_opts(base, ctx, overrides \\ []) do
    auto =
      Keyword.merge(
        [prompt?: true, now_s: 1_000, auto_check_path: Path.join(ctx.dir, "auto-check.json")],
        overrides
      )

    runtime(base, ctx, auto)
  end
end
