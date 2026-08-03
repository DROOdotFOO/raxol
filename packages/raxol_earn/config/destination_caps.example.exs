import Config

# Offering liquidity gate for `Raxol.Earn.Xochi.TransferOffering` -- LAUNCH DRAFT.
#
# Values derived from the solver 0x97D447561fDe10E959E782a29411D8F89586d80b's
# on-chain balances (via Blockscout balanceOf, snapshot; refresh before launch).
# Merge these into the seller deployment's runtime config.
#
# `:destination_caps` -- max atomic units per single order, keyed by the
#   DESTINATION `{chain_id, token_address(lowercase)}` (the leg that actually
#   fills). Absent => unconstrained; `0` => corridor closed. Caps sit well under
#   the measured balance to leave headroom for concurrent in-flight settlements
#   and slippage; monitor aggregate open orders separately.
#
# `:closed_origins` -- src chains we reject before escrow regardless of quote.
#   Robinhood (4663) is USDG-origin-broken until the relay.link exit mover lands
#   (axol-io/Riddler#419); it still serves INBOUND (`*->4663 USDG`), which the
#   USDG destination cap below allows.

config :raxol_earn, :closed_origins, [
  # Robinhood outbound (USDG exit) is down -- riddler#419. Remove once fixed.
  4663
]

config :raxol_earn, :destination_caps, %{
  # --- USDC (6dp). Base holds ~96% of USDC ($48.8k); the rest is dust until the
  #     rebalancer (riddler#412) or a manual CCTP top-up spreads it. ---
  # Base       $48,841  -> 10,000 USDC/order
  {8453, "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"} => 10_000_000_000,
  # Ethereum   $1,710   -> 500 USDC/order (L1 gas is expensive; keep low)
  {1, "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"} => 500_000_000,
  # Polygon    $113     -> 100 USDC/order
  {137, "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359"} => 100_000_000,
  # Arbitrum   $146     -> 100 USDC/order
  {42_161, "0xaf88d065e77c8cc2239327c5edb3a432268e5831"} => 100_000_000,
  # Optimism   $52      -> closed (effectively empty)
  {10, "0x0b2c639c533813f4aa9d7837caf62653d097ff85"} => 0,

  # --- USDT (6dp). Barely funded; only Arbitrum is orderable. ---
  # Arbitrum   $150     -> 100 USDT/order
  {42_161, "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9"} => 100_000_000,
  # Base       $17      -> closed
  {8453, "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2"} => 0,

  # --- WETH (18dp, ~$1,877/ETH). Thin; small tickets only. ---
  # Base       0.247 WETH -> 0.15 WETH/order
  {8453, "0x4200000000000000000000000000000000000006"} => 150_000_000_000_000_000,
  # Ethereum   0.171 WETH -> 0.10 WETH/order
  {1, "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"} => 100_000_000_000_000_000,
  # Arbitrum   0.165 WETH -> 0.10 WETH/order
  {42_161, "0x82af49447d8a07e3bd95bd0d56f35241523fbab1"} => 100_000_000_000_000_000,

  # --- USDG (6dp) on Robinhood: INBOUND only (`*->4663`). ~$21k parked. ---
  # Robinhood  $21,059  -> 5,000 USDG/order
  {4663, "0x5fc5360d0400a0fd4f2af552add042d716f1d168"} => 5_000_000_000
}
