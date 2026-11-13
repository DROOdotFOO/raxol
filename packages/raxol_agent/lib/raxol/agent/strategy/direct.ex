defmodule Raxol.Agent.Strategy.Direct do
  @moduledoc """
  Sequential action execution strategy.

  Runs a single action or a pipeline of actions directly, merging results
  into the agent state. This is the default strategy.
  """

  @behaviour Raxol.Agent.Strategy

  alias Raxol.Agent.Action.Pipeline

  @impl true
  def execute({action_module, params}, state, context) do
    case action_module.call(params, context) do
      {:ok, result} ->
        {:ok, Map.merge(state, result)}

      {:ok, result, commands} ->
        {:ok, Map.merge(state, result), commands}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def execute(steps, state, context) when is_list(steps) do
    case Pipeline.run(steps, state, context) do
      {:ok, result, commands} ->
        {:ok, result, commands}

      {:error, {_step, reason}} ->
        {:error, reason}
    end
  end
end
