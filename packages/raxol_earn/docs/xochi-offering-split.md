# Scope: split the Xochi ACP offering into stables-public + stables-stealth

## Why

Today there is one settlement-agnostic offering, `Raxol.Earn.Xochi.TransferOffering`
(`xochi_cross_chain_transfer`). It relays whatever the buyer signed and deliberately
does **not** gate on settlement type; Riddler verifies the signed intent, so there is
nothing raxol could misroute. That is correct for safety, but it hurts **agent DX**:

- One broad job-offering JSON is hard for buyer agents to conform to reliably.
- `settlement_preference` is a free "audit hint" (`public | private | stealth`), so an
  agent can ask for stealth on a route stealth can't settle and only find out at fill.
- The deliverable schema carries stealth-only fields (`stealth_address`, `view_tag`, …)
  that are noise for a public transfer.

Splitting into two narrower offerings gives agents **focused, self-describing schemas
and actionable pre-escrow errors**: e.g. an agent requesting a stealth settlement to an
L2 destination gets a clean `stealth_requires_l1_destination` rejection instead of an
ambiguous downstream failure. This mirrors the Xochi frontend, which now gates stealth to
L1 destinations (stealth is an **X→L1 / L1↔L1** product; cross-chain stealth is roadmap).

This is a DX/clarity change, not a security change. Riddler remains the enforcer.

The settlement-agnostic `xochi_cross_chain_transfer` document is retained as the single
"covers-everything" listing: one offering whose schema spans public/private/stealth across
every supported token and chain. It self-describes the live corridor set (kept in lockstep
with `Raxol.Earn.Xochi.CorridorAllowlist`, which mirrors the deployed Riddler route tables in
`ansible-riddler`): USDC and USDT each across the full 5-chain EVM mesh, USDG on Robinhood
Chain (4663) cross-asset in both directions (in from and out to USDC/USDT on any mesh
chain), USDC<->USDT conversion, and ERC-5564 stealth to Ethereum L1. Its generated artifact
is `priv/offering.json` (`mix earn.register_offering --offering legacy`); the narrower
USDC-only listing stays at `priv/offering.usdc_public.json`.

## The two offerings

| | `xochi_stable_public` | `xochi_stable_stealth` |
|---|---|---|
| display_name | Xochi Stablecoin Transfer (Public) | Xochi Stablecoin Transfer (Stealth, Ethereum L1) |
| settlement | public wallet on the destination chain | ERC-5564 stealth address on **Ethereum L1** |
| `dst_chain_id` | any supported chain | **must be `1`** (Ethereum L1) |
| `settlement_preference` | enum fixed `["public"]`, default `public` | enum fixed `["stealth"]`, default `stealth` |
| extra required field | - | `stealth_meta_address { spending_pub_key, viewing_pub_key }` |
| deliverable | omits stealth announcement fields | **requires** `settlement_type:"stealth"`, `stealth_address`, `ephemeral_pub_key`, `view_tag` |
| price_usdc / sla | unchanged (`0.25` / 10) | unchanged (`0.25` / 10) |
| tags | `[payments, cross-chain, stablecoin, xochi, public]` | `[payments, cross-chain, stablecoin, xochi, stealth, privacy]` |

Both keep the storefront model verbatim: plain job (hook `none`), budget = the 8-bps
Raxol fee, buyer signs the Xochi intent, raxol relays via `Settler`, funds move
off-escrow. The 8-bps figure and the ACP-core 10%-of-budget math are unchanged.

## Refactor shape

Extract the shared implementation of the current `TransferOffering` into
`Raxol.Earn.Xochi.TransferCore` (plain module, no `use`): `validate_requirement/2`
(taking a `settlement_mode`), `deliver/1`, capacity reserve/confirm/release,
`capabilities/0`, corridor/liquidity guards, `resolve_settler/0`, `present/1`. All the
existing logic moves here unchanged.

Then two thin offering modules `use Raxol.Earn.Offering` and delegate:

```elixir
defmodule Raxol.Earn.Xochi.StablePublicOffering do
  use Raxol.Earn.Offering, name: "xochi_stable_public", price_usdc: "0.25",
    sla_minutes: 10, cluster: "on_chain"

  alias Raxol.Earn.Xochi.{TransferCore, Offering.Public}

  @impl true
  def requirements_schema, do: Public.requirement_schema()
  @impl true
  def deliverables_schema, do: Public.deliverable_schema()
  @impl true
  def handle_request(req, ctx), do: TransferCore.handle_request(req, ctx, :public)
  @impl true
  def handle_deliver(req, ctx), do: TransferCore.handle_deliver(req, ctx)
end

defmodule Raxol.Earn.Xochi.StableStealthOffering do
  use Raxol.Earn.Offering, name: "xochi_stable_stealth", price_usdc: "0.25",
    sla_minutes: 10, cluster: "on_chain"

  alias Raxol.Earn.Xochi.{TransferCore, Offering.Stealth}

  @impl true
  def requirements_schema, do: Stealth.requirement_schema()
  @impl true
  def deliverables_schema, do: Stealth.deliverable_schema()
  @impl true
  def handle_request(req, ctx), do: TransferCore.handle_request(req, ctx, :stealth)
  @impl true
  def handle_deliver(req, ctx), do: TransferCore.handle_deliver(req, ctx)
end
```

