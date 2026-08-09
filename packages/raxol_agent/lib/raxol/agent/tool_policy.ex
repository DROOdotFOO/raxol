defmodule Raxol.Agent.ToolPolicy do
  @moduledoc """
  Composable authorizers for the LLM tool-call path.

  A tool authorizer is a `(action_module, params, context) -> :ok | {:deny,
  reason}` function placed in the agent context under `:tool_authorizer`.
  `Raxol.Agent.Action.ToolConverter.dispatch_tool_call/3` consults it before
  invoking the Action, so a prompt-injected LLM cannot drive a sensitive tool
  (e.g. a payment Action) just by emitting a tool call. Absent, tool calls are
  allowed (backward compatible) -- set one to enforce.

      context = %{tool_authorizer: Raxol.Agent.ToolPolicy.denylist(["payment_execute_xochi_intent"])}
      Raxol.Agent.Strategy.ReAct.execute(action_spec, state, Map.merge(base, context))

  Authorizers compose with `all/1` (deny if any denies).

  Richer phase-aware policy (ALLOW/ASK/DENY) lives in
  `Raxol.Agent.Authorization.Engine` at the `:tool_call` phase; delegating to it
  from here is a follow-up.
  """

  @type authorizer ::
          (module() | Raxol.Agent.Action.Dynamic.t(), map(), map() -> :ok | {:deny, term()})

  @doc "Allow every tool call."
  @spec allow_all() :: authorizer()
  def allow_all, do: fn _module, _params, _context -> :ok end

  @doc "Deny every tool call."
  @spec deny_all(term()) :: authorizer()
  def deny_all(reason \\ :tools_disabled),
    do: fn _module, _params, _context -> {:deny, reason} end

  @doc "Allow only Actions whose tool name is in `names`; deny the rest."
  @spec allowlist([String.t()]) :: authorizer()
  def allowlist(names) when is_list(names) do
    set = MapSet.new(names)

    fn module, _params, _context ->
      if action_name(module) in set, do: :ok, else: {:deny, :not_in_allowlist}
    end
  end

  @doc "Deny Actions whose tool name is in `names`; allow the rest."
  @spec denylist([String.t()]) :: authorizer()
  def denylist(names) when is_list(names) do
    set = MapSet.new(names)

    fn module, _params, _context ->
      if action_name(module) in set, do: {:deny, :denied}, else: :ok
    end
  end

  @doc """
  Deny Actions whose metadata marks them `sensitive: true` (fund-movers like
  the payment Actions); allow the rest. This is the default policy applied when
  no `:tool_authorizer` is set, so a prompt-injected LLM cannot drive a
  sensitive tool unless the agent explicitly opts in (e.g. with `allow_all/0`).
  """
  @spec deny_sensitive() :: authorizer()
  def deny_sensitive do
    fn module, _params, _context ->
      if sensitive?(module), do: {:deny, :sensitive_tool}, else: :ok
    end
  end

  @doc "Combine authorizers: the first `{:deny, _}` wins; otherwise `:ok`."
  @spec all([authorizer()]) :: authorizer()
  def all(authorizers) when is_list(authorizers) do
    fn module, params, context ->
      Enum.reduce_while(authorizers, :ok, fn auth, :ok ->
        case auth.(module, params, context) do
          :ok -> {:cont, :ok}
          {:deny, _reason} = denied -> {:halt, denied}
        end
      end)
    end
  end

  defp action_name(%Raxol.Agent.Action.Dynamic{name: name}), do: name
  defp action_name(module), do: module.__action_meta__().name

  @doc """
  The `{name, sensitive?}` pair for an action, however it is carried.

  Module Actions keep it in `__action_meta__/0`; runtime-discovered MCP tools
  are `%Raxol.Agent.Action.Dynamic{}` structs and carry it on the struct. Public
  because an authorizer that ASKS rather than denies needs the name for its
  prompt, not just the flag -- see
  `Raxol.Agent.ClientProtocol.Permission.authorizer/2`.
  """
  @spec identity(module() | Raxol.Agent.Action.Dynamic.t()) ::
          {String.t() | atom(), boolean()}
  def identity(%Raxol.Agent.Action.Dynamic{name: name, sensitive: sensitive}),
    do: {name, sensitive == true}

  def identity(module) when is_atom(module) do
    meta = module.__action_meta__()
    {Map.get(meta, :name), Map.get(meta, :sensitive, false) == true}
  end

  defp sensitive?(action), do: action |> identity() |> elem(1)
end
