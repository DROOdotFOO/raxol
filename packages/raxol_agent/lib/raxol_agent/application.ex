defmodule RaxolAgent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Resolve the web3/fx tool configuration once, here, so a mistake refuses
    # the boot with its name instead of raising in every context build.
    Raxol.Agent.Web3.load!()

    # This application is what starts Raxol.Agent.Supervisor. An example or a
    # host that started the named subtree itself keeps it: starting it again
    # here would fail with :already_started.
    children =
      if Process.whereis(Raxol.Agent.Supervisor) do
        []
      else
        [Raxol.Agent.Supervisor]
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: RaxolAgent.Supervisor
    )
  end
end
