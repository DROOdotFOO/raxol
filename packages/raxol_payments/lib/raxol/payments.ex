defmodule Raxol.Payments do
  @moduledoc """
  Autonomous payment capabilities for Raxol agents.

  Provides transparent HTTP 402 auto-pay (x402 and MPP protocols), wallet
  management, spending controls, and explicit cross-chain transfers via Xochi.

  ## Protocol Stack

  - **x402** (Coinbase): EIP-712 signed ERC-3009 transfers, auto-pay on HTTP 402
  - **MPP** (Stripe/Tempo): multi-method (Stripe fiat, Tempo stablecoins, EVM)
  - **Xochi**: cross-chain intents via dark pool (default for agents, cash-positive)
  - **Riddler**: direct solver access (B2B/internal, not default)

  ## Agent Path (cross-chain)

  Agents use Xochi for cross-chain transfers. Riddler solves intents
  behind the scenes. The flow is:

      Agent -> Xochi.quote -> Xochi.execute (signed) -> Riddler fills -> settled

  Tier-based fees (0.10% - 0.40%, by tier and asset) make this revenue-positive.

  ## Quick Start

      # Configure a wallet
      wallet = Raxol.Payments.Wallets.Env.new()

      # Auto-pay (HTTP 402, same-chain)
      backend_opts = [
        req_plugins: [
          {Raxol.Payments.Req.AutoPay, wallet: wallet, protocols: [:x402, :mpp]}
        ]
      ]

      # Cross-chain transfer via Xochi
      alias Raxol.Payments.Protocols.Xochi
      alias Raxol.Payments.Xochi.Schemas.QuoteRequest

      config = %{base_url: "https://api.xochi.fi", auth: {:mandate, wallet.address()}}

      request = %QuoteRequest{
        wallet: wallet.address(),
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8...",
        to_token: "0x8335...",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      {:ok, quote} = Xochi.get_quote(config, request)
      {:ok, exec} = Xochi.execute(config, quote, wallet)
      {:ok, status} = Xochi.poll_status(config, exec.intent_id)
  """
end
