defmodule Raxol.Agent.Strategy do
  @moduledoc """
  Behaviour for agent execution strategies.

  A strategy controls HOW an agent processes a command (action invocation).
  The agent decides WHAT to do; the strategy decides HOW to execute it.

  Built-in strategies:
  - `Raxol.Agent.Strategy.Direct` -- sequential action execution
  - `Raxol.Agent.Strategy.ReAct` -- LLM reasoning + tool use loop
  """

  @type command :: {module(), map()} | [{module(), map()}]
  @type state :: map()
  @type context :: map()
  @type effect :: Raxol.Core.Runtime.Command.t() | Raxol.Agent.Directive.t()
  @type result ::
          {:ok, state()}
          | {:ok, state(), [effect()]}
          | {:error, term()}

  @doc """
  Execute a command (action or pipeline) using this strategy.

  - `command` is `{ActionModule, params}` or a list of steps.
  - `state` is the agent's current model/state.
  - `context` carries backend config, available actions, etc.
  """
  @callback execute(command(), state(), context()) :: result()

  @doc "Optional: initialize strategy-specific state."
  @callback init(keyword()) :: {:ok, term()}

  @optional_callbacks [init: 1]
end
