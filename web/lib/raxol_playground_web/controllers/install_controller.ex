defmodule RaxolPlaygroundWeb.InstallController do
  @moduledoc """
  Serves the CLI installer at /install, for
  `curl -fsSL https://raxol.io/install | bash`.
  """
  use RaxolPlaygroundWeb, :controller

  # Embedded at compile time: the prod release ships without the repo, so a
  # request-time read cannot work there. priv/install.sh is a pinned copy of
  # the installer the agent repository publishes. @external_resource
  # recompiles this module whenever the copy changes.
  @script_path Path.expand("../../../priv/install.sh", __DIR__)
  @external_resource @script_path
  @install_script File.read!(@script_path)

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    # This endpoint is executable content. Revalidate every request so a
    # security fix or rollback is not held behind an hour-old edge cache.
    |> put_resp_header("cache-control", "no-cache, max-age=0, must-revalidate")
    |> send_resp(200, @install_script)
  end
end
