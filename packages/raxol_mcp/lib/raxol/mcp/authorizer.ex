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
    * `{:ask, prompt}` -- the action needs interactive approval. What the server
      does with it depends on whether the client can be asked:
      - a client that advertised the `elicitation` capability at `initialize`
        (and has a subscribed transport) is sent a real `elicitation/create`
        request carrying `prompt`, and the call is parked until it answers;
      - anything else gets the machine-readable `authorization_required` result
        (deny-on-ASK), which is also what a decline, a cancel, an error, and a
        timeout resolve to. Only an explicit approval runs the tool.
      See `Raxol.MCP.Server`'s "Elicitation" section.
    * `{:deny, reason}` -- refuse, machine-readably.

  A `nil` authorizer means allow: a stdio transport already inherits the OS
  process boundary. The SSE transport, which exposes tools over the network, is
  guarded separately -- see `Raxol.MCP.Deployment`.

  ## Two seams: tools and reads

  `Raxol.MCP.Server` evaluates authorizers at two independent seams:

    * `:authorizer` -- guards `tools/call` (this module's original purpose).
      Receives the TOOL name.
    * `:read_authorizer` -- guards the read/metadata surfaces
      (`resources/read`, `resources/subscribe`, `resources/unsubscribe`,
      `resources/list`, `prompts/get`, `prompts/list`, `tools/list`,
      `completion/complete`). Receives the METHOD name in the tool-name
      position, e.g. `"resources/read"` with `%{"uri" => uri}` as the
      arguments.

  They are deliberately separate: a tool allowlist knows nothing about
  method names and would otherwise deny every read. On read surfaces an
  `{:ask, _}` decision resolves to deny (no elicitation for reads) and the
  prompt is not echoed to the client. Network deployments should configure
  BOTH seams -- the SSE boot guard (`Raxol.MCP.Deployment`) enforces only
  `:authorizer`, and a nil `:read_authorizer` serves model state to any
  connected client.
  """

  @type context :: map()
  @type decision :: :allow | {:ask, String.t()} | {:deny, term()}
  @type t :: (String.t(), map(), context() -> decision())

  @doc "Allow every call. The implicit behaviour when no authorizer is configured."
  @spec allow_all() :: t()
  def allow_all, do: fn _tool, _args, _ctx -> :allow end

  @doc "Deny every call with `reason`."
  @spec deny_all(term()) :: t()
  def deny_all(reason \\ :denied),
    do: fn _tool, _args, _ctx -> {:deny, reason} end

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

  def decide(fun, tool, args, ctx) when is_function(fun, 3),
    do: fun.(tool, args, ctx)
end
