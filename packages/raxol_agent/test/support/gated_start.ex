defmodule Raxol.Agent.Test.GatedStart do
  @moduledoc """
  An agent whose start a test holds open, for tests of what happens while an
  agent is starting.

  `init/1` tells the process registered as `gate/0` `{:starting, pid}` and
  waits for `:start` from it. With no process registered it starts at once.
  """

  use Raxol.Agent

  @gate __MODULE__.Gate

  @doc "The name a test registers itself under to hold starts open."
  @spec gate() :: atom()
  def gate, do: @gate

  def init(_context) do
    with gate when is_pid(gate) <- Process.whereis(@gate) do
      send(gate, {:starting, self()})
      receive(do: (:start -> :ok))
    end

    %{}
  end

  def available_actions, do: []

  def update(_message, model), do: {model, []}
end
