defmodule Raxol.Agent.Authorization.McpAuthorizer do
  @moduledoc """
  Adapts the ALLOW/ASK/DENY `Raxol.Agent.Authorization.Engine` into an MCP
  `tools/call` authorizer -- the closure `Raxol.MCP.Server` evaluates before a
  tool runs.

  This is the "one engine, two enforcement points" wiring: the same policy engine
  that gates `raxol.code`'s tool calls now gates the MCP surface, and it does so
  from the `raxol_agent` side, so `raxol_mcp` never has to depend on `raxol_agent`
  (which would be a dependency cycle). The MCP server owns only the seam; this
  fills it with the real engine.

  ## Usage

      policies = [%Raxol.Agent.Authorization.Policy{...}, ...]
      Raxol.MCP.Server.start_link(authorizer: McpAuthorizer.build(policies))

  Each call is evaluated at the `:tool_call` phase with a context of
  `%{tool: name, arguments: args}` merged over any static `:context`. The Engine
  `Decision` maps to the MCP vocabulary:

    * `:allow` -> `:allow`
    * `:deny`  -> `{:deny, reason}`
    * `:ask`   -> `{:ask, prompt}` -- MCP `tools/call` has no interactive channel,
      so `Raxol.MCP.Server` turns this into a machine-readable deny-on-ASK. When a
      client advertises elicitation, the same prompt drives a real approval.

  Stateless by default: a fresh `Engine.State` per call, so approvals are not
  remembered across MCP requests (deny-on-ASK needs no approval memory). Pass a
  shared `:state` if you later wire an approval path.
  """

  alias Raxol.Agent.Authorization.{Engine, Policy}

  @type decision :: :allow | {:ask, String.t()} | {:deny, term()}
  @typedoc "The 3-arity closure `Raxol.MCP.Server` expects as its `:authorizer`."
  @type authorizer :: (String.t(), map(), map() -> decision())

  @doc """
  Build an MCP authorizer closure backed by `policies`.

  Options:

    * `:context` -- a static map merged under the per-call `%{tool:, arguments:}`.
    * `:state` -- a shared `Engine.State`; defaults to a fresh, empty one per call.
  """
  @spec build([Policy.t()], keyword()) :: authorizer()
  def build(policies, opts \\ []) when is_list(policies) do
    base = Keyword.get(opts, :context, %{})
    state = Keyword.get(opts, :state, %Engine.State{})

    fn tool, arguments, ctx ->
      context =
        base
        |> Map.merge(ctx)
        |> Map.merge(%{tool: tool, arguments: arguments})

      policies
      |> Engine.evaluate(:tool_call, context, state)
      |> to_decision()
    end
  end

  defp to_decision(%Engine.Decision{action: :allow}), do: :allow
  defp to_decision(%Engine.Decision{action: :deny, reason: reason}), do: {:deny, reason}
  defp to_decision(%Engine.Decision{action: :ask} = decision), do: {:ask, prompt(decision)}

  defp prompt(%Engine.Decision{asks: [%{prompt: p} | _]}) when is_binary(p), do: p
  defp prompt(_decision), do: "Approval required"
end
