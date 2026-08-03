defmodule Raxol.Earn.Xochi.StablePublicOffering do
  @moduledoc """
  ACP offering for Xochi cross-chain stablecoin transfers with public
  settlement: the payout lands in a wallet on the destination chain.

  One of the split pair (see `Raxol.Earn.Xochi.StableStealthOffering`). It is
  narrower than the legacy `TransferOffering`: the requirement's
  `settlement_preference` is fixed to `"public"`, and the deliverable omits the
  ERC-5564 announcement fields. A requirement that declares a private or stealth
  tier is rejected before escrow with
  `{:wrong_offering, :expected_public, "xochi_stable_stealth"}`, so a buyer agent
  gets a focused, actionable error instead of an ambiguous failure.

  Validation and delivery are shared via `Raxol.Earn.Xochi.TransferCore` in
  `:public` mode; settler config is the shared `:xochi_transfer_settler`.
  """

  use Raxol.Earn.Offering,
    name: "xochi_stable_public",
    price_usdc: "0.25",
    sla_minutes: 10,
    cluster: "on_chain"

  alias Raxol.Earn.Xochi.{Offering, TransferCore}

  @impl true
  def requirements_schema, do: Offering.requirement_schema(:public)

  @impl true
  def deliverables_schema, do: Offering.deliverable_schema(:public)

  @impl true
  def handle_request(req, ctx), do: TransferCore.handle_request(req, ctx, :public)

  @impl true
  def handle_deliver(req, ctx), do: TransferCore.handle_deliver(req, ctx)
end
