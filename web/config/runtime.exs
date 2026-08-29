import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :raxol_playground, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Xochi PAYMENTS solver capability endpoint for the landing reach matrix
  # (distinct from this app's own /api/capabilities, the agent surface).
  # Unset, the landing serves the static registry with a "cached" badge and
  # never touches the network. Timeouts are tight because the fetch runs in
  # LiveView mount: an outage costs one bounded stall per cache expiry, then
  # the ETS stale-serve takes over.
  if xochi_base_url = System.get_env("XOCHI_CAPABILITIES_BASE_URL") do
    config :raxol_playground, :xochi_capabilities, %{
      base_url: xochi_base_url,
      req_options: [connect_options: [timeout: 2_500], receive_timeout: 2_500]
    }
  end

  config :raxol_playground, RaxolPlaygroundWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Bind on all IPv4 interfaces for fly.io compatibility
      ip: {0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # Disable terminal features in production/container environments.
  # Must be a map: Raxol.Application.feature_enabled?/1 reads it with Map.get.
  config :raxol, :features, %{
    terminal_driver: false,
    web_interface: true,
    database: false,
    pubsub: true,
    performance_monitoring: true,
    terminal_sync: false,
    rate_limiting: true,
    telemetry: true,
    plugins: false,
    audit: false
  }

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :raxol_playground, RaxolPlaygroundWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :raxol_playground, RaxolPlaygroundWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
