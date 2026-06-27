defmodule Raxol.Payments.Actions.Payments.GetWalletInfo do
  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_get_wallet_info",
    description: "Get the agent's wallet address and chain ID",
    schema: [
      input: [],
      output: [
        address: [type: :string],
        chain_id: [type: :integer]
      ]
    ]

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  @impl true
  def run(_params, context) do
    case Map.fetch(context, :wallet) do
      {:ok, wallet} ->
        {:ok,
         %{
           address: wallet.address(),
           chain_id: wallet.chain_id()
         }}

      :error ->
        {:error, :missing_wallet}
    end
  end
end
