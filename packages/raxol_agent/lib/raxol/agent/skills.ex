defmodule Raxol.Agent.Skills do
  @moduledoc """
  Entry points for the procedural-memory (skills) subsystem.

  Skills are reusable, named procedures an agent can read on demand and, via the
  curation loop, author itself. They live on disk as agentskills.io `SKILL.md`
  files; `Raxol.Agent.Skills.Store` is the warm index over them, and the three
  `Raxol.Agent.Actions.Skills` actions (`skills_list`, `skill_view`,
  `skill_manage`) are how an agent reaches them.

  Provides the configured store and the `{module, opts}` tuple that goes under
  `context[:skills]`, mirroring `Raxol.Agent.Memory.provider_context/3`.
  """

  alias Raxol.Agent.Skills.Store

  @doc "The skills store configured for this node, or `nil` when skills are disabled."
  @spec default_provider() :: module() | nil
  def default_provider, do: Application.get_env(:raxol_agent, :skills_provider)

  @doc """
  Build the `{module, opts}` tuple for `context[:skills]`.

  Returns `nil` when `provider` is `nil`, so a runtime can wire it
  unconditionally. `opts` flow to every store call (notably `:server` when the
  store runs under a non-default registered name).
  """
  @spec provider_context(module() | nil, keyword()) :: {module(), keyword()} | nil
  def provider_context(provider \\ Store, opts \\ [])
  def provider_context(nil, _opts), do: nil
  def provider_context(provider, opts) when is_atom(provider), do: {provider, opts}

  @doc """
  The skill actions to expose on a surface, or `[]` when skills are disabled.

  `skills_list` / `skill_view` / `skill_manage` are appended to a surface's
  action list only when a provider is configured (`config :raxol_agent,
  skills_provider: ...`), so a runtime can splice this in unconditionally.
  """
  @spec enabled_actions() :: [module()]
  def enabled_actions do
    if default_provider(), do: Raxol.Agent.Actions.Skills.actions(), else: []
  end

  @doc """
  The `context[:skills]` tuple for the configured provider, or `nil` when skills
  are disabled. Shorthand for `provider_context(default_provider())`.
  """
  @spec default_context() :: {module(), keyword()} | nil
  def default_context, do: provider_context(default_provider())
end
