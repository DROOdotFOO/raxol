defmodule Raxol.MCP.Authorizer do
  @moduledoc """
  The authorization seam in front of MCP `tools/call`.

  An authorizer is a 3-arity function `(tool_name, arguments, context) -> decision`,
  evaluated by `Raxol.MCP.Server` before a tool runs. `raxol_mcp` deliberately
  owns only the seam, not a policy engine: richer ALLOW/ASK/DENY logic (e.g.
  `Raxol.Agent.Authorization.Engine`) lives upstream and plugs in as a closure,
  so the engine and this enforcement point share one vocabulary without
  `raxol_mcp` depending on `raxol_agent` (which would be a dependency cycle).

  ## Decisions

    * `:allow` -- run the tool.
    * `{:ask, prompt}` -- the action would need interactive approval. `tools/call`
      has no interactive channel, so the server DENIES with a machine-readable
      `authorization_required` result (deny-on-ASK). A client that advertises
      elicitation can upgrade this to a real prompt later; that is a follow-up,
      not part of this seam.
    * `{:deny, reason}` -- refuse, machine-readably.

  A `nil` authorizer means allow: a stdio transport already inherits the OS
  process boundary. The SSE transport, which exposes tools over the network, is
  guarded separately -- see `Raxol.MCP.Deployment`.
  """

  @type context :: map()
  @type decision :: :allow | {:ask, String.t()} | {:deny, term()}
  @type t :: (String.t(), map(), context() -> decision())

  @doc "Allow every call. The implicit behaviour when no authorizer is configured."
  @spec allow_all() :: t()
  def allow_all, do: fn _tool, _args, _ctx -> :allow end

  @doc "Deny every call with `reason`."
  @spec deny_all(term()) :: t()
  def deny_all(reason \\ :denied), do: fn _tool, _args, _ctx -> {:deny, reason} end

  @doc """
  Allow only tools whose name is in `names`; deny the rest. This is the allowlist
  exposure mode: pair it with a narrow set to expose a safe subset of the
  auto-derived tool surface over an untrusted transport.
  """
  @spec allowlist([String.t()]) :: t()
  def allowlist(names) do
    set = MapSet.new(names)

    fn tool, _args, _ctx ->
      if MapSet.member?(set, tool), do: :allow, else: {:deny, :not_allowlisted}
    end
  end

  @doc "Evaluate an authorizer, treating `nil` as `:allow`."
  @spec decide(t() | nil, String.t(), map(), context()) :: decision()
  def decide(nil, _tool, _args, _ctx), do: :allow
  def decide(fun, tool, args, ctx) when is_function(fun, 3), do: fun.(tool, args, ctx)
end
