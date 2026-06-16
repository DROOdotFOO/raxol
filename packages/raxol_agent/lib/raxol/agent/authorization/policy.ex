defmodule Raxol.Agent.Authorization.Policy do
  @moduledoc """
  A single policy in the ALLOW/ASK/DENY authorization engine.

  Distinct from `Raxol.Agent.Policy` (operational resilience: retry/cache/timeout)
  and from the deny-only `Raxol.Agent.PermissionHook` -- this is the authorization
  trichotomy with label state and human-in-the-loop ASK.

  A policy is data: when it applies (phase + condition gate), what labels it may
  write, how its ASK approvals are remembered, and an `evaluate` function that
  returns a `Raxol.Agent.Authorization.Verdict`.

  ## Applicability gates (cheap-first)

    1. **Phase** -- `phases` is `:all` or a list
       (`:input | :tool_call | :tool_result | :output`).
    2. **Conditions** -- a label gate `%{key => value | [values]}`: AND across
       keys, OR within a key's list, against the current label snapshot.

  ## Writable labels

  `writable_labels` is `:all` or a whitelist; a verdict's `writes` are filtered to
  keys the policy may write before they touch label state.

  ## ASK scope (approval memory)

    * `:once`    -- not remembered; ask again next time.
    * `:session` -- remembered for the engine's lifetime.
    * `:root`    -- remembered per evaluation `route` (e.g. the root of a spawn
      tree), so approving once covers the whole tree.
  """

  alias Raxol.Agent.Authorization.Verdict

  @type phase :: :input | :tool_call | :tool_result | :output | atom()
  @type scope :: :once | :session | :root

  @type t :: %__MODULE__{
          name: atom() | binary(),
          phases: :all | [phase()],
          conditions: map(),
          writable_labels: :all | [term()],
          scope: scope(),
          evaluate: (map() -> Verdict.t())
        }

  @enforce_keys [:name, :evaluate]
  defstruct name: nil,
            phases: :all,
            conditions: %{},
            writable_labels: :all,
            scope: :session,
            evaluate: nil

  @doc "Build a policy. Requires `:name` and `:evaluate`."
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc "Run the policy's `evaluate` against `context`, filtering its writes."
  @spec run(t(), map()) :: Verdict.t()
  def run(%__MODULE__{evaluate: evaluate} = policy, context) do
    verdict = evaluate.(context)
    %{verdict | writes: filter_writes(verdict.writes, policy.writable_labels)}
  end

  @doc "Does this policy apply at `phase` given the current `labels`?"
  @spec applies?(t(), phase(), map()) :: boolean()
  def applies?(%__MODULE__{} = policy, phase, labels) do
    phase_match?(policy.phases, phase) and conditions_met?(policy.conditions, labels)
  end

  defp phase_match?(:all, _phase), do: true
  defp phase_match?(phases, phase) when is_list(phases), do: phase in phases

  # AND across keys, OR within a key's list of accepted values.
  defp conditions_met?(conditions, labels) do
    Enum.all?(conditions, fn {key, accepted} ->
      value = Map.get(labels, key)

      case accepted do
        list when is_list(list) -> value in list
        single -> value == single
      end
    end)
  end

  defp filter_writes(writes, :all), do: writes
  defp filter_writes(writes, allowed) when is_list(allowed), do: Map.take(writes, allowed)
end
