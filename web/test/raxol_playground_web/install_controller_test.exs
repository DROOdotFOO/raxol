defmodule RaxolPlaygroundWeb.InstallControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias RaxolPlaygroundWeb.Router

  test "GET /install serves the canonical fail-closed installer without stale caching" do
    conn =
      :get
      |> conn("/install")
      |> Router.call(Router.init([]))

    assert conn.status == 200

    assert get_resp_header(conn, "content-type") == [
             "text/plain; charset=utf-8"
           ]

    assert get_resp_header(conn, "cache-control") == [
             "no-cache, max-age=0, must-revalidate"
           ]

    assert conn.resp_body ==
             File.read!(Path.expand("../../../scripts/install.sh", __DIR__))

    assert conn.resp_body =~ "refusing an unverified install"
  end
end
