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
  if Application.compile_env(:raxol, Raxol.Endpoint, [])[:tidewave_project_eval] &&
       Code.ensure_loaded?(Tidewave) do
    plug Tidewave
  end

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
