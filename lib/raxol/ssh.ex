defmodule Raxol.SSH do
  @moduledoc """
  SSH app serving for Raxol TEA applications.

  Serves a TEA app over SSH so each connection gets its own
  isolated process running the full init/update/view lifecycle.

  ## Example

      # Key-authenticated (any surface that can reach payment Actions):
      Raxol.SSH.serve(MyApp, port: 2222, authorized_keys_dir: "/etc/raxol/authorized")

      # Anonymous (public read-only demo): binds loopback unless separately
      # acknowledged, and must state every resource cap or refuses to start.
      Raxol.SSH.serve(MyApp,
        port: 2222,
        allow_anonymous: true,
        max_connections: 10,
        max_per_ip: 2,
        idle_timeout: :timer.minutes(5),
        max_session_duration: :timer.hours(1)
      )

      # Then: ssh localhost -p 2222
  """

  defdelegate serve(app_module, opts \\ []), to: Raxol.SSH.Server
end
