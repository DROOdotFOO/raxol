defmodule Raxol.ACP.Xochi.TransferOffering do
  @moduledoc """
  DEPRECATED settlement-agnostic Xochi transfer offering (`xochi_cross_chain_transfer`).

  Superseded by the focused pair `Raxol.ACP.Xochi.StablePublicOffering` and
  `Raxol.ACP.Xochi.StableStealthOffering`, which give buyer agents narrower
  schemas and settlement-specific pre-escrow errors. This module stays registered
  for one release so existing `xochi_cross_chain_transfer` jobs keep settling; it
  relays whatever settlement the buyer signed (mode `:any`, no settlement gate),
  exactly as before. Remove it once buyers have migrated to the split offerings.

  All validation and delivery live in `Raxol.ACP.Xochi.TransferCore`; the schema
  is `Raxol.ACP.Xochi.Offering` (the legacy full schema that still advertises all
  three settlement tiers).
  """

  use Raxol.ACP.Offering,
    name: "xochi_cross_chain_transfer",
    price_usdc: "0.25",
    sla_minutes: 10,
    cluster: "on_chain"

  alias Raxol.ACP.Xochi.{Offering, TransferCore}

  @impl true
  def requirements_schema, do: Offering.requirement_schema()

  @impl true
  def deliverables_schema, do: Offering.deliverable_schema()

  @impl true
  def handle_request(req, ctx), do: TransferCore.handle_request(req, ctx, :any)

  @impl true
  def handle_deliver(req, ctx), do: TransferCore.handle_deliver(req, ctx)
end
