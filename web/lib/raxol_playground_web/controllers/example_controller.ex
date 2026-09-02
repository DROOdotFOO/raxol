defmodule RaxolPlaygroundWeb.ExampleController do
  @moduledoc """
  Serves the landing hero's examples as files that run.

  The hero lists four modules and heads each pane `$ mix run <name>.exs`. The
  listing is the module only, because the pane has no room for a boot block
  that a reader also has to read past; this route hands over the same module
  with the two lines that start it, which is what makes the command true.

  Both come from `LandingComponents`, so the file served and the program shown
  cannot drift apart.
  """
  use RaxolPlaygroundWeb, :controller

  alias RaxolPlaygroundWeb.LandingComponents

  def show(conn, %{"example" => example}) do
    # The name is matched against the known set rather than sanitized: these
    # four are the whole vocabulary, so anything else is a 404 and no path
    # ever reaches a filesystem. `.exs` is optional so both the filename and
    # the bare name resolve.
    name = String.replace_suffix(example, ".exs", "")

    case LandingComponents.example_script(name) do
      {:ok, script} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_resp(200, script)

      :error ->
        raise RaxolPlaygroundWeb.NotFoundError, "no example named #{example}"
    end
  end
end
