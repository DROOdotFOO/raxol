defmodule RaxolPlaygroundWeb.DemoLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint RaxolPlaygroundWeb.Endpoint

  defp get_page(path), do: get(build_conn(), path)

  # The index is folded into /gallery, which renders the same catalog with
  # previews, search and filters. A deleted page is still a URL someone linked,
  # so it answers rather than 404s.
  test "GET /demos redirects to the gallery" do
    conn = get_page("/demos")

    assert conn.status == 301
    assert redirected_to(conn, 301) == "/gallery"
  end

  test "major pages render route-specific metadata" do
    for {path, title, canonical} <- [
          {"/", "Raxol: one Elixir module, every surface", "https://raxol.io/"},
          {"/gallery", "Raxol component gallery", "https://raxol.io/gallery"},
          {"/surfaces", "Raxol surfaces", "https://raxol.io/surfaces"},
          {"/payments", "Raxol agent payments", "https://raxol.io/payments"}
        ] do
      html = get_page(path) |> html_response(200)

      assert html =~ ~s(<meta property="og:title" content="#{title}")
      assert html =~ ~s(<link rel="canonical" href="#{canonical}")
      assert html =~ ~s(<meta property="og:url" content="#{canonical}")
    end
  end

  test "GET /demos/:demo serves a known demo" do
    [component | _] = Raxol.Playground.Catalog.list_components()

    conn = get_page("/demos/#{component.name}")

    assert html_response(conn, 200) =~ component.name
  end

  # A name that is not in the catalog is a wrong URL, not a broken server. This
  # used to guard a sharper edge: the index render clause matched `component:
  # nil`, so an unknown name fell into it and read assigns only the index mount
  # set -- a KeyError served as a 500. The index is gone, and the raise in
  # handle_params is now the only thing standing between a bad name and a nil
  # component, so the test matters more rather than less. The status is what is
  # asserted, not the exception type: 404 is the contract, the module that
  # raised to produce it is not.
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
