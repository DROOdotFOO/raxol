defmodule Raxol.Agent.McpSpendHook do
  @moduledoc """
  Reserve before a per-call-priced MCP tool runs, and deny an unpriced tool on
  a metered origin (ADR-0037 decision 7).

  Register it in the ordered `:tool_call_hooks` list of the agent context,
  last, so a capability veto from an earlier hook happens before any money is
  reserved:

      context: %{tool_call_hooks: [Raxol.Agent.Code.Hooks, Raxol.Agent.McpSpendHook],
                 spend_gate: %{emit: emit_fun, try_reserve: try_reserve_fun}}

  ## Three cases, decided from the tool

  `Raxol.Agent.McpBundle` stamps a remote tool with the price its spec
  declared and, when the origin bills per call, with that origin. So:

    * no origin and no price -- an ordinary tool, untouched, fast path;
    * a price -- reserved through `Raxol.Agent.SpendGate.around/4`, which is
      fail-closed: a refused reserve means the request is never built;
    * a metered origin with no price -- denied, with the tool and the origin
      named in both the veto reason and the log line. This is the rule ADR-0033
      adopts by analogy from `Raxol.Agent.Backend.Resolver`: a free endpoint may
      be chosen automatically, a metered one only when explicitly configured. An
      operator sees a reason rather than an absence.

  `Raxol.Agent.McpBundle` already defaults every bundled tool to
  `sensitive: true`, and a priced tool cannot opt out of that, so this hook
  gates spend on top of a capability gate rather than instead of one.

  ## Why the reservation is a closure and not a call from `before_call/2`

  `before_call/2` returns a call, never a result, so it cannot itself wrap the
  invocation: `SpendGate.around/4` needs the spend-bearing call as its
  `call_fun`. Swapping in a wrapped `:action` is not available either --
  `Raxol.Agent.Action.ToolConverter` rejects an action that is not a member of
  the declared toolset, which is a rule worth keeping.

  So this hook mints the reservation as a closure and leaves it on the call,
  under a reserved params key, and the tool's `invoke` applies it through
  `metered/2`. `SpendGate.around/4` therefore runs with the reservation this
  hook authorized, wrapped around the request and before the request is built.
  The closure is the authority: without this hook in the pipeline there is no
  reservation and no handle, which is exactly why the transport refuses a
  priced `tools/call` that arrives without one. A native harness drives its own
  tool loop and bypasses this seam entirely, so that second enforcement site is
  not redundancy.

  The reserved key cannot be forged from model-supplied arguments: its value
  must be a function, and JSON cannot carry one. A non-function under that key
  is refused as `:invalid_spend_ticket` rather than ignored.

  ## Failure direction

  `Raxol.Agent.ToolCall.Hook` contains a hook `exit` as a veto and logs it, so
  a spend ledger that is down denies the call rather than admitting it. A
  context with no `:spend_gate` is the same direction: a priced tool cannot be
  metered without one, so it is denied with `:no_spend_gate` instead of
  running unmetered. Wiring that seam to a real budget is the caller's job --
  the gate's `try_reserve` shape is frozen and deliberately not defaulted
  here, because a default budget would be a fake one.

  ## Units

  A declared price is an integer in whatever unit the run budget counts, and
  it is the operator's figure rather than a measurement. A call that happened
  is settled at that price, because per-call billing has no post-hoc actual
  to discover: the price IS the cost once the call happened. A call that did
  not happen settles 0 -- see `charged/2`, which is what keeps a
  `{:error, :busy}` or a refused metering gate from charging a run budget for
  a request that never left the node.
  """

  @behaviour Raxol.Agent.ToolCall.Hook

  require Logger

  alias Raxol.Agent.Action.Dynamic
  alias Raxol.Agent.SpendGate

  # Reserved params key carrying the reservation closure from this hook to the
  # tool's `invoke`. `metered/2` removes it, so it never reaches a server.
  #
  # Both spellings are removed, and that is not belt-and-braces. Model-supplied
  # argument names are atomized only when the atom already exists, so the same
  # forged name arrives as `:__mcp_spend__` or as `"__mcp_spend__"` depending
  # on whether this module happens to be loaded yet -- a difference no defence
  # should turn on, and one that would otherwise forward the key to the server.
  @param_key :__mcp_spend__
  @param_name "__mcp_spend__"

  @impl true
  def before_call(%{action: %Dynamic{price: price} = tool} = call, context)
      when is_integer(price) and price > 0 do
    reserve(call, tool, price, Map.get(context, :spend_gate))
  end

  def before_call(%{action: %Dynamic{price: price, name: name, origin: origin}}, _context)
      when not is_nil(price) do
    deny(:invalid_price, name, origin)
  end

  def before_call(%{action: %Dynamic{price: nil, origin: origin, name: name}}, _context)
      when is_binary(origin) do
    deny(:unpriced_metered_tool, name, origin)
  end

  def before_call(call, _context), do: {:cont, call}

  defp reserve(call, %Dynamic{name: name, origin: origin}, price, gate) do
    if gate?(gate) do
      wrap = reservation(gate, cost_ref(call, name), price)
      {:cont, %{call | params: Map.put(call.params, @param_key, wrap)}}
    else
      deny(:no_spend_gate, name, origin)
    end
  end

  defp gate?(%{emit: emit, try_reserve: try_reserve}),
    do: is_function(emit, 1) and is_function(try_reserve, 1)

  defp gate?(_other), do: false

  defp deny(reason, name, origin) do
    Logger.warning(fn ->
      "mcp spend: denied #{name} on #{origin || "an unknown origin"}: #{reason}"
    end)

    {:halt, {reason, name, origin}}
  end

  # One reservation per invocation. The call id is the model's tool-use id, so
  # it identifies the call, and the unique integer keeps a retried id from
  # colliding with a live reservation that was never settled.
  defp cost_ref(call, name) do
    id = Map.get(call, :call_id) || name
    "mcp:#{id}:#{System.unique_integer([:positive, :monotonic])}"
  end

  defp reservation(gate, cost_ref, price) do
    fn inner -> run_reserved(gate, cost_ref, price, inner) end
  end

  defp run_reserved(gate, cost_ref, price, inner) do
    # The handle the transport sees is minted here, once per invocation, and
    # the transport spends it. The `cost_ref` stays what the spend ledger
    # keys on: it is derived from the model's tool-use id, so it is a value
    # the model can influence and never a credential to reach a priced tool
    # with. `Raxol.MCP.Client.Reservation` says what the handle defends.
    handle = Raxol.MCP.Client.Reservation.mint()

    case SpendGate.around(gate, cost_ref, price, fn -> charged(price, inner.(handle)) end) do
      {:ok, result} -> result
      {:error, {:reserve_refused, _reason}} = refused -> refused
    end
  end

  # What the run budget is charged. Per-call billing has no post-hoc actual to
  # discover, so a call that HAPPENED settles at the declared price -- a
  # tool-level `isError` result included, since the origin served it.
  #
  # An error is not a call. The transport refuses `:unmetered_call` and
  # `{:unknown_price, _}` with no request built, answers `{:error, :busy}`
  # when the in-flight window is full, `:breaker_open` for a quarantined
  # origin, and `{:error, :timeout}` for a request it gave up on. Settling the
  # full price for those charged the run budget for work no origin will bill,
  # which is what the moduledoc above promises not to do.
  defp charged(price, {:ok, _result} = result), do: {price, result}
  defp charged(_price, {:error, _reason} = result), do: {0, result}
  # A shape neither this hook nor the client produced is not evidence that
  # nothing happened, so it is charged rather than waived.
  defp charged(price, other), do: {price, other}

  @doc """
  Run a remote tool's request under whatever reservation this hook left on the
  call.

  `fun` receives the arguments with the reserved key removed, in either
  spelling, and the reservation handle (`nil` when the call carries none, which
  a priced tool's transport refuses). The reservation wraps `fun`, so a refused
  reserve returns `{:error, {:reserve_refused, reason}}` and `fun` never runs.

  Only this hook can leave a function under the reserved key, since JSON
  carries no functions. Anything else under either spelling is a forgery
  attempt: refused rather than ignored, and never forwarded.
  """
  @spec metered(map(), (map(), String.t() | nil -> term())) :: term()
  def metered(params, fun) when is_map(params) and is_function(fun, 2) do
    {ticket, args} = Map.pop(params, @param_key)
    {forged, args} = Map.pop(args, @param_name)

    cond do
      not is_nil(forged) -> {:error, :invalid_spend_ticket}
      is_function(ticket, 1) -> ticket.(fn reservation -> fun.(args, reservation) end)
      is_nil(ticket) -> fun.(args, nil)
      true -> {:error, :invalid_spend_ticket}
    end
  end
end
