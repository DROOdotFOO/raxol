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
    case Jason.decode(body) do
      {:ok, manifest} ->
        if valid_manifest?(manifest), do: :ok, else: {:error, :invalid_manifest}

      {:error, _reason} ->
        {:error, :invalid_manifest}
    end
  end

  def validate(_body), do: {:error, :invalid_manifest}

  defp valid_manifest?(
         %{
           "schema_version" => 1,
           "version" => version,
           "tag" => tag,
           "published_at" => published_at,
           "repository" => @repository,
           "signer_workflow" => @signer_workflow,
           "assets" => assets
         } = manifest
       )
       when is_binary(version) and is_binary(tag) and is_binary(published_at) do
    map_size(manifest) == 7 and
      Regex.match?(~r/^\d+\.\d+\.\d+$/, version) and
      tag == "raxol-cli-v#{version}" and
      valid_timestamp?(published_at) and
      valid_assets?(assets, tag)
  end

  defp valid_manifest?(_manifest), do: false

  defp valid_timestamp?(published_at) do
    match?({:ok, _, _}, DateTime.from_iso8601(published_at))
  end

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
