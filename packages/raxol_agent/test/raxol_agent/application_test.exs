defmodule RaxolAgent.ApplicationTest do
  @moduledoc """
  `RaxolAgent.Application` is what starts `Raxol.Agent.Supervisor`: `:raxol`
  does not. The package has no application callback under `MIX_ENV=test`, so
  `start/2` is called here as the application controller calls it.
  """
  use ExUnit.Case, async: false

  setup do
    refute Process.whereis(Raxol.Agent.Supervisor)
    refute Process.whereis(RaxolAgent.Supervisor)
    :ok
  end

  test "starts Raxol.Agent.Supervisor under its own supervisor" do
    {:ok, app} = RaxolAgent.Application.start(:normal, [])

    assert [{Raxol.Agent.Supervisor, agents, :supervisor, _modules}] =
             Supervisor.which_children(app)

    assert Process.whereis(Raxol.Agent.Supervisor) == agents
    assert is_pid(Process.whereis(Raxol.Agent.McpTools))

    :ok = Supervisor.stop(app)
    refute Process.whereis(Raxol.Agent.Supervisor)
  end

  test "leaves an agent supervisor a host already started to that host" do
    agents = start_supervised!(Raxol.Agent.Supervisor)

    {:ok, app} = RaxolAgent.Application.start(:normal, [])

    assert Supervisor.which_children(app) == []
    assert Process.whereis(Raxol.Agent.Supervisor) == agents

    :ok = Supervisor.stop(app)
    assert Process.whereis(Raxol.Agent.Supervisor) == agents
  end
end
