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
  identifier returned from `id_fn(payload)`. Two charge modes:

  ### Fixed-per-turn (default, `cost_fn == nil`)

  On each `:turn` authorization:

  1. Extract the identifier via `id_fn(payload)`. If `nil`, abstain
     (`:ok`) -- a missing identifier is not a budget violation.
  2. Read the current cumulative spend for the identifier (default 0).
  3. If `current + cost_per_turn > cap`, return `{:deny, :budget_exceeded}`.
  4. Otherwise atomically increment by `cost_per_turn` and return `:ok`.

  ### Cost-from-event (set `cost_fn`)

  When `cost_fn` is set, authorization charges nothing -- `cost_per_turn`
  becomes a *budget floor* used only for the deny check ("we'd need at
  least `cost_per_turn` of headroom to allow this turn"). The actual
  cost is settled per `:turn_completed` event via `settle/3`, which the
  Symphony RaxolAgent runner invokes automatically.

  Use this when per-turn cost varies (typical for LLM token billing):

      %Raxol.Symphony.Sandboxes.BudgetCap{
        cap: 100_000,
        cost_per_turn: 100,
        cost_fn: &Raxol.Symphony.Sandboxes.BudgetCap.tokens_from_usage/1
      }

  The bundled `tokens_from_usage/1` extractor reads `total_tokens` (or
  the sum of `input_tokens + output_tokens`) from a `:usage` map under
  whichever common key shape the backend returns. Returns 0 when no
  usage data is present, so a `cost_fn`-mode sandbox abstains for
  non-LLM events.

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
    :cost_fn,
    id_fn: &__MODULE__.default_id_fn/1,
    bucket_table: :symphony_budget_cap
  ]

  @type t :: %__MODULE__{
          cap: pos_integer(),
          cost_per_turn: non_neg_integer(),
          cost_fn: (map() -> non_neg_integer()) | nil,
          id_fn: (map() -> term() | nil),
          bucket_table: atom()
        }

  @doc false
  def default_id_fn(payload), do: Map.get(payload, :issue_id)

  @doc """
  Default `cost_fn` -- extracts a token count from a `:turn_completed`
  event's `:usage` map. Supports four common shapes:

  - `%{usage: %{total_tokens: n}}` (atom keys)
  - `%{usage: %{"total_tokens" => n}}` (string keys)
  - `%{usage: %{input_tokens: a, output_tokens: b}}` (sum)
  - `%{usage: %{"input_tokens" => a, "output_tokens" => b}}` (sum)

  Returns `0` when no usage data is present.
  """
  @spec tokens_from_usage(map()) :: non_neg_integer()
  def tokens_from_usage(%{} = event) do
    usage = Map.get(event, :usage) || Map.get(event, "usage") || %{}

    total =
      Map.get(usage, :total_tokens) ||
        Map.get(usage, "total_tokens")

    cond do
      is_integer(total) and total >= 0 ->
        total

      true ->
        input =
          to_non_neg(
            Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens")
          )

        output =
          to_non_neg(
            Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens")
          )

        input + output
    end
  end

  def tokens_from_usage(_), do: 0

  defp to_non_neg(n) when is_integer(n) and n >= 0, do: n
  defp to_non_neg(_), do: 0

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

  @doc """
  Atomically add `amount` to the cumulative spend for `identifier`.
  Returns the new running total. A non-positive `amount` is a no-op
  (returns the current spend without touching the table).
  """
  @spec record(atom(), term(), integer()) :: non_neg_integer()
  def record(table, identifier, amount) when is_integer(amount) and amount > 0 do
    _ = ensure_table(table)
    :ets.update_counter(table, identifier, amount, {identifier, 0})
  end

  def record(table, identifier, _amount) do
    spend(table, identifier)
  end

  @doc """
  Settle the actual cost of a `:turn_completed` event against the
  sandbox's bucket. No-op when:

  - `cost_fn` is `nil` (the sandbox is in fixed-per-turn mode).
  - `id_fn(payload)` returns `nil`.
  - `cost_fn(event)` returns 0 or a non-integer.

  Otherwise atomically adds the extracted cost to the running spend
  and returns `{:ok, new_total}`. Cap enforcement is the responsibility
  of the next `authorize/4` call; `settle/3` never denies (the turn has
  already happened).
  """
  @spec settle(t(), map(), map()) ::
          {:ok, non_neg_integer()} | :noop
  def settle(%__MODULE__{cost_fn: nil}, _event, _payload), do: :noop

  def settle(%__MODULE__{} = sandbox, event, payload) when is_map(event) do
    case sandbox.id_fn.(payload) do
      nil ->
        :noop

      identifier ->
        cost = sandbox.cost_fn.(event)

        if is_integer(cost) and cost > 0 do
          new_total = record(sandbox.bucket_table, identifier, cost)
          {:ok, new_total}
        else
          :noop
        end
    end
  end

  def settle(_sandbox, _event, _payload), do: :noop
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

    cond do
      current + sandbox.cost_per_turn > sandbox.cap ->
        {:deny, :budget_exceeded}

      sandbox.cost_fn != nil ->
        # cost-from-event mode: cost_per_turn is a deny-floor only.
        # Actual charge is settled by `settle/3` at turn completion.
        :ok

      true ->
        :ets.update_counter(table, identifier, sandbox.cost_per_turn, {identifier, 0})
        :ok
    end
  end
end
