defmodule Raxol.Payments.Actions.Payments.Transfer do
  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_transfer",
    description:
      "Transfer funds to an address (explicit payment, not auto-pay)",
    schema: [
      input: [
        to: [
          type: :string,
          required: true,
          description: "Recipient address (0x...)"
        ],
        amount: [type: :string, required: true, description: "Amount to send"],
        currency: [type: :string, description: "Currency (default: USDC)"]
      ],
      output: [
        status: [type: :string],
        from: [type: :string],
        to: [type: :string],
        amount: [type: :string]
      ]
    ]

  alias Raxol.Payments.{Ledger, SpendingPolicy}

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  @impl true
  def run(%{to: to, amount: amount_str} = params, context) do
    case Map.fetch(context, :wallet) do
      {:ok, wallet} ->
        do_transfer(wallet, to, amount_str, params, context)

      :error ->
        {:error, :missing_wallet}
    end
  end

  defp do_transfer(wallet, to, amount_str, params, context) do
    currency = Map.get(params, :currency, "USDC")
    amount = Decimal.new(amount_str)

    with :ok <- check_budget(amount, context) do
      # Record the spend
      if ledger = Map.get(context, :ledger) do
        agent_id = Map.get(context, :agent_id, :unknown)

        Ledger.record_spend(ledger, agent_id, amount, %{
          to: to,
          currency: currency,
          type: :explicit_transfer
        })
      end

      {:ok,
       %{
         status: "pending",
         from: wallet.address(),
         to: to,
         amount: amount_str
       }}
    end
  end

  defp check_budget(amount, context) do
    case Map.get(context, :policy) do
      nil ->
        :ok

      %SpendingPolicy{} = policy ->
        with :ok <- check_confirmation(policy, amount, context) do
          check_ledger_budget(policy, amount, context)
        end
    end
  end

  # Explicit transfers move to an address, not a host, so the domain gate from
  # PolicyGate does not apply -- but the amount-based confirmation threshold
  # does. Callers that need a confirmation UX pass `:on_confirm` in the action
  # context (1-arity function on amount).
  defp check_confirmation(policy, amount, context) do
    if SpendingPolicy.requires_confirmation?(policy, amount) do
      on_confirm = Map.get(context, :on_confirm)

      if is_function(on_confirm, 1) and on_confirm.(amount) == :approve do
        :ok
      else
        {:error, {:requires_confirmation, amount}}
      end
    else
      :ok
    end
  end

  defp check_ledger_budget(policy, amount, context) do
    case Map.get(context, :ledger) do
      nil ->
        :ok

      ledger ->
        agent_id = Map.get(context, :agent_id, :unknown)

        case Ledger.check_budget(ledger, agent_id, amount, policy) do
          :ok -> :ok
          {:over_limit, limit_type} -> {:error, {:over_budget, limit_type}}
        end
    end
  end
end
