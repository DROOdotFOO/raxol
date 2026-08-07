defmodule Raxol.Agent.Code.CostLedger do
  @moduledoc """
  The coding TUI's bridge to `Raxol.Payments.Ledger`, so LLM spend and
  agent payment spend share one budget.

  raxol_agent does not depend on raxol_payments — the direction is the
  other way — so every call here is guarded on the Ledger module being
  loadable; without raxol_payments in the host application each function
  degrades to its no-op result. The host wires it by passing Code.App
  the options `:ledger` (a `Raxol.Payments.Ledger` server ref),
  `:spending_policy` (a `Raxol.Payments.SpendingPolicy`), and optionally
  `:agent_id` (the ledger scope key; defaults to `"raxol-code"` so a
  `/clear` cannot mint its way out of a budget).
  """

  @compile {:no_warn_undefined, [Raxol.Payments.Ledger, Decimal]}

  # Epsilon probe amount: `check_budget` needs a positive amount, and
  # this asks "is there any budget left at all?" without reserving.
  @probe "0.000001"

  @doc "True when raxol_payments' Ledger is loadable in this host."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Raxol.Payments.Ledger)

  @doc """
  Record `cost_usd` of LLM spend against the ledger (fire-and-forget).
  No-op without raxol_payments, a ledger ref, or a positive cost.
  """
  @spec record(term(), term(), float(), map()) :: :ok
  def record(ledger, agent_id, cost_usd, metadata)

  def record(ledger, agent_id, cost_usd, metadata)
      when not is_nil(ledger) and is_float(cost_usd) and cost_usd > 0.0 do
    if available?() do
      Raxol.Payments.Ledger.record_spend(
        ledger,
        agent_id,
        Decimal.from_float(cost_usd),
        metadata
      )
    end

    :ok
  end

  def record(_ledger, _agent_id, _cost_usd, _metadata), do: :ok

  @doc """
  Whether the agent's budget is already exhausted under `policy`:
  `:ok`, or `{:over, limit_type}`. `:ok` without raxol_payments or a
  ledger/policy (no budget configured means no gate).
  """
  @spec check(term(), term(), term()) :: :ok | {:over, atom()}
  def check(ledger, agent_id, policy)
      when not is_nil(ledger) and not is_nil(policy) do
    if available?() do
      case Raxol.Payments.Ledger.check_budget(
             ledger,
             agent_id,
             Decimal.new(@probe),
             policy
           ) do
        :ok -> :ok
        {:over_limit, type} -> {:over, type}
      end
    else
      :ok
    end
  end

  def check(_ledger, _agent_id, _policy), do: :ok

  @doc """
  A one-line spend summary from the shared ledger (session + lifetime
  totals under `policy`), or nil when no budget is configured.
  """
  @spec totals_text(term(), term(), term()) :: String.t() | nil
  def totals_text(ledger, agent_id, policy)
      when not is_nil(ledger) and not is_nil(policy) do
    if available?() do
      %{session: session, lifetime: lifetime} =
        Raxol.Payments.Ledger.get_totals(ledger, agent_id, policy)

      "ledger: $#{Decimal.round(session, 4)} session · " <>
        "$#{Decimal.round(lifetime, 4)} lifetime"
    end
  end

  def totals_text(_ledger, _agent_id, _policy), do: nil
end
