defmodule Raxol.Agent.Authorization.Engine do
  @moduledoc """
  Pure ALLOW/ASK/DENY authorization reducer.

  Evaluates an ordered list of `Raxol.Agent.Authorization.Policy` at a phase and
  folds them into one `Decision` (the omnigent PolicyEngine model):

    * **DENY** short-circuits: the label writes accumulated from prior ALLOWs are
      kept, the decision is DENY with the reason. No further policies run.
    * **ALLOW** applies its (whitelisted) writes to the running labels via a
      monotonic merge, then continues.
    * **ASK** accumulates an approval request and holds its writes in ESCROW
      (applied only on approval), then continues.

  Final action: DENY if any policy denied, else ASK if any policy asked, else
  ALLOW. "Stricter session first" is just list order -- prepend session policies;
  there is no separate tiering engine.

  ## Approval memory and the spawn tree

  Approving an ASK can be remembered (per `Policy.scope`): `:session` for the
  engine's lifetime, `:root` per evaluation `route`. Passing the root of a spawn
  tree as `route` and scoping `:root` makes one approval cover the whole tree.

  ## State threading

  `evaluate/5` is pure -- it returns a `Decision` but does NOT mutate state.
  Callers `commit/2` an ALLOW (or DENY) decision to fold its labels in, or
  `approve/2` an ASK decision to release escrow and remember the approval.
  """

  alias Raxol.Agent.Authorization.{Labels, Policy}

  defmodule State do
    @moduledoc "Engine state: current labels, remembered approvals, monotonic spec."
    @type t :: %__MODULE__{labels: map(), approvals: MapSet.t(), monotonic: map()}
    defstruct labels: %{}, approvals: %MapSet{}, monotonic: %{}
  end

  defmodule Decision do
    @moduledoc "The folded outcome of one `evaluate/5` pass."
    @type t :: %__MODULE__{
            action: :allow | :ask | :deny,
            labels: map(),
            reason: term(),
            asks: [map()],
            escrow: map(),
            route: term()
          }
    defstruct action: :allow, labels: %{}, reason: nil, asks: [], escrow: %{}, route: nil
  end

  @doc "Build engine state. Options: `:labels`, `:monotonic`."
  @spec new(keyword()) :: State.t()
  def new(opts \\ []) do
    %State{
      labels: Keyword.get(opts, :labels, %{}),
      approvals: MapSet.new(),
      monotonic: Keyword.get(opts, :monotonic, %{})
    }
  end

  @doc """
  Evaluate ordered `policies` at `phase` with `context` against `state`.

  Options: `:route` -- evaluation route for `:root`-scoped approval memory.
  Returns a `Decision`; does not mutate `state`.
  """
  @spec evaluate([Policy.t()], Policy.phase(), map(), State.t(), keyword()) :: Decision.t()
  def evaluate(policies, phase, context, %State{} = state, opts \\ []) do
    route = Keyword.get(opts, :route, :default)

    policies
    |> Enum.filter(&Policy.applies?(&1, phase, state.labels))
    |> reduce(context, route, state)
  end

  @doc "Fold a decision's labels into state (used for ALLOW/DENY outcomes)."
  @spec commit(Decision.t(), State.t()) :: State.t()
  def commit(%Decision{labels: labels}, %State{} = state), do: %{state | labels: labels}

  @doc """
  Approve an ASK decision: release escrowed writes into the labels and remember
  the approval per each ask's scope.
  """
  @spec approve(Decision.t(), State.t()) :: State.t()
  def approve(%Decision{action: :ask} = decision, %State{} = state) do
    labels = Labels.merge(state.labels, decision.escrow, state.monotonic)
    approvals = Enum.reduce(decision.asks, state.approvals, &remember(&1, decision.route, &2))
    %{state | labels: labels, approvals: approvals}
  end

  # -- Reduction --------------------------------------------------------------

  defp reduce(policies, context, route, state) do
    acc0 = %{labels: state.labels, asks: [], escrow: %{}}

    outcome =
      Enum.reduce_while(policies, {:ok, acc0}, fn policy, {:ok, acc} ->
        case decide(policy, context, route, state) do
          {:deny, reason} -> {:halt, {:deny, reason, acc}}
          {:allow, writes} -> {:cont, {:ok, apply_allow(acc, writes, state)}}
          {:ask, prompt, writes} -> {:cont, {:ok, hold_ask(acc, policy, prompt, writes)}}
        end
      end)

    finalize(outcome, route)
  end

  # An ASK whose approval is remembered for this route is treated as ALLOW.
  defp decide(policy, context, route, state) do
    verdict = Policy.run(policy, context)

    case verdict.action do
      :ask ->
        if approved?(state, policy, route),
          do: {:allow, verdict.writes},
          else: {:ask, verdict.prompt, verdict.writes}

      :allow ->
        {:allow, verdict.writes}

      :deny ->
        {:deny, verdict.reason}
    end
  end

  defp apply_allow(acc, writes, state),
    do: %{acc | labels: Labels.merge(acc.labels, writes, state.monotonic)}

  defp hold_ask(acc, policy, prompt, writes) do
    %{
      acc
      | asks: acc.asks ++ [%{policy: policy.name, prompt: prompt, scope: policy.scope}],
        escrow: Map.merge(acc.escrow, writes)
    }
  end

  defp finalize({:deny, reason, acc}, route),
    do: %Decision{action: :deny, reason: reason, labels: acc.labels, route: route}

  defp finalize({:ok, %{asks: []} = acc}, route),
    do: %Decision{action: :allow, labels: acc.labels, route: route}

  defp finalize({:ok, acc}, route),
    do: %Decision{
      action: :ask,
      labels: acc.labels,
      asks: acc.asks,
      escrow: acc.escrow,
      route: route
    }

  # -- Approval memory --------------------------------------------------------

  defp approved?(state, policy, route),
    do: MapSet.member?(state.approvals, approval_key(policy.name, policy.scope, route))

  defp remember(%{scope: :once}, _route, approvals), do: approvals

  defp remember(%{policy: name, scope: scope}, route, approvals),
    do: MapSet.put(approvals, approval_key(name, scope, route))

  defp approval_key(name, :session, _route), do: {name, :session}
  defp approval_key(name, :root, route), do: {name, {:root, route}}
  defp approval_key(name, :once, _route), do: {name, :once}
end
