defmodule Raxol.Agent.SilentAgent do
  @moduledoc """
  An agent that never answers a `Raxol.Agent.Comm.call/3`, for tests of a
  caller's timeout. A test that spawns it over MCP puts it on
  `config :raxol_agent, :mcp_spawnable_apps` for its own duration.
  """

  use Raxol.Agent

  def init(_context), do: %{}

  def available_actions, do: []

  def update(_message, model), do: {model, []}
end
