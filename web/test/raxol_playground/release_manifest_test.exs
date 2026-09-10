defmodule RaxolPlayground.ReleaseManifestTest do
  use ExUnit.Case, async: true

  alias RaxolPlayground.ReleaseManifest

  test "accepts only immutable assets from the declared release" do
    manifest = manifest()

    assert :ok = ReleaseManifest.validate(Jason.encode!(manifest))

    tampered = put_in(manifest, ["assets", "linux-x64", "url"], "https://example.com/raxol")
    assert {:error, :invalid_manifest} = ReleaseManifest.validate(Jason.encode!(tampered))
  end

  test "rejects version, digest, and platform-set mismatches" do
    manifest = manifest()

    assert {:error, :invalid_manifest} =
             manifest
             |> Map.put("tag", "raxol-cli-v9.9.9")
             |> Jason.encode!()
             |> ReleaseManifest.validate()

    assert {:error, :invalid_manifest} =
             manifest
             |> put_in(["assets", "darwin-arm64", "sha256"], "not-a-digest")
             |> Jason.encode!()
             |> ReleaseManifest.validate()

    assert {:error, :invalid_manifest} =
             manifest
             |> update_in(["assets"], &Map.delete(&1, "win32-x64"))
             |> Jason.encode!()
             |> ReleaseManifest.validate()
  end

  defp manifest do
    version = "0.3.0"
    tag = "raxol-cli-v#{version}"
    base = "https://github.com/DROOdotFOO/raxol/releases/download/#{tag}"
    attestation_url = "#{base}/raxol-cli-attestation.sigstore.json"

    assets = %{
      "darwin-arm64" => "raxol_cli_macos",
      "linux-x64" => "raxol_cli_linux",
      "linux-arm64" => "raxol_cli_linux_arm",
      "win32-x64" => "raxol_cli_windows.exe"
    }

    %{
      "schema_version" => 1,
      "version" => version,
      "tag" => tag,
      "published_at" => "2026-09-10T12:00:00Z",
      "repository" => "DROOdotFOO/raxol",
      "signer_workflow" => "DROOdotFOO/raxol/.github/workflows/release-raxol-cli.yml",
      "assets" =>
        Map.new(assets, fn {platform, name} ->
          {platform,
           %{
             "name" => name,
             "url" => "#{base}/#{name}",
             "sha256" => String.duplicate("a", 64),
             "attestation_url" => attestation_url
           }}
        end)
    }
  end
end
