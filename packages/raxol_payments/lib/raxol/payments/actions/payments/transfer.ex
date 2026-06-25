defmodule Raxol.Payments.Actions.Payments.Transfer do
  @moduledoc """
  Agent Action for an explicit transfer to an address.

  Spending is authorized through `Raxol.Payments.Actions.SpendGate` before any
  execution: the atomic ledger reservation and confirmation threshold are
  enforced here. Cross-chain and stealth execution route through Xochi via
  `Raxol.Payments.Actions.Payments.ExecuteXochiIntent`.
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_transfer",
    sensitive: true,
    description: "Transfer funds to an address (explicit payment, not auto-pay)",
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

  alias Raxol.Payments.Actions.SpendGate

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

    metadata = %{to: to, currency: currency, type: :explicit_transfer}

    with :ok <-
           SpendGate.authorize(context, amount,
             target: {:address, to},
             metadata: metadata
           ) do
      {:ok,
       %{
         status: "pending",
         from: wallet.address(),
         to: to,
         amount: amount_str
       }}
    end
  end
end
