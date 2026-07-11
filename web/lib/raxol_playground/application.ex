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
         query: Application.get_env(:raxol_playground, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: RaxolPlayground.PubSub}
      ] ++
        maybe_raxol_pubsub() ++
        [
          RaxolPlaygroundWeb.Presence,
          RaxolPlaygroundWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: RaxolPlayground.Supervisor]

    with {:ok, sup} <- Supervisor.start_link(children, opts) do
      # SSH is started after the tree is up (see start_ssh_playground/1), so a
      # failed SSH start does not abort the web app's boot.
      start_ssh_playground(sup)
      {:ok, sup}
    end
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

  # Start the SSH playground as a dynamically-added, temporary child of the
  # already-running supervisor. Because the tree is up, Supervisor.start_child
  # returns {:error, _} on a failed start (e.g. an unwritable host-keys dir)
  # instead of aborting the whole boot -- an SSH problem degrades to "no SSH"
  # rather than taking the web app down. restart: :temporary keeps a later SSH
  # crash from tripping the parent's max_restarts.
  defp start_ssh_playground(sup) do
    with "true" <- System.get_env("RAXOL_SSH_PLAYGROUND"),
         nil <- Process.whereis(Raxol.SSH.Server),
         {:ok, _} <- Application.ensure_all_started(:ssh) do
      spec =
        Supervisor.child_spec(
          {Raxol.SSH.Server,
           app_module: Raxol.Playground.App,
           port: ssh_port(),
           host_keys_dir: System.get_env("RAXOL_SSH_HOST_KEYS_DIR") || "/app/ssh_keys",
           max_connections: ssh_max_connections(),
           allow_anonymous: true},
          restart: :temporary
        )

      case Supervisor.start_child(sup, spec) do
        {:ok, _pid} -> :ok
        {:error, reason} -> IO.puts("[SSH] playground not started: #{inspect(reason)}")
      end
    else
      _ -> :ok
    end
  rescue
    e -> IO.puts("[SSH] playground error: #{Exception.message(e)}")
  catch
    :exit, reason -> IO.puts("[SSH] playground exit: #{inspect(reason)}")
  end

  defp ssh_port, do: String.to_integer(System.get_env("RAXOL_SSH_PORT") || "2222")

  defp ssh_max_connections,
    do: String.to_integer(System.get_env("RAXOL_SSH_MAX_CONNECTIONS") || "50")

  @impl true
  def config_change(changed, _new, removed) do
    RaxolPlaygroundWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
