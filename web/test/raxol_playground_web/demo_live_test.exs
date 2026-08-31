defmodule RaxolPlaygroundWeb.DemoLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint RaxolPlaygroundWeb.Endpoint

  defp get_page(path), do: get(build_conn(), path)

  test "GET /demos lists the catalog" do
    conn = get_page("/demos")

    assert conn.status == 200
    assert html_response(conn, 200) =~ "Interactive Demos"
  end

  test "GET /demos/:demo serves a known demo" do
    [component | _] = Raxol.Playground.Catalog.list_components()

    conn = get_page("/demos/#{component.name}")

    assert html_response(conn, 200) =~ component.name
  end

  # A name that is not in the catalog is a wrong URL, not a broken server. The
  # index render clause matches on `component: nil`, so an unknown name used to
  # fall into it and reference assigns only the index mount sets -- a KeyError,
  # served as a 500. The status is what is asserted here rather than the
  # exception type: 404 is the contract, the module raised to produce it is not.
  test "GET /demos/:demo 404s on a name the catalog does not have" do
    status =
      try do
        get_page("/demos/no-such-component").status
      rescue
        error -> Plug.Exception.status(error)
      end

    assert status == 404
  end
end
