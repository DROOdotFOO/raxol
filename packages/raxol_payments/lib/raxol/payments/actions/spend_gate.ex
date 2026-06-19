defmodule Raxol.Payments.Actions.SpendGate do
  @moduledoc """
  Single spending choke point for payment Actions.

  Every agent Action that releases a wallet signature for real funds calls
  `authorize/3` first and proceeds only on `:ok`. This routes the request
  through the non-budget policy gate (`Raxol.Payments.PolicyGate`) and the
  atomic ledger reservation (`Raxol.Payments.Ledger.try_spend/5`) before any
  `wallet.sign_*` call.

  ## Targets

  * `{:domain, host}` -- HTTP/host-routed payment (x402, Xochi intent endpoint).
    The host is matched against `policy.approved_domains` and the confirmation
    threshold is applied.
  * `{:address, addr}` -- a direct on-chain transfer to an address. There is no
    host to approve, so only the confirmation threshold applies.

  ## Context keys

  * `:policy` -- a `SpendingPolicy` (nil means unrestricted: the gate is a no-op).
  * `:ledger` -- a `Ledger` server (nil disables budget reservation).
  * `:agent_id` -- ledger key (default `:unknown`).
  * `:on_confirm` -- `(Decimal.t(), String.t() -> :approve | :deny)` consulted
    when the amount exceeds `policy.require_confirmation_above`.

  ## Failed downstream execution

  `authorize/3` reserves budget atomically. If the signing/execution step that
  follows fails, call `release/2` (or `release/3`) to refund the reservation so
  a failed payment does not permanently consume the agent's budget.
  """

  alias Raxol.Payments.{Ledger, PolicyGate, SpendingPolicy}

  @type target :: {:domain, String.t()} | {:address, String.t()}

  @type error ::
          {:over_budget, atom()}
          | {:requires_confirmation, Decimal.t()}
          | {:deny, PolicyGate.deny_reason()}

  @doc """
  Authorize a spend before signing. Returns `:ok` or `{:error, reason}`.

  ## Options

  * `:target` -- `{:domain, host}` or `{:address, addr}` (default `{:address, ""}`).
  * `:metadata` -- map recorded with the ledger entry on success.
  """
  @spec authorize(map(), Decimal.t(), keyword()) :: :ok | {:error, error()}
  def authorize(context, %Decimal{} = amount, opts \\ []) when is_map(context) do
    target = Keyword.get(opts, :target, {:address, ""})

    with :ok <- gate(Map.get(context, :policy), amount, target, context) do
      reserve(context, amount, opts)
    end
  end

  @doc """
  Refund a previously authorized amount (e.g. when execution fails after the
  gate reserved budget). No-op when no ledger is configured.
  """
  @spec release(map(), Decimal.t(), map()) :: :ok
  def release(context, %Decimal{} = amount, metadata \\ %{}) when is_map(context) do
    case Map.get(context, :ledger) do
      nil ->
        :ok

      ledger ->
        agent_id = Map.get(context, :agent_id, :unknown)
        Ledger.release(ledger, agent_id, amount, metadata)
    end
  end

  # -- Non-budget gate --

  defp gate(nil, _amount, _target, _context), do: :ok

  defp gate(%SpendingPolicy{} = policy, amount, {:domain, host}, context)
       when is_binary(host) do
    opts = [on_confirm: Map.get(context, :on_confirm)]

    case PolicyGate.evaluate(policy, amount, host, opts) do
      :ok -> :ok
      {:deny, reason} -> {:error, {:deny, reason}}
    end
  end

  defp gate(%SpendingPolicy{} = policy, amount, {:address, addr}, context)
       when is_binary(addr) do
    if SpendingPolicy.requires_confirmation?(policy, amount) do
      confirm_address(Map.get(context, :on_confirm), amount, addr)
    else
      :ok
    end
  end

  defp confirm_address(on_confirm, amount, addr) when is_function(on_confirm, 2) do
    case on_confirm.(amount, addr) do
      :approve -> :ok
      _ -> {:error, {:requires_confirmation, amount}}
    end
  end

  defp confirm_address(_on_confirm, amount, _addr),
    do: {:error, {:requires_confirmation, amount}}

  # -- Atomic budget reservation --

  defp reserve(context, amount, opts) do
    with {:ledger, ledger} when not is_nil(ledger) <-
           {:ledger, Map.get(context, :ledger)},
         {:policy, %SpendingPolicy{} = policy} <-
           {:policy, Map.get(context, :policy)} do
      agent_id = Map.get(context, :agent_id, :unknown)
      metadata = Keyword.get(opts, :metadata, %{})

      case Ledger.try_spend(ledger, agent_id, amount, policy, metadata) do
        :ok -> :ok
        {:over_limit, type} -> {:error, {:over_budget, type}}
      end
    else
      _ -> :ok
    end
  end
end