`Raxol.Earn.Xochi.TransferOffering` stays as a thin deprecated shim delegating to
`:public` for one release (existing `xochi_cross_chain_transfer` jobs keep working), then
is removed. Split `Offering` schema into `Offering.Public` / `Offering.Stealth` (share the
corridor-field + `signed_intent` sub-schema via a private `base_properties/0`).

## The settlement-mode gate (the focused errors)

Add to `TransferCore.validate_requirement/2`, keyed on `mode`, running **before escrow**
inside the existing `cond` (after the malformed/amount checks, before corridor gating):

```elixir
# declared settlement must match the offering the agent chose
mode == :public and declared_settlement(req) not in ["public", nil] ->
  {:error, {:wrong_offering, expected: :public, declared: declared_settlement(req),
            use: "xochi_stable_stealth"}}

mode == :stealth and declared_settlement(req) != "stealth" ->
  {:error, {:wrong_offering, expected: :stealth, declared: declared_settlement(req),
            use: "xochi_stable_public"}}

# stealth is X->L1 only; cross-chain stealth is not live
mode == :stealth and req["dst_chain_id"] != 1 ->
  {:error, {:stealth_requires_l1_destination, req["dst_chain_id"]}}

# focused schema error: the stealth offering needs the ERC-5564 keys up front
mode == :stealth and not valid_stealth_meta?(req["stealth_meta_address"]) ->
  {:error, :stealth_meta_address_required}
```

`declared_settlement/1` reads the requirement's `settlement_preference` (default
`"public"`). Note this gates on the **declared** field, not the opaque signature; raxol
still can't inspect the signed intent, but the declared field + `dst_chain_id` are enough
to give the agent a focused pre-escrow rejection and keep the wrong request out of escrow.
Riddler remains the source of truth at fill.

All existing rejections (`not_cross_chain`, `unsupported_src/dst_token`,
`unsupported_corridor`, `origin_closed`, `over_capacity`, `invalid_address`) are unchanged
and shared.

## Schema deltas

**Public requirement:** current schema, but `settlement_preference.enum = ["public"]`,
`default "public"`, description trimmed to "public settlement to the destination wallet."
**Public deliverable:** drop `settlement_type`, `stealth_address`, `ephemeral_pub_key`,
`view_tag`.

**Stealth requirement:** current schema, plus
- `settlement_preference.enum = ["stealth"]`, default `"stealth"`.
- `dst_chain_id`: `const: 1` (or `enum: [1]`) with description "Stealth settles on
  Ethereum L1; destination must be chain 1."
- new required `stealth_meta_address` object: `{ spending_pub_key: 0x-hex-33/65,
  viewing_pub_key: 0x-hex-33/65 }` (the ERC-5564 keys the buyer also signed into the
  intent; surfaced here for a focused schema error and the deliverable's announcement).
**Stealth deliverable:** promote `settlement_type` (const `"stealth"`), `stealth_address`,
`ephemeral_pub_key`, `view_tag` into `required`.

## Registration + config

`Raxol.Earn.Seller.Offerings` default becomes
`[StablePublicOffering, StableStealthOffering, TransferOffering]` (the third deprecated,
removed next cycle). `mix earn.register_offering` registers both new offerings from their
`offering_metadata/0`. `:xochi_transfer_settler` config is shared (one settler, both
offerings). `CorridorAllowlist` is reused; the stealth `dst == 1` gate composes on top.

## Tests (ExUnit)

Per offering, table-driven:
- **public:** accepts a supported stablecoin corridor with `settlement_preference` absent
  or `"public"`; rejects `"stealth"` with `{:wrong_offering, expected: :public, …}`;
  existing corridor/amount/address rejections still fire.
- **stealth:** accepts a corridor with `dst_chain_id == 1`, `settlement_preference:
  "stealth"`, and a valid `stealth_meta_address`; rejects `dst_chain_id != 1` with
  `{:stealth_requires_l1_destination, dst}`; rejects missing `stealth_meta_address` with
  `:stealth_meta_address_required`; rejects `settlement_preference: "public"` with
  `{:wrong_offering, expected: :stealth, …}`.
- **shared:** `TransferCore` unit tests (delivery relay, capacity) unchanged; a shim test
  that `TransferOffering` still delegates to `:public`.

## Docs

`xochi/docs/planning/economics.md` "ACP channel take rate" + launch decision #2: replace
"public-only at launch, stealth not live" with the two-offering model (public + stealth),
note stealth is X→L1 (dst = chain 1), keep the 8-bps / off-escrow math. (Tracked
separately.)

## Not changing

Pricing (8 bps storefront), the off-escrow principal flow, the settler/relay path, the
capability-matrix corridor gate, and the "buyer signs, Riddler verifies" safety model.
