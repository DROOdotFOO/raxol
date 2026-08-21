defmodule Raxol.Earn.Xochi.Offering do
  @moduledoc """
  Xochi cross-chain intent offering schema for the Virtuals ACP marketplace.

  Raxol sells this as a pure storefront. The buyer quotes and signs a Xochi
  cross-chain intent against Xochi itself, then creates a plain ACP job
  (hook = `address(0)`) whose budget is raxol's storefront fee. On funding, the
  storefront relays the buyer's pre-signed intent to Xochi (via
  `Raxol.Earn.Xochi.Settler` then `Raxol.Payments.Protocols.Xochi.execute_signed/2`)
  and polls it to settlement. raxol never signs the transfer and never touches
  the transferred funds. The transfer moves through Xochi off-escrow, so the ACP
  core's platform and evaluator take never bites the transfer amount. raxol earns
  only the storefront fee: on `complete`, the provider nets `budget * 0.90`.

  This module holds the offering's JSON schemas: the request shape (which carries
  the buyer's signed intent bundle) and the deliverable shape returned when the
  intent settles.

  ## Which module to register

  Register the focused pair, not this base module directly:

    - `Raxol.Earn.Xochi.StablePublicOffering`  (name `xochi_stable_public`)
    - `Raxol.Earn.Xochi.StableStealthOffering` (name `xochi_stable_stealth`)

  Both share these schemas via the mode-specific `requirement_schema/1` and
  `deliverable_schema/1`. `Raxol.Earn.Xochi.TransferOffering` (name
  `xochi_cross_chain_transfer`) is the deprecated settlement-agnostic shim; it
  uses the full `requirement_schema/0` and stays only until buyers migrate.

  ## Lifecycle

      job.created      -> buyer initiated a plain job, awaiting acceptance
      budget.set       -> storefront proposes budget = its fee (bps of transfer)
      job.funded       -> buyer escrowed the storefront fee
      job.submitted    -> storefront relayed the buyer's signed intent; the solver
                          fills cross-chain; deliverable = { intent_id,
                          settlement_tx_hash, receiving_tx_hash, status }
                          plus the ERC-5564 announcement ({ settlement_type,
                          stealth_address, ephemeral_pub_key, view_tag }) for a
                          stealth settlement
      job.completed    -> buyer verifies dst_tx; provider nets budget*0.90

  The deliverable carries both the source and destination transaction hashes, so
  the buyer (or an evaluator agent) can verify the settlement on-chain before
  approving.

  ## Safety: the buyer signs, Riddler verifies

  The buyer signs the EIP-712 intent (and any origin-pull authorization) against
  Xochi, and Riddler verifies it against its own server-persisted quote. Neither
  raxol nor the buyer can forge the amount or route. raxol relays the opaque
  bundle without inspecting or re-signing it, so the destination, privacy tier,
  and route are whatever the buyer signed. There is no same-owner or public-only
  gate on raxol's side, because there is nothing raxol could misroute.

  ## Marketplace registration

  When registering at https://app.virtuals.io/acp/new, the mode-specific
  `requirement_schema/1` and `deliverable_schema/1` go into the `Job Offering`
  form. `offering_metadata/1` returns the full payload for the offerings API.
  """

  @doc """
  Offering metadata payload for Virtuals's marketplace API.

  Returns a map that can be JSON-encoded for `POST /offerings`. The
  shape mirrors the `Offering` type in acp-node-v2.
  """
  @spec offering_metadata() :: map()
  def offering_metadata do
    %{
      name: "xochi_cross_chain_transfer",
      display_name: "Xochi Cross-Chain Transfer",
      description:
        "Cross-chain stablecoin settlement storefront. The buyer signs a Xochi " <>
          "intent, the storefront relays it and returns the settlement tx hashes; " <>
          "the buyer escrows only the storefront fee (a plain job, no fund hook). " <>
          "Supported settlement: USDC and USDT each across the full 5-chain EVM mesh " <>
          "(Ethereum, Optimism, Polygon, Base, Arbitrum); USDG on Robinhood Chain (4663), " <>
          "cross-asset in both directions (USDC/USDT in -> USDG, and USDG -> USDC/USDT out " <>
          "on any mesh chain); and USDC<->USDT cross-asset conversion. Order size min " <>
          "$1.00, max bounded by the solver's per-token caps (e.g. USDT ~$1,000, USDG " <>
          "~$10,000). The buyer may settle publicly to a wallet, or privately to a " <>
          "one-time ERC-5564 stealth address on Ethereum L1, by signing the choice into " <>
          "their intent; the storefront relays it verbatim.",
      # No funds move through ACP: the buyer's capital moves via their signed Xochi
      # intent (off-ACP), so the job takes no fund hook. The listed fee is a
      # percentage (0.10 = 10 bps); price carries the value, not a USDC amount.
      required_funds: false,
      price_usdc: 0.10,
      price_type: "percentage",
      hook_kind: "none",
      sla_minutes: 10,
      requirement_schema: requirement_schema(),
      deliverable_schema: deliverable_schema(),
      tags: [
        "payments",
        "cross-chain",
        "stablecoin",
        "xochi",
        "usdc",
        "usdt",
        "usdg",
        "robinhood",
        "stealth",
        "privacy"
      ]
    }
  end

  @doc """
  JSON Schema for what the buyer must send when initiating a job.

  Only `signed_intent` is required: the storefront reads the authoritative
  corridor and amount from Xochi by the bundle's `intent_id` at accept time, so
  the buyer no longer hand-carries (and cannot misstate) `src_chain_id`,
  `dst_chain_id`, `src_token`, `dst_token`, or `amount_atomic`. Those remain as
  optional audit hints; raxol derives and enforces the real values.

  ## `pull_signature` is mandatory, which narrows this to pulling corridors

  The bundle requires a `pull_signature` for every mode. That is deliberate, and
  it means an ACP job can only ever be a corridor whose origin supports a gasless
  pull -- an EVM leg signing ERC-3009 or Permit2.

  A non-EVM origin (Tron, Solana) funds a `deposit_address` instead, so its buyer
  has no pull to sign and nothing to put here. `Raxol.Payments` models that case
  (`Protocols.Xochi.deposit_route_quote/3`, and a bundle whose `pull_signature`
  is nil for non-pulling methods), but the seller stack does not: every corridor
  in `Raxol.Earn.Xochi.CorridorAllowlist` is EVM, and `Raxol.Earn.Xochi.Settler`
  settles only by relaying a signed pull through `execute_signed/2`. Accepting a
  deposit-route job would therefore escrow a fee for work this stack cannot do.

  So the narrowing costs nothing today, and a corridor_allowlist_test guard fails
  if a non-pulling origin ever becomes quotable while this stays mandatory. At
  that point make `pull_signature` required per-mode in `requirement_schema/1`
  rather than in this shared base. See GitHub #665.
  """
  @spec requirement_schema() :: map()
  def requirement_schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "required" => ["signed_intent"],
      "additionalProperties" => false,
      "properties" => %{
        "src_chain_id" => %{
          "type" => "integer",
          "description" =>
            "Source chain ID. Supported: 1 (Ethereum), 10 (Optimism), 137 (Polygon), " <>
              "8453 (Base), 42161 (Arbitrum), and 4663 (Robinhood Chain). USDG lives " <>
              "only on 4663."
        },
        "dst_chain_id" => %{
          "type" => "integer",
          "description" =>
            "Destination chain ID. Supported: 1 (Ethereum), 10 (Optimism), 137 " <>
              "(Polygon), 8453 (Base), 42161 (Arbitrum), and 4663 (Robinhood Chain, as a " <>
              "USDG destination). Stealth settles on Ethereum L1 (1)."
        },
        "src_token" => %{
          "type" => "string",
          "pattern" =>
            "^(0x[0-9a-fA-F]{40}|T[1-9A-HJ-NP-Za-km-z]{33}|[1-9A-HJ-NP-Za-km-z]{32,44})$",
          "description" =>
            "Token address being sent on src_chain_id, as a 0x-hex EVM address. " <>
              "Supported tokens: USDC, USDT, and USDG (USDG on Robinhood Chain 4663 " <>
              "only). All supported chains are EVM; non-EVM legs (Tron, Solana) are not " <>
              "yet supported and are rejected before escrow. Validated per-chain against " <>
              "the solver capability matrix before escrow."
        },
        "dst_token" => %{
          "type" => "string",
          "pattern" =>
            "^(0x[0-9a-fA-F]{40}|T[1-9A-HJ-NP-Za-km-z]{33}|[1-9A-HJ-NP-Za-km-z]{32,44})$",
          "description" =>
            "Token address to be received on dst_chain_id, as a 0x-hex EVM address. " <>
              "Supported tokens: USDC, USDT, and USDG (USDG only on Robinhood Chain " <>
              "4663). Legs may be cross-asset (USDG in/out, or USDC<->USDT). All " <>
              "supported chains are EVM; non-EVM legs (Tron, Solana) are not yet " <>
              "supported and are rejected before escrow. Validated per-chain against the " <>
              "solver capability matrix before escrow."
        },
        "amount_atomic" => %{
          "type" => "string",
          "pattern" => "^[0-9]+$",
          "description" =>
            "Optional audit hint of the transfer size in token base units (USDC: " <>
              "1 USDC = 1_000_000). raxol does not trust it: the authoritative amount " <>
              "is read from Xochi by the signed intent's intent_id and is what sizes " <>
              "the storefront fee and the deliverable."
        },
        "signed_intent" => %{
          "type" => "object",
          "required" => ["intent_id", "quote_id", "signature", "nonce", "pull_signature"],
          "additionalProperties" => false,
          "description" =>
            "The buyer's pre-signed Xochi intent bundle. The buyer quotes and signs " <>
              "the EIP-712 intent against Xochi directly; the storefront relays it " <>
              "verbatim (Riddler verifies it against its own persisted quote, so the " <>
              "amount and route cannot be forged).",
          "properties" => %{
            "intent_id" => %{
              "type" => "string",
              "description" => "Xochi intent id the buyer signed."
            },
            "quote_id" => %{
              "type" => "string",
              "description" => "Xochi quote id the signature binds to."
            },
            "signature" => %{
              "type" => "string",
              "pattern" => "^0x[0-9a-fA-F]+$",
              "description" => "EIP-712 signature over the XochiIntent."
            },
            "nonce" => %{
              "type" => "integer",
              "minimum" => 0,
              "description" => "Worker replay-dedup nonce."
            },
            "pull_signature" => %{
              "type" => "string",
              "pattern" => "^0x[0-9a-fA-F]+$",
              "description" =>
                "ERC-3009 origin-pull signature. Required for USDC settlement: the " <>
                  "solver pulls the origin funds with this authorization, so a bundle " <>
                  "without it cannot settle."
            },
            "aztec_proof" => %{
              "type" => "string",
              "description" => "Optional shielded-claim proof."
            }
          }
        },
        "destination" => %{
          "type" => "string",
          "pattern" =>
            "^(0x[0-9a-fA-F]{40}|T[1-9A-HJ-NP-Za-km-z]{33}|[1-9A-HJ-NP-Za-km-z]{32,44})$",
          "description" =>
            "Optional: the recipient the buyer signed into their Xochi intent, for " <>
              "the buyer's or evaluator's audit trail, as a 0x-hex EVM address (all " <>
              "supported chains are EVM). raxol does not use or enforce it; the " <>
              "destination is fixed by the buyer's signature."
        },
        "slippage_bps" => %{
          "type" => "integer",
          "minimum" => 0,
          "maximum" => 1000,
          "default" => 50,
          "description" => "Optional audit hint; the buyer's signed quote fixes slippage."
        },
        "settlement_preference" => %{
          "type" => "string",
          "enum" => ["public", "private", "stealth"],
          "default" => "public",
          "description" =>
            "Optional audit hint of the privacy tier the buyer signed. \"stealth\" " <>
              "records an ERC-5564 stealth delivery to a one-time address on Ethereum " <>
              "L1 (chain 1; cross-chain stealth is not yet live): the buyer signed the " <>
              "stealth spending/viewing keys and an ephemeral recipient into their Xochi " <>
              "intent, so funds land at a stealth address they control. raxol relays " <>
              "whatever the buyer signed and does not gate on this."
        }
      }
    }
  end

  @doc "JSON Schema for what Xochi returns in `submit(deliverable)`."
  @spec deliverable_schema() :: map()
  def deliverable_schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "required" => ["intent_id", "settlement_tx_hash", "status"],
      "additionalProperties" => false,
      "properties" => %{
        "intent_id" => %{
          "type" => "string",
          "description" => "Xochi intent identifier returned by POST /xochi/quote."
        },
        "settlement_tx_hash" => %{
          "type" => "string",
          "pattern" => "^0x[0-9a-fA-F]{64}$",
          "description" =>
            "The authoritative settlement transaction hash. For an instant fill " <>
              "this is the destination delivery; for a two-leg bridge it is the " <>
              "origin leg (with the destination arrival in receiving_tx_hash)."
        },
        "receiving_tx_hash" => %{
          "type" => "string",
          "pattern" => "^0x[0-9a-fA-F]{64}$",
          "description" =>
            "The destination-arrival transaction hash for a two-leg settlement. " <>
              "Absent (null) for an instant single-tx fill."
        },
        "amount_atomic" => %{
          "type" => "string",
          "pattern" => "^[0-9]+$",
          "description" =>
            "The transfer amount settled, in token base units (matches the " <>
              "requirement's amount_atomic; committed so the deliverable hash pins " <>
              "what was moved)."
        },
        "status" => %{
          "type" => "string",
          "enum" => ["completed"],
          "description" => "Settlement lifecycle state; a delivered job is always completed."
        },
        "settlement_type" => %{
          "type" => "string",
          "enum" => ["public", "stealth", "shielded"],
          "description" =>
            "The privacy tier that settled, echoed from the poll status. Present " <>
              "only when the buyer signed a non-public intent."
        },
        "stealth_address" => %{
          "type" => "string",
          "pattern" => "^0x[0-9a-fA-F]{40}$",
          "description" =>
            "ERC-5564 stealth address the funds landed at (present only for a " <>
              "stealth settlement). A public on-chain announcement field, not the " <>
              "recipient's identity."
        },
        "ephemeral_pub_key" => %{
          "type" => "string",
          "pattern" => "^0x[0-9a-fA-F]+$",
          "description" =>
            "ERC-5564 ephemeral public key from the stealth announcement " <>
              "(present only for a stealth settlement)."
        },
        "view_tag" => %{
          "type" => "integer",
          "minimum" => 0,
          "maximum" => 255,
          "description" =>
            "ERC-5564 view tag byte from the stealth announcement " <>
              "(present only for a stealth settlement)."
        }
      }
    }
  end

  @doc """
  Requirement schema narrowed to a settlement mode.

  `:public` fixes `settlement_preference` to `"public"`. `:stealth` fixes it to
  `"stealth"`, pins `dst_chain_id` to Ethereum L1 (`1`), and requires the
  ERC-5564 `stealth_meta_address`. Built from `requirement_schema/0` so the two
  variants never drift from the shared corridor/intent fields.
  """
  @spec requirement_schema(:public | :usdc_public | :stealth) :: map()
  def requirement_schema(:public) do
    put_in(requirement_schema(), ["properties", "settlement_preference"], %{
      "type" => "string",
      "enum" => ["public"],
      "default" => "public",
      "description" => "Public settlement: the payout lands in a wallet on the destination chain."
    })
  end

  # USDC-only public settlement: `:public` plus both legs pinned to the CCTP
  # mesh. The chain enum derives from `Raxol.Payments.Assets.usdc_chains/0` so it
  # cannot drift from the runtime USDC gate in `UsdcPublicOffering`.
  def requirement_schema(:usdc_public) do
    requirement_schema(:public)
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

  def requirement_schema(:stealth) do
    requirement_schema()
    |> put_in(["properties", "settlement_preference"], %{
      "type" => "string",
      "enum" => ["stealth"],
      "default" => "stealth",
      "description" =>
        "Stealth settlement (ERC-5564): the payout lands at a one-time address on " <>
          "Ethereum L1 that only the recipient controls."
    })
    |> put_in(["properties", "dst_chain_id"], %{
      "type" => "integer",
      "const" => 1,
      "description" =>
        "Destination chain. Stealth settles on Ethereum L1, so this must be 1 " <>
          "(cross-chain stealth is not yet live)."
    })
    |> put_in(["properties", "stealth_meta_address"], %{
      "type" => "object",
      "required" => ["spending_pub_key", "viewing_pub_key"],
      "additionalProperties" => false,
      "description" =>
        "ERC-5564 stealth meta-address keys the buyer also signed into their intent, " <>
          "surfaced here so the offering can validate them before escrow and the " <>
          "deliverable can carry the on-chain announcement.",
      "properties" => %{
        "spending_pub_key" => %{"type" => "string", "pattern" => "^0x[0-9a-fA-F]+$"},
        "viewing_pub_key" => %{"type" => "string", "pattern" => "^0x[0-9a-fA-F]+$"}
      }
    })
    |> update_in(["required"], &(&1 ++ ["stealth_meta_address"]))
  end

  defp usdc_chain_prop(role) do
    %{
      "type" => "integer",
      "enum" => Raxol.Payments.Assets.usdc_chains(),
      "description" =>
        "#{role} chain. USDC settles across the CCTP mesh: " <>
          "1 (Ethereum), 10 (OP), 137 (Polygon), 8453 (Base), 42161 (Arbitrum)."
    }
  end

  @doc """
  Deliverable schema narrowed to a settlement mode. `:public` drops the stealth
  announcement fields; `:stealth` promotes them to `required`.
  """
  @spec deliverable_schema(:public | :usdc_public | :stealth) :: map()
  def deliverable_schema(:public) do
    update_in(deliverable_schema(), ["properties"], fn props ->
      Map.drop(props, ["settlement_type", "stealth_address", "ephemeral_pub_key", "view_tag"])
    end)
  end

  def deliverable_schema(:usdc_public), do: deliverable_schema(:public)

  def deliverable_schema(:stealth) do
    update_in(deliverable_schema(), ["required"], fn required ->
      required ++ ["settlement_type", "stealth_address", "ephemeral_pub_key", "view_tag"]
    end)
  end

  @doc "Marketplace metadata for a mode-specific offering (`:usdc_public` | `:public` | `:stealth`)."
  @spec offering_metadata(:usdc_public | :public | :stealth) :: map()
  def offering_metadata(:usdc_public) do
    %{
      name: "xochi_usdc_public",
      display_name: "Xochi USDC Transfer (Public)",
      description:
        "USDC-only cross-chain settlement to a wallet on the destination chain, across " <>
          "the CCTP mesh (Ethereum, Optimism, Polygon, Base, Arbitrum). The buyer signs a " <>
          "Xochi intent, the storefront relays it and returns the settlement tx hashes; " <>
          "the buyer escrows only the storefront fee (a plain job, no fund hook). Both " <>
          "legs must be USDC; other stablecoins are rejected before escrow. Order size is " <>
          "bounded (min 1 USDC, max 3,000 USDC).",
      required_funds: false,
      price_usdc: 0.10,
      price_type: "percentage",
      hook_kind: "none",
      sla_minutes: 10,
      requirement_schema: requirement_schema(:usdc_public),
      deliverable_schema: deliverable_schema(:usdc_public),
      tags: ["payments", "cross-chain", "stablecoin", "usdc", "xochi", "public"]
    }
  end

  def offering_metadata(:public) do
    %{
      name: "xochi_stable_public",
      display_name: "Xochi Stablecoin Transfer (Public)",
      description:
        "Cross-chain stablecoin settlement to a wallet on the destination chain. The " <>
          "buyer signs a Xochi intent, the storefront relays it and returns the " <>
          "settlement tx hashes; the buyer escrows only the storefront fee (a plain " <>
          "job, no fund hook).",
      required_funds: false,
      price_usdc: 0.10,
      price_type: "percentage",
      hook_kind: "none",
      sla_minutes: 10,
      requirement_schema: requirement_schema(:public),
      deliverable_schema: deliverable_schema(:public),
      tags: ["payments", "cross-chain", "stablecoin", "xochi", "public"]
    }
  end

  def offering_metadata(:stealth) do
    %{
      name: "xochi_stable_stealth",
      display_name: "Xochi Stablecoin Transfer (Stealth, Ethereum L1)",
      description:
        "Cross-chain stablecoin settlement to a one-time ERC-5564 stealth address on " <>
          "Ethereum L1 that only the recipient controls. Destination must be Ethereum " <>
          "(chain 1); cross-chain stealth is not yet live. The buyer signs a Xochi " <>
          "intent, the storefront relays it and returns the settlement tx hashes plus " <>
          "the stealth announcement for on-chain verification.",
      required_funds: false,
      price_usdc: 0.10,
      price_type: "percentage",
      hook_kind: "none",
      sla_minutes: 10,
      requirement_schema: requirement_schema(:stealth),
      deliverable_schema: deliverable_schema(:stealth),
      tags: ["payments", "cross-chain", "stablecoin", "xochi", "stealth", "privacy"]
    }
  end

  @doc "Default SLA in minutes: max time from `job.funded` to `job.submitted`."
  @spec sla_minutes() :: pos_integer()
  def sla_minutes, do: 10

  @doc """
  Whether a given requirement payload is well-formed enough to relay. A cheap
  shape check: it confirms a `signed_intent` bundle carrying at least
  `intent_id`, `quote_id`, `signature`, `nonce`, and `pull_signature`. The
  corridor (chains, tokens, amount) is NOT required here -- it is read
  authoritatively from Xochi by the intent id (see
  `Raxol.Earn.Xochi.IntentDeriver`). It does not verify the signature (Riddler
  does that against its persisted quote).

  Requiring `pull_signature` restricts this to corridors whose origin can sign a
  gasless pull; see `requirement_schema/0` for why that is safe while every
  allowlisted corridor is EVM, and what to change when one is not.
  """
  @spec valid_requirement?(map()) :: boolean()
  def valid_requirement?(req) when is_map(req) do
    valid_signed_intent?(req["signed_intent"])
  end

  def valid_requirement?(_), do: false

  defp valid_signed_intent?(bundle) when is_map(bundle) do
    Enum.all?(~w(intent_id quote_id signature nonce pull_signature), &Map.has_key?(bundle, &1))
  end

  defp valid_signed_intent?(_), do: false
end
