defmodule RaxolPlayground.Application do
  @moduledoc """
  OTP Application for the Raxol Playground web interface.

  Starts and supervises the Phoenix endpoint, PubSub, telemetry, and other
  web-related services for the Raxol interactive playground.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        RaxolPlaygroundWeb.Telemetry,
        {DNSCluster,
         query:
           Application.get_env(:raxol_playground, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: RaxolPlayground.PubSub}
      ] ++
        maybe_raxol_pubsub() ++
        [
          RaxolPlaygroundWeb.Presence,
          RaxolPlaygroundWeb.Endpoint
        ] ++ maybe_ssh_playground()

    opts = [strategy: :one_for_one, name: RaxolPlayground.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # In production Raxol runs in :minimal mode (RAXOL_MODE=minimal), so it does
  # not start Raxol.PubSub or the SSH playground; the web app provides them.
  # The guard skips the child if a :full-mode Raxol already started it, avoiding
  # an {:already_started} crash.
  defp maybe_raxol_pubsub do
    if Process.whereis(Raxol.PubSub) do
      []
    else
      [
        Supervisor.child_spec({Phoenix.PubSub, name: Raxol.PubSub},
          id: :raxol_pubsub
        )
      ]
    end
  end

  defp maybe_ssh_playground do
    if System.get_env("RAXOL_SSH_PLAYGROUND") == "true" and
         is_nil(Process.whereis(Raxol.SSH.Server)) do
      port = String.to_integer(System.get_env("RAXOL_SSH_PORT") || "2222")

      max =
        String.to_integer(System.get_env("RAXOL_SSH_MAX_CONNECTIONS") || "50")

      keys_dir = System.get_env("RAXOL_SSH_HOST_KEYS_DIR") || "/app/ssh_keys"

      try do
        Application.ensure_all_started(:ssh)

        # restart: :temporary so an SSH crash does not trip the parent
        # supervisor's max_restarts and take the Phoenix endpoint down with it.
        ssh_spec =
          Supervisor.child_spec(
            {Raxol.SSH.Server,
             app_module: Raxol.Playground.App,
             port: port,
             host_keys_dir: keys_dir,
             max_connections: max,
             allow_anonymous: true},
            restart: :temporary
          )

        [ssh_spec]
      rescue
        e ->
          IO.puts("[SSH] Failed to prepare SSH: #{Exception.message(e)}")
          []
      catch
        :exit, reason ->
          IO.puts("[SSH] Failed to start :ssh app: #{inspect(reason)}")
          []
      end
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    RaxolPlaygroundWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
