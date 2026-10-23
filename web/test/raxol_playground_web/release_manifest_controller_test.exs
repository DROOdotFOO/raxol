defmodule RaxolPlaygroundWeb.ReleaseManifestControllerTest do
  # The cache is one named ETS table shared with ReleaseManifestCacheTest.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias RaxolPlayground.ReleaseManifestCache
  alias RaxolPlaygroundWeb.Router

  @fixture Path.expand("../fixtures/release_manifest.json", __DIR__)
  @etag ~s("fixture")

  setup do
    ReleaseManifestCache.reset()
    on_exit(fn -> ReleaseManifestCache.reset() end)

    body = File.read!(@fixture)

    {:ok, %{body: ^body, stale?: false}} =
      ReleaseManifestCache.get(req_options: [plug: response_plug(body)])

    %{body: body}
  end

  test "GET /releases/latest.json serves the cached manifest as JSON", %{body: body} do
    conn = request([])

    assert conn.status == 200
    assert conn.resp_body == body
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert get_resp_header(conn, "etag") == [@etag]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=60, stale-if-error=300"]
    assert get_resp_header(conn, "warning") == []
  end

  test "GET /releases/latest.json answers a matching If-None-Match with 304 and the same headers" do
    conn = request([{"if-none-match", @etag}])

    assert conn.status == 304
    assert conn.resp_body == ""
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert get_resp_header(conn, "etag") == [@etag]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=60, stale-if-error=300"]
  end

  defp request(headers) do
    conn = conn(:get, "/releases/latest.json")

    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> Router.call(Router.init([]))
  end

  defp response_plug(body) do
    fn conn ->
      conn
      |> put_resp_header("etag", @etag)
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end
end
