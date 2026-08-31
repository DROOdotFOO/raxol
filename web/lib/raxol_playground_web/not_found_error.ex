defmodule RaxolPlaygroundWeb.NotFoundError do
  @moduledoc """
  Raised when a route resolves but the thing it names does not exist.

  `/demos/:demo` takes an arbitrary path segment, so a typo reaches the
  LiveView rather than the router's own 404. Raising this instead of letting
  the render fail on missing assigns is what separates "you asked for the
  wrong page" from "the server is broken": `plug_status` makes Phoenix serve
  it as a 404, and only a genuine fault is left reporting a 500.
  """
  defexception [:message, plug_status: 404]
end
