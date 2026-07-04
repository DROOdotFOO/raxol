# Buyer-side: produce the `signed_intent` bundle for the "Xochi Cross-Chain
# Transfer" ACP offering, then assemble the job requirement raxol relays.
#
# raxol sells the transfer as a PURE STOREFRONT: the buyer quotes and signs the
# Xochi intent itself (raxol never sees the key and never signs), and hands raxol
# the opaque `signed_intent` bundle. raxol relays it via
# `Raxol.Payments.Protocols.Xochi.execute_signed/2` and returns the settlement tx
# hashes. The transfer settles through Xochi off-escrow; the ACP job budget is
# only raxol's storefront fee (8 bps of the transfer, the Standard-tier routing
# rate).
#
# Run (needs a funded key + a Xochi Member token or mandate):
#
#     BUYER_PRIVATE_KEY=0x... XOCHI_MEMBER_TOKEN=... \
#       mix run examples/buyer_signed_intent.exs
#
# Without BUYER_PRIVATE_KEY it prints the shapes without hitting the network.

alias Raxol.Payments.Protocols.Xochi
alias Raxol.Payments.Xochi.Schemas.QuoteRequest

# The buyer's wallet holds the origin funds. raxol never sees this key.
defmodule BuyerWallet do
  use Raxol.Payments.Wallets.Env, env_var: "BUYER_PRIVATE_KEY"
end

# USDC, Base -> Arbitrum, 1.0 USDC. `wallet` is BOTH funder and recipient (Xochi
# has no separate recipient field), so funds arrive at your own address on dst.
build_request = fn wallet_address ->
  %QuoteRequest{
    wallet: wallet_address,
    from_chain_id: 8453,
    to_chain_id: 42_161,
    from_token: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    to_token: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    from_amount: "1000000",
    settlement_preference: "public",
    slippage_bps: 50
  }
end

# Assemble the ACP job requirement from a bundle (atom-keyed) -- stringify the
# bundle keys for JSON transport. This is what a buyer submits as the job
# requirement to the "xochi_cross_chain_transfer" offering.
build_requirement = fn request, bundle ->
  %{
    "src_chain_id" => request.from_chain_id,
    "dst_chain_id" => request.to_chain_id,
    "src_token" => request.from_token,
    "dst_token" => request.to_token,
    "amount_atomic" => request.from_amount,
    "signed_intent" => Map.new(bundle, fn {k, v} -> {to_string(k), v} end)
  }
end

case System.get_env("BUYER_PRIVATE_KEY") do
  nil ->
    # No key -- show the shapes with a placeholder bundle (no network call).
    request = build_request.("0xYOUR_WALLET")

    bundle = %{
      intent_id: "xi_<from Xochi>",
      quote_id: "xq_<from Xochi>",
      signature: "0x<EIP-712 signature over the XochiIntent>",
      nonce: 0,
      pull_signature: "0x<ERC-3009/Permit2 origin-pull signature>"
    }

    IO.puts("(set BUYER_PRIVATE_KEY + XOCHI_MEMBER_TOKEN to sign for real)\n")
    IO.puts("signed_intent bundle (shape):")
    IO.inspect(bundle, pretty: true)
    IO.puts("\nACP job requirement (hand this to the offering):")
    IO.puts(Jason.encode!(build_requirement.(request, bundle), pretty: true))

  _key ->
    request = build_request.(BuyerWallet.address())

    # Xochi config. Auth here is a Member token; also {:mandate, agent_wallet}
    # or {:x402, wallet: BuyerWallet}. See Raxol.Payments.Xochi.Client.
    config = %{
      base_url: System.get_env("XOCHI_URL", "https://api.xochi.fi"),
      auth_token: System.get_env("XOCHI_MEMBER_TOKEN", "")
    }

    # Quote + sign in one call. raxol never sees the key; the bundle is what you
    # hand the storefront.
    case Xochi.quote_and_sign(config, request, BuyerWallet) do
      {:ok, bundle} ->
        IO.puts("signed_intent bundle:")
        IO.inspect(bundle, pretty: true)
        IO.puts("\nACP job requirement (hand this to the offering):")
        IO.puts(Jason.encode!(build_requirement.(request, bundle), pretty: true))

      {:error, reason} ->
        IO.puts("quote_and_sign failed: #{inspect(reason)}")
        IO.puts("(needs a funded key + a valid Xochi auth token / mandate)")
    end
end
