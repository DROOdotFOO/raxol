defmodule Raxol.Earn.Xochi.UsdcPublicOffering do
  @moduledoc """
  Launch offering: USDC-only cross-chain transfer with public settlement.

  The narrowest of the Xochi transfer offerings, and the only one registered by
  default (see `Raxol.Earn.Seller.Offerings`). It advertises exactly one thing --
  move USDC across the CCTP settlement mesh (`Raxol.Payments.Assets.usdc_chains/0`)
  and land the payout in a wallet on the destination chain. Both legs must resolve
  to a known USDC contract; a requirement whose src or dst token is anything else
  (USDT, USDG, WETH, ...) is rejected before escrow with
  `{:wrong_offering, :expected_usdc}`. There is deliberately no fallback offering
  named: the other stablecoin rails (USDT/USDG) are not settle-ready, so pointing a
  buyer at them would route real funds into a settlement that reverts. The scope
  widens only once those rails land and their offerings are added to the seller
  config.

  This is the clean rail: USDC settles via CCTP, the solver holds inventory on every
  hub, and there is no Permit2 verified-spender dependency (unlike USDT/USDG).

  Order size is bounded here, in USDC base units: a minimum (anti-spam) and a
  maximum ceiling, both overridable via `config :raxol_earn, :usdc_public_min_atomic`
  / `:usdc_public_max_atomic` (defaults: 1 USDC and 3_000 USDC). The maximum is a
  static ceiling only; per-corridor inventory-depth gating is the separate,
  opt-in capacity ledger (`capacity_gate_enabled`), which is inert unless
  configured.

  Validation beyond the USDC gate and the order band (cross-chain, positive amount,
  corridor allowlist, and -- when enabled -- capacity) and delivery are the shared
  `Raxol.Earn.Xochi.TransferCore` in `:public` mode, so this offering never drifts
  from the common corridor rules; settler config is the shared
  `:xochi_transfer_settler`.
  """

  use Raxol.Earn.Offering,
    name: "xochi_usdc_public",
    fee_bps: 8,
    sla_minutes: 10,
    cluster: "on_chain"

  alias Raxol.Earn.AssetToken
  alias Raxol.Earn.Xochi.{IntentDeriver, Offering, TransferCore}
  alias Raxol.Payments.Assets

  # USDC base units (6 decimals): 1 USDC and 3_000 USDC.
  @default_min_atomic 1_000_000
  @default_max_atomic 3_000_000_000

  @impl true
  def requirements_schema, do: Offering.requirement_schema(:usdc_public)

  @impl true
  def deliverables_schema, do: Offering.deliverable_schema(:usdc_public)

  @doc """
  Accept-time derivation: read the buyer's intent from Xochi by `intent_id`,
  replace the buyer-declared corridor/amount with the authoritative values, and
  size the storefront fee as `fee_bps` of the authoritative principal.

  raxol never trusts the relayed amount: the buyer signed one number against
  Xochi and Riddler verifies the signature against that persisted quote, so the
  `from_amount` on the `:quoted` intent is what settles. Fails closed -- a
  missing intent id, no Xochi config, an unreachable/unknown intent, a
  non-`:quoted` state, or a malformed amount all reject before any on-chain
  write.
  """
  @impl true
  def resolve_accept(req, %{chain_id: chain_id, xochi_config: xochi_config}) do
    with {:ok, %{intent: intent, from_amount: principal}} <-
           IntentDeriver.resolve(xochi_config, req) do
      budget = AssetToken.usdc_from_raw(div(principal * fee_bps(), 10_000), chain_id)
      {:ok, derive_corridor(req, intent), budget}
    end
  end

  @impl true
  def handle_request(req, ctx) do
    with :ok <- usdc_only(req),
         :ok <- within_order_band(req) do
      TransferCore.handle_request(req, ctx, :public)
    end
  end

  @impl true
  def handle_deliver(req, ctx), do: TransferCore.handle_deliver(req, ctx)

  # Overwrite the buyer-declared corridor/amount with Xochi's authoritative
  # values so the downstream USDC + order-band gates and the deliverable run on
  # what was actually signed. The opaque `signed_intent` and any settlement hint
  # are left untouched.
  defp derive_corridor(req, intent) do
    Map.merge(req, %{
      "src_chain_id" => intent.from_chain_id,
      "dst_chain_id" => intent.to_chain_id,
      "src_token" => intent.from_token,
      "dst_token" => intent.to_token,
      "amount_atomic" => intent.from_amount
    })
  end

  defp usdc_only(req) do
    if usdc_leg?(req["src_chain_id"], req["src_token"]) and
         usdc_leg?(req["dst_chain_id"], req["dst_token"]) do
      :ok
    else
      {:reject, {:wrong_offering, :expected_usdc}}
    end
  end

  # A malformed/absent amount defers to TransferCore's own positive-amount and
  # malformed-requirement guards rather than being masked as a band violation.
  defp within_order_band(req) do
    min = min_atomic()
    max = max_atomic()

    case parse_amount(req["amount_atomic"]) do
      {:ok, amount} when amount < min -> {:reject, {:order_below_min, min}}
      {:ok, amount} when amount > max -> {:reject, {:order_above_max, max}}
      _ -> :ok
    end
  end

  defp usdc_leg?(chain_id, token), do: Assets.usdc?(chain_id, token)

  defp parse_amount(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_amount(_), do: :error

  defp min_atomic,
    do: Application.get_env(:raxol_earn, :usdc_public_min_atomic, @default_min_atomic)

  defp max_atomic,
    do: Application.get_env(:raxol_earn, :usdc_public_max_atomic, @default_max_atomic)
end
