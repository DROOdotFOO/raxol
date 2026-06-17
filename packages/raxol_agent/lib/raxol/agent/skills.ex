defmodule Raxol.Agent.Skills do
  @moduledoc """
  Entry points for the procedural-memory (skills) subsystem.

  Skills are reusable, named procedures an agent can read on demand and, via the
  curation loop, author itself. They live on disk as agentskills.io `SKILL.md`
  files; `Raxol.Agent.Skills.Store` is the warm index over them, and the three
  `Raxol.Agent.Actions.Skills` actions (`skills_list`, `skill_view`,
  `skill_manage`) are how an agent reaches them.

  This module is the small surface a runtime needs: the configured store and the
  `{module, opts}` tuple that goes under `context[:skills]`, mirroring
  `Raxol.Agent.Memory.provider_context/3`.
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
end
