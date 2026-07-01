defmodule Raxol.ACP.Xochi.Offering do
  @moduledoc """
  Draft Xochi cross-chain intent offering schema for the Virtuals ACP
  marketplace.

  Xochi launches as a **fund-transfer agent**: the buyer creates a job
  whose hookAddress is the v2 `FundTransferHook`, escrows funds, and
  the Xochi solver agent uses `setBudgetWithFundRequest(budget,
  transferAmount, destination)` to (a) take its service fee from the
  escrow and (b) route the rest through Xochi's quote+execute flow to
  the buyer-specified destination on a different chain.

  This module defines the offering's JSON schema (for marketplace
  registration), the canonical request shape, and the deliverable
  shape Xochi returns when the intent settles.

  ## Lifecycle

      job.created      -> buyer initiated, awaiting provider acceptance
      budget.set       -> Xochi quoted; budget = service fee in USDC
      job.funded       -> buyer escrowed the full transfer + fee
      job.submitted    -> Xochi.execute returned an intent_id; solver
                          fills cross-chain; deliverable = { intent_id,
                          src_tx_hash, dst_tx_hash, status }
      job.completed    -> buyer verifies dst_tx; FundTransferHook
                          releases escrow

  The deliverable surfaces both src and dst transaction hashes so the
  buyer (or an evaluator agent) can verify the cross-chain settlement
  on-chain before approving.

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
        "Atomic cross-chain stablecoin transfer via Xochi intents. " <>
          "Buyer escrows USDC on src chain, Xochi delivers to a recipient " <>
          "on the dst chain, FundTransferHook releases service fee on settle.",
      required_funds: true,
      hook_kind: "fund_transfer",
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
        "destination",
        "slippage_bps"
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
          "pattern" => "^0x[0-9a-fA-F]{40}$",
          "description" => "ERC-20 address being sent on src_chain_id."
        },
        "dst_token" => %{
          "type" => "string",
          "pattern" => "^0x[0-9a-fA-F]{40}$",
          "description" => "ERC-20 address to be received on dst_chain_id."
        },
        "amount_atomic" => %{
          "type" => "string",
          "pattern" => "^[0-9]+$",
          "description" => "Source amount in token base units (USDC: 1 USDC = 1_000_000)."
        },
        "destination" => %{
          "type" => "string",
          "pattern" => "^0x[0-9a-fA-F]{40}$",
          "description" =>
            "Recipient on dst_chain_id. Not yet honored: settlement currently " <>
              "delivers to the requester's own address on dst_chain_id. Delivery " <>
              "to a different recipient is a future release; this field is kept " <>
              "so requirements are forward-compatible."
        },
        "slippage_bps" => %{
          "type" => "integer",
          "minimum" => 0,
          "maximum" => 1000,
          "default" => 50,
          "description" => "Acceptable slippage in basis points (50 = 0.5%)."
        },
        "settlement_preference" => %{
          "type" => "string",
          "enum" => ["public", "private"],
          "default" => "public",
          "description" =>
            "Settlement privacy. 'private' uses Xochi's dark pool path; 'public' uses standard solver routing."
        },
        "stealth_spending_pub_key" => %{
          "type" => "string",
          "pattern" => "^0x[0-9a-fA-F]+$",
          "description" => "Optional stealth-address spending pubkey for shielded settlement."
        },
        "stealth_viewing_pub_key" => %{
          "type" => "string",
          "pattern" => "^0x[0-9a-fA-F]+$",
          "description" => "Optional stealth-address viewing pubkey."
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
      "required" => ["intent_id", "src_tx_hash", "status"],
      "additionalProperties" => false,
      "properties" => %{
        "intent_id" => %{
          "type" => "string",
          "description" => "Xochi intent identifier returned by POST /xochi/quote."
        },
        "quote_id" => %{
          "type" => "string",
          "description" => "Xochi quote identifier (audit trail)."
        },
        "src_tx_hash" => %{
          "type" => "string",
          "pattern" => "^0x[0-9a-fA-F]{64}$",
          "description" => "Transaction hash on src_chain_id (intent lock)."
        },
        "dst_tx_hash" => %{
          "type" => "string",
          "pattern" => "^0x[0-9a-fA-F]{64}$",
          "description" => "Transaction hash on dst_chain_id (intent fill). Absent until settled."
        },
        "status" => %{
          "type" => "string",
          "enum" => ["pending", "settled", "failed", "refunded"],
          "description" => "Lifecycle state of the Xochi intent."
        },
        "fee_atomic" => %{
          "type" => "string",
          "pattern" => "^[0-9]+$",
          "description" => "Xochi service fee charged in USDC base units."
        },
        "dst_amount_atomic" => %{
          "type" => "string",
          "pattern" => "^[0-9]+$",
          "description" => "Amount actually received on dst_chain_id (post-slippage)."
        }
      }
    }
  end

  @doc "Default SLA in minutes -- max time from `job.funded` to `job.submitted`."
  @spec sla_minutes() :: pos_integer()
  def sla_minutes, do: 10

  @doc """
  Whether a given requirement payload is well-formed enough to start
  signing a Xochi quote. Cheap shape check only -- does not call
  Riddler.
  """
  @spec valid_requirement?(map()) :: boolean()
  def valid_requirement?(req) when is_map(req) do
    required =
      ~w(src_chain_id dst_chain_id src_token dst_token amount_atomic destination slippage_bps)

    Enum.all?(required, &Map.has_key?(req, &1))
  end

  def valid_requirement?(_), do: false
end
