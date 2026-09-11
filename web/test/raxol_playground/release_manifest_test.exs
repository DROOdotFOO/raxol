defmodule RaxolPlayground.ReleaseManifestTest do
  use ExUnit.Case, async: true

  alias RaxolPlayground.ReleaseManifest
  @fixture Path.expand("../fixtures/release_manifest.json", __DIR__)

  test "accepts only immutable assets from the declared release" do
    manifest = @fixture |> File.read!() |> Jason.decode!()

    assert :ok = ReleaseManifest.validate(Jason.encode!(manifest))

    tampered = put_in(manifest, ["assets", "linux-x64", "url"], "https://example.com/raxol")
    assert {:error, :invalid_manifest} = ReleaseManifest.validate(Jason.encode!(tampered))
  end

  test "rejects version, digest, and platform-set mismatches" do
    manifest = @fixture |> File.read!() |> Jason.decode!()

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
end
