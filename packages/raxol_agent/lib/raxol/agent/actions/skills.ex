defmodule Raxol.Agent.Actions.Skills do
  @moduledoc """
  LLM-callable procedural-memory (skill) actions.

  Each action reaches the configured skills store via `context[:skills]`, the
  same way `Raxol.Agent.Actions.Memory` reaches the provider via
  `context[:memory]`. Add these to an agent's `available_actions/0` (done
  automatically when a skills provider is configured via `use Raxol.Agent`).
  """

  @actions [
    Raxol.Agent.Actions.Skills.List,
    Raxol.Agent.Actions.Skills.View,
    Raxol.Agent.Actions.Skills.Manage
  ]

  @doc "All skill action modules."
  @spec actions() :: [module()]
  def actions, do: @actions
end
