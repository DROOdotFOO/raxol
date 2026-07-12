defmodule RaxolAgent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The main `raxol` app already starts Raxol.Agent.Supervisor whenever
    # the module is compiled in (application.ex maybe_add_agent_supervisor),
    # and raxol_agent depends on raxol -- so when raxol_agent boots as the
    # top application the dep starts the supervisor first. Starting it again
    # here crashes with :already_started, which took down every agent
    # example run from the package. Only own it when nobody else has.
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
