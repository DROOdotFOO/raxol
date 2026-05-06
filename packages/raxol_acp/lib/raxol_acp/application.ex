defmodule RaxolAcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Raxol.ACP.Supervisor
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: RaxolAcp.RootSupervisor
    )
  end
end
