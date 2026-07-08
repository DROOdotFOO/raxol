defmodule Raxol.ACP.Xochi.Offering do
  @moduledoc """
  Xochi cross-chain intent offering schema for the Virtuals ACP marketplace.

  Raxol sells this as a **pure storefront**: the buyer quotes and signs a Xochi
  cross-chain intent against Xochi itself, then creates a **plain** ACP job
  (hook = `address(0)`) whose budget is raxol's storefront fee. On funding, the
  storefront relays the buyer's pre-signed intent to Xochi (via
  `Raxol.ACP.Xochi.Settler` -> `Raxol.Payments.Protocols.Xochi.execute_signed/2`)
  and polls it to settlement. raxol never signs the transfer and never touches
  the transferred funds -- the transfer moves through Xochi off-escrow, so the
  ACP core's platform/evaluator take never bites the transfer amount. raxol
  earns the storefront fee: on `complete`, the provider nets `budget * 0.90`.

  This module defines the offering's JSON schema (for marketplace registration),
  the canonical request shape (which carries the buyer's signed intent bundle),
  and the deliverable shape returned when the intent settles.

  ## Lifecycle

      job.created      -> buyer initiated a plain job, awaiting acceptance
      budget.set       -> storefront proposes budget = its fee (bps of transfer)
      job.funded       -> buyer escrowed the storefront fee
      job.submitted    -> storefront relayed the buyer's signed intent; solver
                          fills cross-chain; deliverable = { intent_id,
                          settlement_tx_hash, receiving_tx_hash, status }
      job.completed    -> buyer verifies dst_tx; provider nets budget*0.90

  The deliverable surfaces both src and dst transaction hashes so the buyer (or
  an evaluator agent) can verify the cross-chain settlement on-chain before
  approving.

  ## Safety: the buyer signs, Riddler verifies

  Because the buyer signs the EIP-712 intent (and any origin-pull authorization)
  against Xochi, and Riddler verifies it against its own server-persisted quote,
  neither raxol nor the buyer can forge the amount or route. raxol relays the
  opaque bundle without inspecting or re-signing it, so the destination, privacy
  tier, and route are whatever the buyer signed -- there is no same-owner or
  public-only gate on raxol's side (there is nothing raxol could misroute).

  ## Marketplace registration

  When registering the offering at https://app.virtuals.io/acp/new, the
  `requirement_schema/0` and `deliverable_schema/0` JSON Schemas below
  go into the `Job Offering` form. `request_schema/0` is what buyers
  fill out when creating a job.
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
          "The buyer may settle to a different recipient or an ERC-5564 stealth " <>
          "address by signing it into their intent; the storefront relays it verbatim.",
      required_funds: true,
      hook_kind: "none",
      sla_minutes: 10,
      requirement_schema: requirement_schema(),
      deliverable_schema: deliverable_schema(),
      tags: ["payments", "cross-chain", "stablecoin", "xochi"]
    }
  end

  @doc "JSON Schema for what the buyer must send when initiating a job."
  @spec requirement_schema() :: map()
  def requirement_schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "required" => [
        "src_chain_id",
        "dst_chain_id",
        "src_token",
        "dst_token",
        "amount_atomic",
        "signed_intent"
      ],
      "additionalProperties" => false,
      "properties" => %{
        "src_chain_id" => %{
          "type" => "integer",
          "description" => "Source chain ID (e.g. 8453 for Base mainnet)."
        },
        "dst_chain_id" => %{
          "type" => "integer",
          "description" => "Destination chain ID."
        },
        "src_token" => %{
          "type" => "string",
          "pattern" =>
            "^(0x[0-9a-fA-F]{40}|T[1-9A-HJ-NP-Za-km-z]{33}|[1-9A-HJ-NP-Za-km-z]{32,44})$",
          "description" =>
            "Token address being sent on src_chain_id: 0x-hex (EVM), " <>
              "Base58Check (Tron), or base58 mint (Solana). Validated " <>
              "per-chain against the solver capability matrix before escrow."
        },
        "dst_token" => %{
          "type" => "string",
          "pattern" =>
            "^(0x[0-9a-fA-F]{40}|T[1-9A-HJ-NP-Za-km-z]{33}|[1-9A-HJ-NP-Za-km-z]{32,44})$",
          "description" =>
            "Token address to be received on dst_chain_id: 0x-hex (EVM), " <>
              "Base58Check (Tron), or base58 mint (Solana). Validated " <>
              "per-chain against the solver capability matrix before escrow."
        },
        "amount_atomic" => %{
          "type" => "string",
          "pattern" => "^[0-9]+$",
          "description" =>
            "Transfer size in token base units (USDC: 1 USDC = 1_000_000). Used to " <>
              "size the storefront fee (bps of this) and to commit the deliverable " <>
              "amount; the on-chain amount is fixed by the buyer's signed intent."
        },
        "signed_intent" => %{
          "type" => "object",
          "required" => ["intent_id", "quote_id", "signature", "nonce"],
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
                "Optional ERC-3009/Permit2 origin-pull signature (absent for " <>
                  "non-pulling methods)."
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
              "the buyer's / evaluator's audit trail. raxol does not use or enforce " <>
              "it -- the destination is fixed by the buyer's signature."
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
              "records an ERC-5564 stealth delivery -- the buyer signed the stealth " <>
              "spending/viewing keys and an ephemeral recipient into their Xochi " <>
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
        }
      }
    }
  end

  @doc "Default SLA in minutes -- max time from `job.funded` to `job.submitted`."
  @spec sla_minutes() :: pos_integer()
  def sla_minutes, do: 10

  @doc """
  Whether a given requirement payload is well-formed enough to relay. Cheap
  shape check only -- confirms the corridor fields plus a `signed_intent` bundle
  carrying at least `intent_id`, `quote_id`, `signature`, and `nonce`. Does not
  verify the signature (Riddler does that against its persisted quote).
  """
  @spec valid_requirement?(map()) :: boolean()
  def valid_requirement?(req) when is_map(req) do
    required = ~w(src_chain_id dst_chain_id src_token dst_token amount_atomic signed_intent)

    Enum.all?(required, &Map.has_key?(req, &1)) and valid_signed_intent?(req["signed_intent"])
  end

  def valid_requirement?(_), do: false

  defp valid_signed_intent?(bundle) when is_map(bundle) do
    Enum.all?(~w(intent_id quote_id signature nonce), &Map.has_key?(bundle, &1))
  end

  defp valid_signed_intent?(_), do: false
end
