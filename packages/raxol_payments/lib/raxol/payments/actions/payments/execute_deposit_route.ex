defmodule Raxol.Payments.Actions.Payments.ExecuteDepositRoute do
  @moduledoc """
  Fetch and verify a Tron-origin cross-chain deposit-route quote.

  A non-EVM (Tron) origin has no gasless pull, so the quote returns a bare
  `deposit_address` the payer funds directly. This action fetches the quote and
  verifies its `deposit_attestation` recovers to the pinned signer BEFORE
  returning the deposit instructions, failing closed otherwise -- so the agent
  never sends TRC-20 funds to an address a compromised quote endpoint could have
  swapped.

  raxol does not send the funds (it has no Tron transaction stack): the agent's
  own Tron wallet funds `deposit_address` before `deposit_deadline`, then polls
  settlement with `payment_poll_xochi_status` (`pending -> completed | refunded`,
  with the refund reason surfaced on rejection).

  ## Context

    * `:xochi_config` -- `%{base_url:, auth}` for the quote endpoint.
    * `:deposit_attestation_signer` -- optional operator pin for the expected
      signer; otherwise `config :raxol_payments, :xochi_deposit_attestation_signer`,
      otherwise the live capability matrix's `deposit_attestation_signer`.

  Errors are machine-readable: `:attestation_mismatch`, `:missing_attestation`,
  `:deposit_signer_unavailable`, `:not_a_deposit_route`, `{:not_solvable, reason}`,
  or a request-validation tuple (e.g. `{:invalid_wallet, _}`).
  """

  use Raxol.Agent.Action,
    name: "payment_execute_deposit_route",
    sensitive: true,
    description:
      "Fetch and verify a Tron-origin cross-chain deposit-route quote. Returns the verified deposit_address (+ deadline) for your own Tron wallet to fund; raxol does not send the funds. Poll settlement with payment_poll_xochi_status.",
    schema: [
      input: [
        wallet: [type: :string, required: true, description: "Your Tron (base58) sending wallet"],
        from_chain_id: [
          type: :integer,
          required: true,
          description: "Origin chain id (Tron: 728126428)"
        ],
        to_chain_id: [type: :integer, required: true, description: "Destination (EVM) chain id"],
        from_token: [
          type: :string,
          required: true,
          description: "Origin TRC-20 token (Tron base58)"
        ],
        to_token: [
          type: :string,
          required: true,
          description: "Destination token contract (0x...)"
        ],
        amount_atomic: [
          type: :string,
          required: true,
          description: "Amount to send, in origin-token base units (an integer string)"
        ],
        recipient_address: [
          type: :string,
          required: true,
          description: "EVM destination recipient (0x...); the Tron wallet cannot receive on EVM"
        ],
        slippage_bps: [type: :integer, default: 50, description: "Max slippage (default 50)"],
        trust_score: [type: :integer, description: "Trust score for tier/fee"]
      ],
      output: [
        intent_id: [type: :string],
        deposit_address: [
          type: :string,
          description: "Send the TRC-20 deposit here -- verified against the pinned signer"
        ],
        deposit_deadline: [
          type: :integer,
          description: "Unix seconds until which a landed deposit is still filled"
        ],
        from_amount: [type: :string],
        to_amount: [type: :string],
        recipient_address: [type: :string]
      ]
    ]

  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.DepositRouteRequest

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  @impl true
  def run(params, context) do
    with {:ok, config} <- fetch_config(context),
         {:ok, instructions} <-
           Xochi.deposit_route_quote(config, build_request(params), signer_opts(context)) do
      {:ok, summary(instructions)}
    end
  end

  defp fetch_config(context) do
    case Map.fetch(context, :xochi_config) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, {:missing_context, :xochi_config}}
    end
  end

  # An operator's out-of-band signer pin (and, for tests, a pre-fetched
  # capability matrix) pass straight through to the protocol's signer resolution.
  defp signer_opts(context) do
    context
    |> Map.take([:deposit_attestation_signer, :capabilities])
    |> Map.to_list()
  end

  defp build_request(params) do
    %DepositRouteRequest{
      wallet: Map.fetch!(params, :wallet),
      from_chain_id: Map.fetch!(params, :from_chain_id),
      to_chain_id: Map.fetch!(params, :to_chain_id),
      from_token: Map.fetch!(params, :from_token),
      to_token: Map.fetch!(params, :to_token),
      from_amount: Map.fetch!(params, :amount_atomic),
      recipient_address: Map.fetch!(params, :recipient_address),
      slippage_bps: Map.get(params, :slippage_bps) || 50,
      trust_score: Map.get(params, :trust_score)
    }
  end

  defp summary(instructions) do
    Map.take(instructions, [
      :intent_id,
      :deposit_address,
      :deposit_deadline,
      :from_amount,
      :to_amount,
      :recipient_address
    ])
  end
end
