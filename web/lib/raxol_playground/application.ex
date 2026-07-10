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
        {Phoenix.PubSub, name: RaxolPlayground.PubSub},
        RaxolPlaygroundWeb.Presence,
        RaxolPlaygroundWeb.Endpoint
      ]

    opts = [strategy: :one_for_one, name: RaxolPlayground.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    RaxolPlaygroundWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
