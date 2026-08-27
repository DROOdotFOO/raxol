defmodule RaxolPlaygroundWeb.InstallController do
  @moduledoc """
  Serves the CLI installer at /install, for
  `curl -fsSL https://raxol.io/install | bash`.
  """
  use RaxolPlaygroundWeb, :controller

  # Embedded at compile time: the prod release ships without the repo, so a
  # request-time read cannot work there, and a copy under priv/ would be a
  # second copy to keep in sync. @external_resource recompiles this module
  # whenever the script changes, so the repo file stays the single source.
  @script_path Path.expand("../../../../scripts/install.sh", __DIR__)
  @external_resource @script_path
  @install_script File.read!(@script_path)

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, @install_script)
  end
end
