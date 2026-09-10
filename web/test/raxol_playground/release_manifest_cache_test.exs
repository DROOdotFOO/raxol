defmodule RaxolPlayground.ReleaseManifestCacheTest do
  use ExUnit.Case, async: false

  alias RaxolPlayground.ReleaseManifestCache
  @fixture Path.expand("../fixtures/release_manifest.json", __DIR__)

  setup do
    ReleaseManifestCache.reset()
    on_exit(fn -> ReleaseManifestCache.reset() end)
    :ok
  end

  test "revalidates upstream and serves a bounded stale manifest on failure" do
    body = File.read!(@fixture)

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
end
