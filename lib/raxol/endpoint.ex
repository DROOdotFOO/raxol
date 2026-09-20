defmodule Raxol.Endpoint do
  @moduledoc """
  Dev-only Phoenix endpoint for local health checks and Tidewave MCP integration.

  Tidewave is mounted at `/tidewave/mcp` only when the configured development
  bind is loopback, enabling local MCP clients to use `project_eval` and the
  custom Raxol headless session tools without exposing evaluation remotely.
  """

  use Phoenix.Endpoint, otp_app: :raxol

  # Tidewave must be placed before request body parsing. The dev configuration
  # disables this mount entirely when RAXOL_DEV_BIND_IP is non-loopback.
  #
  # Read the single key by path, not the whole endpoint config: the full
  # keyword list carries `port:`, which config/dev.exs probes for a free
  # socket on every config evaluation. Recording that value would mark this
  # module stale whenever the probe landed elsewhere, and make a
  # `--no-compile` boot raise a compile-env mismatch.
  if Application.compile_env(
       :raxol,
       [Raxol.Endpoint, :tidewave_project_eval],
       false
     ) &&
       Code.ensure_loaded?(Tidewave) do
    plug Tidewave
  end

  # Only bounds requests that fall through Tidewave, which is every route
  # this endpoint itself serves: `/health` and the 404 handler. Tidewave's
  # router parses its own `/mcp` (Plug.Parsers default, 8 MB) and `/upload`
  # (200 MB) before this plug is reached.
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    length: 1_000_000,
    read_length: 64_000,
    read_timeout: 10_000,
    json_decoder: Jason

  plug :health_check
  plug :not_found

  defp health_check(%Plug.Conn{path_info: ["health"]} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{status: "ok"}))
    |> Plug.Conn.halt()
  end

  defp health_check(conn, _opts), do: conn

  defp not_found(%Plug.Conn{state: :sent} = conn, _opts), do: conn

  defp not_found(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, Jason.encode!(%{error: "not_found"}))
    |> Plug.Conn.halt()
  end
end
