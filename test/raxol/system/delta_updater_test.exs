defmodule Raxol.System.DeltaUpdaterTest do
  @moduledoc """
  Delta self-updates against a real HTTP release channel on loopback. The
  patch step is the one seam replaced (`:apply_patch`): it concatenates the
  delta onto the old binary, so the tests run without `bspatch` while every
  download, checksum and install is real.
  """
  use ExUnit.Case, async: true

  alias Raxol.System.{DeltaUpdater, Updater}
  alias Raxol.Test.UpdaterReleaseServer, as: Server

  @repo "DROOdotFOO/raxol"
  @platform "linux-x64"
  @asset "raxol_cli_linux"
  @tag_name "raxol-cli-v1.1.0"
  @delta "raxol-delta-1.0.0-1.1.0-linux-x64.bin"
  @old "old binary"
  @patch " + patch"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol_delta_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    exe = Path.join(dir, "raxol")
    File.write!(exe, @old)
    test_pid = self()

    apply_patch = fn old, delta, new ->
      send(test_pid, {:patched, File.read!(delta)})
      File.write(new, File.read!(old) <> File.read!(delta))
    end

    %{dir: dir, exe: exe, apply_patch: apply_patch}
  end

  defp opts(base, ctx, extra \\ []) do
    Keyword.merge(
      [
        manifest: [api_base: base, download_base: base],
        platform: @platform,
        current_version: "1.0.0",
        current_executable: ctx.exe,
        backup_dir: Path.join(ctx.dir, "backups"),
        work_dir: Path.join(ctx.dir, "work"),
        apply_patch: ctx.apply_patch
      ],
      extra
    )
  end

  defp download_path(name),
    do: "/#{@repo}/releases/download/#{@tag_name}/#{name}"

  defp serve(assets, opts \\ []),
    do: Server.start(Server.release_routes(@repo, @tag_name, assets, opts))

  test "self_update fetches the installed-to-target delta from the target release and installs it",
       ctx do
    base = serve(%{@asset => @old <> @patch, @delta => @patch})

    assert :ok = Updater.self_update("1.1.0", opts(base, ctx))

    assert File.read!(ctx.exe) == @old <> @patch
    delta_path = download_path(@delta)
    full_path = download_path(@asset)
    assert_received {:release_request, ^delta_path}
    refute_received {:release_request, ^full_path}
  end

  test "a delta that does not match SHA256SUMS is never patched", ctx do
    sums =
      Server.sha256sums(%{
        @asset => @old <> @patch,
        @delta => "the published delta"
      })

    base = serve(%{@asset => @old <> @patch, @delta => @patch}, checksums: sums)

    assert {:error, {:checksum_mismatch, @delta}} =
             DeltaUpdater.apply_delta_update("1.1.0", opts(base, ctx))

    refute_received {:patched, _delta}
    assert File.read!(ctx.exe) == @old
  end

  test "patched output that does not hash to the full binary is neither installed nor run",
       ctx do
    marker = Path.join(ctx.dir, "ran")
    rogue = "#!/bin/sh\ntouch #{marker}\n"

    rogue_patch = fn _old, _delta, new -> File.write(new, rogue) end
    base = serve(%{@asset => @old <> @patch, @delta => @patch})

    assert {:error, {:checksum_mismatch, @asset}} =
             DeltaUpdater.apply_delta_update(
               "1.1.0",
               opts(base, ctx, apply_patch: rogue_patch)
             )

    assert File.read!(ctx.exe) == @old
    refute File.exists?(marker)
  end

  test "without a delta from the installed version, self_update installs the full binary",
       ctx do
    base =
      serve(%{
        @asset => "new binary",
        "raxol-delta-0.9.0-1.1.0-linux-x64.bin" => "x"
      })

    assert :ok = Updater.self_update("1.1.0", opts(base, ctx))

    assert File.read!(ctx.exe) == "new binary"
    refute_received {:patched, _delta}
  end

  test "check_delta_availability reports the pinned delta URL and its savings",
       ctx do
    base =
      serve(%{
        @asset => String.duplicate("b", 100),
        @delta => String.duplicate("d", 10)
      })

    assert {:ok, info} =
             DeltaUpdater.check_delta_availability("1.1.0", opts(base, ctx))

    assert info.delta_url == base <> download_path(@delta)
    assert %{delta_size: 10, full_size: 100, savings_percent: 90} = info
  end
end
