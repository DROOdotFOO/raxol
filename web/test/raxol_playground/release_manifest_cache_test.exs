defmodule RaxolPlayground.ReleaseManifestCacheTest do
  use ExUnit.Case, async: false

  alias RaxolPlayground.ReleaseManifestCache

  setup do
    ReleaseManifestCache.reset()
    on_exit(fn -> ReleaseManifestCache.reset() end)
    :ok
  end

  test "revalidates upstream and serves a bounded stale manifest on failure" do
    body = Jason.encode!(manifest())

    assert {:ok, %{body: ^body, etag: ~s("fixture"), stale?: false}} =
             ReleaseManifestCache.get(
               fresh_ms: 0,
               req_options: [plug: response_plug(200, body, ~s("fixture"))]
             )

    assert {:ok, %{body: ^body, etag: ~s("fixture"), stale?: true}} =
             ReleaseManifestCache.get(
               fresh_ms: 0,
               req_options: [plug: response_plug(503, "", nil)]
             )

    assert {:error, {:http_status, 503}} =
             ReleaseManifestCache.get(
               fresh_ms: 0,
               stale_ms: -1,
               req_options: [plug: response_plug(503, "", nil)]
             )
  end

  defp response_plug(status, body, etag) do
    fn conn ->
      conn = if etag, do: Plug.Conn.put_resp_header(conn, "etag", etag), else: conn

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end
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
