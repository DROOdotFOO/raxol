defmodule Raxol.System.UpdaterTest do
  @moduledoc """
  The self-updater against a real HTTP release channel on loopback: real
  downloads, real SHA256SUMS, real files standing in for the running
  executable. What is asserted is what would end up on disk.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Raxol.System.Updater
  alias Raxol.System.Updater.{Archive, Manifest}
  alias Raxol.Test.UpdaterReleaseServer, as: Server

  @repo "DROOdotFOO/raxol"
  @platform "linux-x64"
  @asset "raxol_cli_linux"
  @old "old binary"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol_updater_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    exe = Path.join(dir, "raxol")
    File.write!(exe, @old)

    %{
      dir: dir,
      exe: exe,
      backup: Path.join([dir, "backups", "previous_version"])
    }
  end

  defp opts(base, ctx, extra \\ []) do
    {manifest, extra} = Keyword.pop(extra, :manifest, [])

    Keyword.merge(
      [
        manifest: [api_base: base, download_base: base] ++ manifest,
        platform: @platform,
        current_version: "1.0.0",
        current_executable: ctx.exe,
        backup_dir: Path.join(ctx.dir, "backups"),
        work_dir: Path.join(ctx.dir, "work")
      ],
      extra
    )
  end

  defp download_path(tag, name),
    do: "/#{@repo}/releases/download/#{tag}/#{name}"

  describe "manifest pinning" do
    test "the default channel builds every URL from the raxol-cli releases of DROOdotFOO/raxol" do
      {:ok, manifest} = Manifest.load()
      {:ok, tag} = Manifest.tag(manifest, "v0.2.10")

      assert tag == "raxol-cli-v0.2.10"

      assert Manifest.release_url(manifest, tag) ==
               "https://api.github.com/repos/DROOdotFOO/raxol/releases/tags/raxol-cli-v0.2.10"

      assert Manifest.asset_url(manifest, tag, @asset) ==
               "https://github.com/DROOdotFOO/raxol/releases/download/raxol-cli-v0.2.10/raxol_cli_linux"
    end

    test "a version, repo, or base URL that could redirect a download is refused" do
      {:ok, manifest} = Manifest.load()

      assert {:error, {:invalid_version, _}} =
               Manifest.tag(manifest, "1.0.0/../../evil")

      assert {:error, {:invalid_version, _}} =
               Manifest.tag(manifest, "1.0.0-rc1")

      assert {:error, {:invalid_manifest, :api_base, _}} =
               Manifest.new(api_base: "http://evil.example")

      assert {:error, {:invalid_manifest, :download_base, _}} =
               Manifest.new(download_base: "https://github.com/someone-else")

      assert {:error, {:invalid_manifest, :repo, _}} =
               Manifest.new(repo: "a/b/../c")

      assert {:error, {:invalid_manifest, :assets, _}} =
               Manifest.new(assets: %{@platform => "../x"})

      assert {:error, {:unknown_manifest_keys, [:url]}} =
               Manifest.new(url: "https://x")

      assert {:ok, _loopback} = Manifest.new(api_base: "http://127.0.0.1:4000")
    end
  end

  describe "self_update/2 on a raw-binary channel" do
    test "installs the verified binary from the pinned URL, and rollback restores the old one",
         ctx do
      tag = "raxol-cli-v1.1.0"

      base =
        Server.start(
          Server.release_routes(@repo, tag, %{@asset => "new binary"})
        )

      assert :ok = Updater.self_update("1.1.0", opts(base, ctx))

      assert File.read!(ctx.exe) == "new binary"
      assert File.read!(ctx.backup) == @old

      asset_path = download_path(tag, @asset)
      assert_received {:release_request, ^asset_path}

      unless match?({:win32, _}, :os.type()) do
        assert (File.stat!(ctx.exe).mode &&& 0o111) != 0
      end

      assert :ok = Updater.rollback_update(opts(base, ctx))
      assert File.read!(ctx.exe) == @old
    end

    test "a binary that does not match SHA256SUMS is refused and nothing is replaced",
         ctx do
      tag = "raxol-cli-v1.1.0"
      sums = Server.sha256sums(%{@asset => "the binary that was published"})

      base =
        Server.start(
          Server.release_routes(@repo, tag, %{@asset => "a tampered binary"},
            checksums: sums
          )
        )

      assert {:error, {:checksum_mismatch, @asset}} =
               Updater.self_update("1.1.0", opts(base, ctx))

      assert File.read!(ctx.exe) == @old
      refute File.exists?(ctx.backup)
    end

    test "without a usable SHA256SUMS entry the binary is never even downloaded",
         ctx do
      tag = "raxol-cli-v1.1.0"
      other = Server.sha256sums(%{"raxol_cli_macos" => "x"})
      sha = Server.sha256("new binary")

      for {sums, expected} <- [
            {other, {:missing_checksum, @asset}},
            {"#{sha}  #{@asset}\n#{sha}  #{@asset}\n",
             {:duplicate_checksum, @asset}},
            {"not a checksum line\n",
             {:invalid_checksum_line, "not a checksum line"}}
          ] do
        base =
          Server.start(
            Server.release_routes(@repo, tag, %{@asset => "new binary"},
              checksums: sums
            )
          )

        assert {:error, ^expected} =
                 Updater.self_update("1.1.0", opts(base, ctx))

        asset_path = download_path(tag, @asset)
        refute_received {:release_request, ^asset_path}

        assert File.read!(ctx.exe) == @old
      end
    end

    test "an equal or older release is not installed", ctx do
      base =
        Server.start(
          Server.release_routes(@repo, "raxol-cli-v1.0.0", %{@asset => "same"})
        )

      assert {:no_update, "1.0.0"} =
               Updater.self_update("1.0.0", opts(base, ctx))

      assert File.read!(ctx.exe) == @old
    end
  end

  describe "check_for_updates/1" do
    test "reports the newest published release on the channel, ignoring other tags",
         ctx do
      listing = [
        Server.release_json("v9.0.0", %{}),
        Server.release_json("raxol-cli-v2.0.0", %{}, prerelease: true),
        Server.release_json("raxol-cli-v3.0.0", %{}, draft: true),
        Server.release_json("raxol-cli-v1.0.5", %{})
      ]

      base =
        Server.start(
          Server.release_routes(@repo, "raxol-cli-v1.1.0", %{@asset => "x"},
            listing: listing
          )
        )

      assert {:update_available, "1.1.0"} =
               Updater.check_for_updates(opts(base, ctx, force: true))

      assert {:no_update, "1.1.0"} =
               Updater.check_for_updates(
                 opts(base, ctx, force: true, current_version: "1.1.0")
               )
    end
  end

  defp tar_gz(path, entries) do
    {:ok, tar} = :erl_tar.open(to_charlist(path), [:write, :compressed])

    for {name, bytes} <- entries,
        do: :ok = :erl_tar.add(tar, bytes, to_charlist(name), [])

    :ok = :erl_tar.close(tar)
    File.read!(path)
  end

  defp archive_opts(base, ctx) do
    opts(base, ctx,
      manifest: [
        assets: %{@platform => "raxol.tar.gz"},
        format: {:tar_gz, "raxol"}
      ]
    )
  end

  describe "archive channels" do
    test "a verified archive installs the executable it contains", ctx do
      archive =
        tar_gz(Path.join(ctx.dir, "good.tar.gz"), [
          {"bin/raxol", "archived binary"}
        ])

      base =
        Server.start(
          Server.release_routes(@repo, "raxol-cli-v1.1.0", %{
            "raxol.tar.gz" => archive
          })
        )

      assert :ok = Updater.self_update("1.1.0", archive_opts(base, ctx))
      assert File.read!(ctx.exe) == "archived binary"
    end

    test "an entry escaping the extraction directory refuses the whole archive before extraction",
         ctx do
      archive =
        tar_gz(Path.join(ctx.dir, "evil.tar.gz"), [
          {"../evil", "pwned"},
          {"raxol", "payload"}
        ])

      base =
        Server.start(
          Server.release_routes(@repo, "raxol-cli-v1.1.0", %{
            "raxol.tar.gz" => archive
          })
        )

      assert {:error, {:unsafe_archive_entry, "../evil"}} =
               Updater.self_update("1.1.0", archive_opts(base, ctx))

      assert File.read!(ctx.exe) == @old
      refute File.exists?(Path.join([ctx.dir, "work", "evil"]))
      refute File.exists?(Path.join([ctx.dir, "work", "extracted", "raxol"]))
    end

    test "the checksum is checked before the archive is opened", ctx do
      archive =
        tar_gz(Path.join(ctx.dir, "evil.tar.gz"), [
          {"../evil", "pwned"},
          {"raxol", "payload"}
        ])

      sums =
        Server.sha256sums(%{"raxol.tar.gz" => "the archive that was published"})

      base =
        Server.start(
          Server.release_routes(
            @repo,
            "raxol-cli-v1.1.0",
            %{"raxol.tar.gz" => archive},
            checksums: sums
          )
        )

      assert {:error, {:checksum_mismatch, "raxol.tar.gz"}} =
               Updater.self_update("1.1.0", archive_opts(base, ctx))
    end

    test "a zip entry escaping the extraction directory is refused", ctx do
      zip = Path.join(ctx.dir, "evil.zip")

      {:ok, _} =
        :zip.create(to_charlist(zip), [
          {~c"../zevil", "pwned"},
          {~c"raxol", "x"}
        ])

      assert {:error, {:unsafe_archive_entry, "../zevil"}} =
               Archive.extract(zip, Path.join(ctx.dir, "zout"), :zip)

      refute File.exists?(Path.join(ctx.dir, "zevil"))
      refute File.exists?(Path.join([ctx.dir, "zout", "raxol"]))
    end

    # Creating a symlink needs a privilege Windows runners do not grant.
    @tag :skip_on_windows
    test "a tar symlink entry is refused", ctx do
      link_dir = Path.join(ctx.dir, "linked")
      File.mkdir_p!(link_dir)
      :ok = File.ln_s("/etc/passwd", Path.join(link_dir, "raxol"))
      tar = Path.join(ctx.dir, "link.tar.gz")
      {:ok, t} = :erl_tar.open(to_charlist(tar), [:write, :compressed])

      :ok =
        :erl_tar.add(
          t,
          to_charlist(Path.join(link_dir, "raxol")),
          ~c"raxol",
          []
        )

      :ok = :erl_tar.close(t)

      assert {:error, {:unsafe_archive_entry, "raxol", :symlink}} =
               Archive.extract(tar, Path.join(ctx.dir, "tout"), :tar_gz)
    end
  end
end
