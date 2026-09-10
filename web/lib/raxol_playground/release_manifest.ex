defmodule RaxolPlayground.ReleaseManifest do
  @moduledoc false

  @repository "DROOdotFOO/raxol"
  @signer_workflow "DROOdotFOO/raxol/.github/workflows/release-raxol-cli.yml"
  @assets %{
    "darwin-arm64" => "raxol_cli_macos",
    "linux-x64" => "raxol_cli_linux",
    "linux-arm64" => "raxol_cli_linux_arm",
    "win32-x64" => "raxol_cli_windows.exe"
  }

  @spec validate(binary()) :: :ok | {:error, :invalid_manifest}
  def validate(body) when is_binary(body) do
    with {:ok, manifest} <- Jason.decode(body),
         %{
           "schema_version" => 1,
           "version" => version,
           "tag" => tag,
           "published_at" => published_at,
           "repository" => @repository,
           "signer_workflow" => @signer_workflow,
           "assets" => assets
         } <- manifest,
         true <- map_size(manifest) == 7,
         true <- is_binary(version),
         true <- is_binary(published_at),
         true <- Regex.match?(~r/^\d+\.\d+\.\d+$/, version),
         true <- tag == "raxol-cli-v#{version}",
         {:ok, _, _} <- DateTime.from_iso8601(published_at),
         true <- valid_assets?(assets, tag) do
      :ok
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  def validate(_body), do: {:error, :invalid_manifest}

  defp valid_assets?(assets, tag) when is_map(assets) do
    MapSet.new(Map.keys(assets)) == MapSet.new(Map.keys(@assets)) and
      Enum.all?(@assets, fn {platform, expected_name} ->
        valid_asset?(assets[platform], expected_name, tag)
      end)
  end

  defp valid_assets?(_assets, _tag), do: false

  defp valid_asset?(asset, expected_name, tag) when is_map(asset) do
    base = "https://github.com/#{@repository}/releases/download/#{tag}"
    sha256 = asset["sha256"]

    is_binary(sha256) and
      asset == %{
        "name" => expected_name,
        "url" => "#{base}/#{expected_name}",
        "sha256" => sha256,
        "attestation_url" => "#{base}/raxol-cli-attestation.sigstore.json"
      } and Regex.match?(~r/^[a-f0-9]{64}$/, sha256)
  end

  defp valid_asset?(_asset, _expected_name, _tag), do: false
end
