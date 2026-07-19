defmodule Raxol.ACP.Xochi.StableStealthOffering do
  @moduledoc """
  ACP offering for Xochi cross-chain stablecoin transfers with **stealth**
  settlement: the payout lands at a one-time ERC-5564 stealth address on
  **Ethereum L1** that only the recipient controls.

  Stealth is an **X -> L1** product. Cross-chain stealth is not live, so the
  destination must be Ethereum L1 (chain `1`); a non-Ethereum destination is
  rejected before escrow with `{:stealth_requires_l1_destination, dst}`, mirroring
  the Xochi frontend gate. The requirement's `settlement_preference` is fixed to
  `"stealth"` and a `stealth_meta_address` (the ERC-5564 spending/viewing keys the
  buyer also signed into the intent) is required, so a buyer agent gets a focused
  schema/validation error instead of a fill-time surprise. The deliverable
  requires the announcement fields (`stealth_address`, `ephemeral_pub_key`,
  `view_tag`) for on-chain verification.

  Validation and delivery are shared via `Raxol.ACP.Xochi.TransferCore`
  (`:stealth` mode); settler config is the shared `:xochi_transfer_settler`.
  """

  use Raxol.ACP.Offering,
    name: "xochi_stable_stealth",
    price_usdc: "0.25",
    sla_minutes: 10,
    cluster: "on_chain"

  alias Raxol.ACP.Xochi.{Offering, TransferCore}

  @impl true
  def requirements_schema, do: Offering.requirement_schema(:stealth)

  @impl true
  def deliverables_schema, do: Offering.deliverable_schema(:stealth)

  @impl true
  def handle_request(req, ctx), do: TransferCore.handle_request(req, ctx, :stealth)

  @impl true
  def handle_deliver(req, ctx), do: TransferCore.handle_deliver(req, ctx)
end
