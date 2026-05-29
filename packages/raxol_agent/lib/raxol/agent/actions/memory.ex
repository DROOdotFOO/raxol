defmodule Raxol.Agent.Actions.Memory do
  @moduledoc """
  LLM-callable cross-session memory actions.

  Each action reaches the configured provider via `context[:memory]`, the same
  way `Raxol.Agent.Actions.Vfs` reaches the VFS via `context[:vfs]`. Add these
  to an agent's `available_actions/0` (done automatically when a memory provider
  is configured via `use Raxol.Agent`).
  """

  @actions [
    Raxol.Agent.Actions.Memory.Remember,
    Raxol.Agent.Actions.Memory.Recall,
    Raxol.Agent.Actions.Memory.Forget
  ]

  @doc "All memory action modules."
  @spec actions() :: [module()]
  def actions, do: @actions
end
