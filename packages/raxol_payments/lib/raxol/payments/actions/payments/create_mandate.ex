defmodule Raxol.Payments.Actions.Payments.CreateMandate do
  @moduledoc """
  Agent Action that issues a Xochi delegation envelope from the
  caller's wallet to a specified agent wallet.
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_create_mandate",
    description:
      "Issue a Xochi delegation envelope: sign an EIP-712 Mandate authorizing a specific agent wallet to call scoped Xochi endpoints within a budget. Returns the base64url envelope to present in X-Xochi-Delegation.",
    schema: [
      input: [
        agent_wallet: [
          type: :string,
          required: true,
          description: "Agent address (0x...) that will present this envelope"
        ],
        scopes: [
          type: {:list, :string},
          required: true,
          description: "Allowed scopes: any of quote, execute, stealth_claim"
        ],
        max_amount_usd: [
          type: :integer,
          required: true,
          description: "Total authorized notional in USD cents (0 disables the cap)"
        ],
        max_calls: [
          type: :integer,
          required: true,
          description: "Hard cap on call count"
        ],
        expires_at: [
          type: :integer,
          required: true,
          description: "Envelope expiry as unix seconds"
        ],
        nonce: [
          type: :string,
          description: "Optional 0x-prefixed 32-byte hex nonce; random if omitted"
        ]
      ],
      output: [
        envelope: [
          type: :string,
          description: "Base64url-encoded envelope for X-Xochi-Delegation"
        ],
        envelope_hash: [type: :string, description: "0x-prefixed keccak256(envelope)"],
        human_wallet: [type: :string],
        agent_wallet: [type: :string],
        expires_at: [type: :integer]
      ]
    ]

  alias Raxol.Payments.Mandate
  alias Raxol.Payments.Mandate.Store

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  @impl true
  def run(params, context) do
    with {:ok, signed} <- issue_mandate(params, context),
         :ok <- Store.put(signed),
         {:ok, envelope} <- Mandate.to_envelope(signed) do
      {:ok, summary(signed, envelope)}
    end
  end

  defp issue_mandate(params, context) do
    with {:ok, wallet} <- fetch_wallet(context),
         attrs <- build_attrs(params, wallet),
         {:ok, mandate} <- Mandate.build(attrs) do
      Mandate.sign(mandate, wallet)
    end
  end

  defp summary(signed, envelope) do
    %{
      envelope: envelope,
      envelope_hash: "0x" <> Base.encode16(signed.envelope_hash, case: :lower),
      human_wallet: signed.human_wallet,
      agent_wallet: signed.agent_wallet,
      expires_at: signed.expires_at
    }
  end

  defp fetch_wallet(context) do
    case Map.fetch(context, :wallet) do
      {:ok, wallet} -> {:ok, wallet}
      :error -> {:error, :missing_wallet}
    end
  end

  defp build_attrs(params, wallet) do
    base = %{
      human_wallet: wallet.address(),
      agent_wallet: Map.get(params, :agent_wallet),
      scopes: Map.get(params, :scopes),
      max_amount_usd: Map.get(params, :max_amount_usd),
      max_calls: Map.get(params, :max_calls),
      expires_at: Map.get(params, :expires_at)
    }

    case Map.get(params, :nonce) do
      nil -> base
      nonce -> Map.put(base, :nonce, nonce)
    end
  end
end
