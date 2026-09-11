defmodule Raxol.ReleaseManifestTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/build_cli_release_manifest.mjs", __DIR__)
  @assets [
    "raxol_cli_macos",
    "raxol_cli_linux",
    "raxol_cli_linux_arm",
    "raxol_cli_windows.exe"
  ]

  test "builds exact immutable URLs from the release checksums" do
    dir = tmp_dir()
    checksums = Path.join(dir, "SHA256SUMS")
    manifest = Path.join(dir, "manifest.json")

    checksums_body =
      @assets
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {name, index} ->
        "#{String.duplicate(Integer.to_string(index), 64)}  #{name}\n"
      end)

    File.write!(checksums, checksums_body)

    {output, status} =
      System.cmd("node", [@script, "0.3.0", checksums, manifest],
        env: [{"RAXOL_RELEASED_AT", "2026-09-10T12:00:00Z"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    decoded = manifest |> File.read!() |> Jason.decode!()
    assert decoded["schema_version"] == 1
    assert decoded["version"] == "0.3.0"
    assert decoded["tag"] == "raxol-cli-v0.3.0"
    assert map_size(decoded["assets"]) == 4

    assert decoded["assets"]["linux-x64"] == %{
             "name" => "raxol_cli_linux",
             "url" =>
               "https://github.com/DROOdotFOO/raxol/releases/download/raxol-cli-v0.3.0/raxol_cli_linux",
             "sha256" => String.duplicate("2", 64),
             "attestation_url" =>
               "https://github.com/DROOdotFOO/raxol/releases/download/raxol-cli-v0.3.0/raxol-cli-attestation.sigstore.json"
           }
  end

  test "rejects incomplete checksum sets" do
    dir = tmp_dir()
    checksums = Path.join(dir, "SHA256SUMS")
    manifest = Path.join(dir, "manifest.json")
    File.write!(checksums, "#{String.duplicate("a", 64)}  raxol_cli_linux\n")

    {output, status} =
      System.cmd("node", [@script, "0.3.0", checksums, manifest],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "missing checksum for raxol_cli_macos"
    refute File.exists?(manifest)
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol_release_manifest_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
