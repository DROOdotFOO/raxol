defmodule RaxolPlaygroundWeb.ReleaseManifestController do
  use RaxolPlaygroundWeb, :controller

  require Logger

  alias RaxolPlayground.ReleaseManifestCache

  @cache_control "public, max-age=60, stale-if-error=300"

  def show(conn, _params) do
    case ReleaseManifestCache.get() do
      {:ok, entry} ->
        send_manifest(conn, entry)

      {:error, reason} ->
        Logger.error("CLI release manifest unavailable: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(502, Jason.encode!(%{error: "release_manifest_unavailable"}))
    end
  end

  defp send_manifest(conn, entry) do
    conn =
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", @cache_control)
      |> put_resp_header("etag", entry.etag)
      |> maybe_mark_stale(entry.stale?)

    if entry.etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      send_resp(conn, 200, entry.body)
    end
  end

  defp maybe_mark_stale(conn, true),
    do: put_resp_header(conn, "warning", ~s(110 - "Response is stale"))

  defp maybe_mark_stale(conn, false), do: conn
end
