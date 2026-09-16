defmodule RaxolPlaygroundWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :raxol_playground

  @session_options [
    store: :cookie,
    key: "_raxol_playground_key",
    signing_salt: "raxol_playground",
    same_site: "Lax"
  ]

  @request_body_options Application.compile_env!(
                          :raxol_playground,
                          [RaxolPlaygroundWeb.Endpoint, :request_body_options]
                        )

  # Redirect www to non-www in production
  if Mix.env() == :prod do
    plug(RaxolPlaygroundWeb.Plugs.WwwRedirect)
  end

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.Static,
    at: "/",
    from: :raxol_playground,
    gzip: false,
    only: RaxolPlaygroundWeb.static_paths()
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(
    Plug.Parsers,
    [
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library()
    ] ++ @request_body_options
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(RaxolPlaygroundWeb.Router)
end
