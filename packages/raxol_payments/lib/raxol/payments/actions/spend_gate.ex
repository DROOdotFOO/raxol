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
          | {:invalid_amount, Decimal.t()}
          | {:policy_required, atom()}
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

    with :ok <- validate_amount(amount),
         :ok <- require_policy(context),
         :ok <- gate(Map.get(context, :policy), amount, target, context) do
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

  # -- Amount validation --

  # A spend must be a positive, finite amount. Zero, negative, and non-finite
  # (Infinity/NaN) amounts are rejected before any gate runs. A negative amount
  # would otherwise pass every cap check and, once reserved, lower the running
  # ledger total, handing back budget headroom for later real spends. In
  # Decimal 2.x a finite value carries an integer coefficient while Infinity and
  # NaN carry an atom, so `is_integer(coef)` gates them out without hitting the
  # error `Decimal.compare/2` raises on NaN.
  defp validate_amount(%Decimal{coef: coef} = amount) when is_integer(coef) do
    if Decimal.compare(amount, 0) == :gt,
      do: :ok,
      else: {:error, {:invalid_amount, amount}}
  end

  defp validate_amount(amount), do: {:error, {:invalid_amount, amount}}

  # -- Policy presence --

  # A missing policy makes the gate a no-op (`gate(nil, ...)` passes and the
  # reservation is skipped), i.e. unlimited spending. That default-open posture
  # is convenient for tests and unconfigured callers but wrong for a fund-moving
  # deployment. `require_policy: true` (context) or
  # `config :raxol_payments, :require_policy, true` fails closed when no
  # `SpendingPolicy` is in context. Off by default (behaviour unchanged).
  defp require_policy(context) do
    if policy_required?(context) and not match?(%SpendingPolicy{}, Map.get(context, :policy)),
      do: {:error, {:policy_required, :no_spending_policy}},
      else: :ok
  end

  defp policy_required?(context) do
    case Map.get(context, :require_policy) do
      flag when is_boolean(flag) -> flag
      _ -> Application.get_env(:raxol_payments, :require_policy, false)
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
