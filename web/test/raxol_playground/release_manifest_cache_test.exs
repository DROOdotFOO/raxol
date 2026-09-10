defmodule RaxolPlayground.ReleaseManifestCacheTest do
  use ExUnit.Case, async: true

  alias RaxolPlayground.ReleaseManifestCache

  test "revalidates upstream and serves a bounded stale manifest on failure" do
    body = Jason.encode!(manifest())
    {url, server} = serve_responses([{200, body, ~s("fixture")}, {503, "", nil}])
    cache = Module.concat(__MODULE__, "Cache#{System.unique_integer([:positive])}")

    start_supervised!(
      {ReleaseManifestCache, name: cache, url: url, fresh_ms: 0, stale_ms: :timer.minutes(5)}
    )

    assert {:ok, %{body: ^body, etag: ~s("fixture"), stale?: false}} =
             ReleaseManifestCache.get(cache)

    assert {:ok, %{body: ^body, etag: ~s("fixture"), stale?: true}} =
             ReleaseManifestCache.get(cache)

    refute Process.alive?(server)
  end

  defp serve_responses(responses) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        Enum.each(responses, fn {status, body, etag} ->
          {:ok, socket} = :gen_tcp.accept(listener)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
          :ok = :gen_tcp.send(socket, response(status, body, etag))
          :gen_tcp.close(socket)
        end)

        :gen_tcp.close(listener)
      end)

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    {"http://127.0.0.1:#{port}/latest.json", server}
  end

  defp response(status, body, etag) do
    reason = if status == 200, do: "OK", else: "Service Unavailable"
    etag_header = if etag, do: "ETag: #{etag}\r\n", else: ""

    "HTTP/1.1 #{status} #{reason}\r\n" <>
      "Content-Type: application/json\r\n" <>
      etag_header <>
      "Content-Length: #{byte_size(body)}\r\n" <>
      "Connection: close\r\n\r\n" <>
      body
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
