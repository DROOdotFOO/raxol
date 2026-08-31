defmodule RaxolPlaygroundWeb.RedirectController do
  @moduledoc """
  Permanent redirects for pages that have been folded into another.

  A deleted page is still a URL someone bookmarked, linked, or wrote into a
  README, so it answers rather than 404s. Permanent because these moves are
  not provisional: the destination is where the content lives now.
  """

  use RaxolPlaygroundWeb, :controller

  @doc """
  `/demos` -> `/gallery`.

  The demo index rendered the same `Raxol.Playground.Catalog` the gallery
  does, minus the previews, the search and the filters, and linked to the very
  pages `/demos/:demo` still serves. The gallery is the index now.
  """
  def demos(conn, _params) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: "/gallery")
    |> halt()
  end
end
