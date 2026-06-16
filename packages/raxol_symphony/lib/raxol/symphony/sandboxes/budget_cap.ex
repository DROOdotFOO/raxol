defmodule Raxol.Symphony.Sandboxes.BudgetCap do
  @moduledoc """
  `Raxol.Agent.Sandbox` impl that caps cumulative spend per
  identifier and denies further `:turn` actions once the cap is hit.

  ## Configuration

      %Raxol.Symphony.Sandboxes.BudgetCap{
        cap: 1000,
        cost_per_turn: 1,
        id_fn: &Map.get(&1, :issue_id),
        bucket_table: :symphony_budget_cap
      }

  ## Behaviour

  Tracks cumulative spend in a named ETS table keyed by the
  identifier returned from `id_fn(payload)`. On each `:turn`
  authorization:

  1. Extract the identifier via `id_fn(payload)`. If `nil`, abstain
     (`:ok`) -- a missing identifier is not a budget violation.
  2. Read the current cumulative spend for the identifier (default 0).
  3. If `current + cost_per_turn > cap`, return `{:deny, :budget_exceeded}`.
  4. Otherwise atomically increment by `cost_per_turn` and return `:ok`.

  ## Spend scoping

  `id_fn` lets consumers scope budgets at different granularities:

      # Per-issue (default):
      id_fn: &Map.get(&1, :issue_id)

      # Per-org (consumer stuffs :org_id into the payload):
      id_fn: &Map.get(&1, :org_id)

      # Global cap (one bucket for everyone):
      id_fn: fn _ -> :global end

  ## Concurrency

  Uses `:ets.update_counter` for atomic increment. Multiple
  orchestrators sharing the same `bucket_table` see the same
  cumulative spend; isolate by giving each its own table.

  ## Resetting the budget

  No automatic reset. Consumers wanting periodic resets call
  `reset/2` on their own schedule (e.g. daily via cron job).

  ## Other actions

  Abstains for any action other than `:turn` so this composes
  with Shell / SendAgent / Async dimensions.
  """

  @enforce_keys [:cap, :cost_per_turn]
  defstruct [
    :cap,
    :cost_per_turn,
    id_fn: &__MODULE__.default_id_fn/1,
    bucket_table: :symphony_budget_cap
  ]

  @type t :: %__MODULE__{
          cap: pos_integer(),
          cost_per_turn: pos_integer(),
          id_fn: (map() -> term() | nil),
          bucket_table: atom()
        }

  @doc false
  def default_id_fn(payload), do: Map.get(payload, :issue_id)

  @doc "Idempotently create the ETS bucket table."
  @spec ensure_table(atom()) :: atom()
  def ensure_table(table) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ref ->
        :ok
    end

    table
  end

  @doc """
  Read the current cumulative spend for `identifier`. Returns `0`
  when the identifier has no recorded spend.
  """
  @spec spend(atom(), term()) :: non_neg_integer()
  def spend(table, identifier) do
    _ = ensure_table(table)

    case :ets.lookup(table, identifier) do
      [{^identifier, value}] -> value
      [] -> 0
    end
  end

  @doc """
  Reset the cumulative spend for `identifier` (or `:all` to clear
  the whole table). Idempotent.
  """
  @spec reset(atom(), term() | :all) :: :ok
  def reset(table, :all) do
    _ = ensure_table(table)
    :ets.delete_all_objects(table)
    :ok
  end

  def reset(table, identifier) do
    _ = ensure_table(table)
    :ets.delete(table, identifier)
    :ok
  end
end

defimpl Raxol.Agent.Sandbox, for: Raxol.Symphony.Sandboxes.BudgetCap do
  alias Raxol.Symphony.Sandboxes.BudgetCap

  def authorize(%BudgetCap{} = sandbox, :turn, payload, _ctx) do
    case sandbox.id_fn.(payload) do
      nil ->
        :ok

      identifier ->
        check_and_charge(sandbox, identifier)
    end
  end

  def authorize(_sandbox, _action, _payload, _ctx), do: :ok

  defp check_and_charge(sandbox, identifier) do
    table = BudgetCap.ensure_table(sandbox.bucket_table)
    current = BudgetCap.spend(table, identifier)

    if current + sandbox.cost_per_turn > sandbox.cap do
      {:deny, :budget_exceeded}
    else
      :ets.update_counter(table, identifier, sandbox.cost_per_turn, {identifier, 0})
      :ok
    end
  end
end
