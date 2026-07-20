defmodule Raxol.ACP.Xochi.UsdcPublicOffering do
  @moduledoc """
  Launch offering: USDC-only cross-chain transfer with public settlement.

  The narrowest of the Xochi transfer offerings. It advertises exactly one thing --
  move USDC between the five CCTP chains `{1, 10, 137, 8453, 42_161}` and land the
  payout in a wallet on the destination chain. Both legs must resolve to a known
  USDC contract; a requirement whose src or dst token is anything else (USDT, USDG,
  WETH, ...) is rejected before escrow with
  `{:wrong_offering, :expected_usdc, "xochi_stable_public"}`, so a buyer agent gets a
  focused, actionable error and is pointed at the broader stablecoin offering.

  This is the clean rail: USDC settles via CCTP, the solver holds inventory on every
  hub, and there is no Permit2 verified-spender dependency (unlike USDT/USDG). It is
  the offering to register for the initial ACP launch; the token-agnostic
  `Raxol.ACP.Xochi.StablePublicOffering` / `TransferOffering` widen the scope once the
  other stablecoin rails are settle-ready.

  Validation beyond the USDC gate (cross-chain, positive amount, corridor allowlist,
  capacity) and delivery are the shared `Raxol.ACP.Xochi.TransferCore` in `:public`
  mode, so this offering never drifts from the common corridor rules; settler config
  is the shared `:xochi_transfer_settler`.
  """

  use Raxol.ACP.Offering,
    name: "xochi_usdc_public",
    price_usdc: "0.25",
    sla_minutes: 10,
    cluster: "on_chain"

  alias Raxol.ACP.Xochi.{Offering, TransferCore}
  alias Raxol.Payments.Assets

  # The five CCTP chains USDC settles across (full mesh). Mirrors
  # CorridorAllowlist's @usdc_chains and Riddler's @usdc_chains.
  @cctp_chains [1, 10, 137, 8453, 42_161]

  @impl true
  def requirements_schema do
    Offering.requirement_schema(:public)
    |> put_in(["properties", "src_chain_id"], usdc_chain_prop("Source"))
    |> put_in(["properties", "dst_chain_id"], usdc_chain_prop("Destination"))
    |> put_in(
      ["properties", "src_token", "description"],
      "The USDC contract on src_chain_id. Only USDC is accepted; a non-USDC token is rejected before escrow."
    )
    |> put_in(
      ["properties", "dst_token", "description"],
      "The USDC contract on dst_chain_id. Only USDC is accepted; a non-USDC token is rejected before escrow."
    )
  end

  @impl true
  def deliverables_schema, do: Offering.deliverable_schema(:public)

  @impl true
  def handle_request(req, ctx) do
    if usdc_leg?(req["src_chain_id"], req["src_token"]) and
         usdc_leg?(req["dst_chain_id"], req["dst_token"]) do
      TransferCore.handle_request(req, ctx, :public)
    else
      {:reject, {:wrong_offering, :expected_usdc, "xochi_stable_public"}}
    end
  end

  @impl true
  def handle_deliver(req, ctx), do: TransferCore.handle_deliver(req, ctx)

  defp usdc_leg?(chain_id, token), do: Assets.usdc?(chain_id, token)

  defp usdc_chain_prop(role) do
    %{
      "type" => "integer",
      "enum" => @cctp_chains,
      "description" =>
        "#{role} chain. USDC settles across the CCTP mesh: " <>
          "1 (Ethereum), 10 (OP), 137 (Polygon), 8453 (Base), 42161 (Arbitrum)."
    }
  end
end
