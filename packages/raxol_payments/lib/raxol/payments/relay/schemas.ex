defmodule Raxol.Payments.Relay.Schemas do
  @moduledoc """
  Request and response shapes for Riddler's Relay API (the Tron cross-chain
  rail). Distinct from the Xochi schemas: Relay is deposit-address based (no
  client signature), supports Tron and EVM addresses, and uses its own field
  names (`can_fill`, `to_amount`, `deposit_address`, status
  `pending|executing|confirming|completed|failed`).
  """

  alias Raxol.Payments.Tron.Address, as: TronAddress

  # Tron mainnet chain id (0x2b6653dc).
  @tron_chain_id 728_126_428

  @doc "Tron mainnet chain id."
  @spec tron_chain_id() :: pos_integer()
  def tron_chain_id, do: @tron_chain_id

  @doc "True when `chain_id` is a Tron chain."
  @spec tron_chain?(integer()) :: boolean()
  def tron_chain?(@tron_chain_id), do: true
  def tron_chain?(_), do: false

  defmodule QuoteRequest do
    @moduledoc false
    @enforce_keys [
      :transfer_id,
      :from_chain_id,
      :to_chain_id,
      :from_token,
      :to_token,
      :from_amount,
      :from_address,
      :to_address
    ]
    defstruct [
      :transfer_id,
      :from_chain_id,
      :to_chain_id,
      :from_token,
      :to_token,
      :from_amount,
      :from_address,
      :to_address,
      :deadline,
      slippage_bps: 50,
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            transfer_id: String.t(),
            from_chain_id: pos_integer(),
            to_chain_id: pos_integer(),
            from_token: String.t(),
            to_token: String.t(),
            from_amount: String.t(),
            from_address: String.t(),
            to_address: String.t(),
            deadline: integer() | nil,
            slippage_bps: non_neg_integer(),
            metadata: map()
          }

    alias Raxol.Payments.Relay.Schemas

    @spec validate(t()) :: :ok | {:error, term()}
    def validate(%__MODULE__{} = req) do
      cond do
        req.from_chain_id == req.to_chain_id ->
          {:error, {:invalid_route, "from and to chains must differ"}}

        not (Schemas.tron_chain?(req.from_chain_id) or Schemas.tron_chain?(req.to_chain_id)) ->
          {:error, {:invalid_route, "at least one chain must be Tron"}}

        not valid_address?(req.from_address, req.from_chain_id) ->
          {:error, {:invalid_from_address, req.from_address}}

        not valid_address?(req.to_address, req.to_chain_id) ->
          {:error, {:invalid_to_address, req.to_address}}

        true ->
          :ok
      end
    end

    defp valid_address?(addr, chain_id) do
      if Schemas.tron_chain?(chain_id),
        do: TronAddress.valid?(addr),
        else: evm_address?(addr)
    end

    defp evm_address?(addr) when is_binary(addr),
      do: Regex.match?(~r/^0x[0-9a-fA-F]{40}$/, addr)

    defp evm_address?(_), do: false

    @spec to_json(t()) :: map()
    def to_json(%__MODULE__{} = req) do
      %{
        "transfer_id" => req.transfer_id,
        "from_chain_id" => req.from_chain_id,
        "to_chain_id" => req.to_chain_id,
        "from_token" => req.from_token,
        "to_token" => req.to_token,
        "from_amount" => req.from_amount,
        "from_address" => req.from_address,
        "to_address" => req.to_address,
        "slippage_bps" => req.slippage_bps
      }
      |> Schemas.put_non_nil("deadline", req.deadline)
      |> maybe_put_metadata(req.metadata)
    end

    defp maybe_put_metadata(map, metadata) when map_size(metadata) == 0, do: map
    defp maybe_put_metadata(map, metadata), do: Map.put(map, "metadata", metadata)
  end

  defmodule QuoteResponse do
    @moduledoc false
    @enforce_keys [:transfer_id, :quote_id]
    defstruct [
      :transfer_id,
      :quote_id,
      :to_amount,
      :estimated_fees,
      :expiry,
      :estimated_time_seconds,
      :route,
      :deposit_address,
      :deposit_expires_at,
      :gasless,
      can_fill: false,
      instant_settlement: false,
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            transfer_id: String.t(),
            quote_id: String.t(),
            can_fill: boolean(),
            to_amount: String.t() | nil,
            estimated_fees: map() | nil,
            expiry: integer() | nil,
            estimated_time_seconds: integer() | nil,
            route: map() | nil,
            deposit_address: String.t() | nil,
            deposit_expires_at: integer() | nil,
            # EIP-712 typed data for a gasless pull, present once Riddler returns
            # it on the Tron route (axol-io/Riddler#120). nil = deposit-address.
            gasless: map() | nil,
            instant_settlement: boolean(),
            metadata: map()
          }

    @spec from_json(map()) :: t()
    def from_json(json) do
      %__MODULE__{
        transfer_id: json["transfer_id"],
        quote_id: json["quote_id"],
        can_fill: json["can_fill"] || false,
        to_amount: json["to_amount"],
        estimated_fees: json["estimated_fees"],
        expiry: json["expiry"],
        estimated_time_seconds: json["estimated_time_seconds"],
        route: json["route"],
        deposit_address: json["deposit_address"],
        deposit_expires_at: json["deposit_expires_at"],
        gasless: json["gasless"],
        instant_settlement: json["instant_settlement"] || false,
        metadata: json["metadata"] || %{}
      }
    end
  end

  defmodule ExecuteRequest do
    @moduledoc false
    @enforce_keys [:transfer_id, :quote_id]
    defstruct [:transfer_id, :quote_id, :signature, :nonce]

    @type t :: %__MODULE__{
            transfer_id: String.t(),
            quote_id: String.t(),
            signature: String.t() | nil,
            nonce: integer() | nil
          }

    # Deposit-address transfers carry no signature. A gasless transfer (once
    # Riddler consumes it on the Tron route, see axol-io/Riddler#120) carries a
    # signed authorization so the solver can pull instead of waiting on a deposit.
    @spec to_json(t()) :: map()
    def to_json(%__MODULE__{} = req) do
      %{"transfer_id" => req.transfer_id, "quote_id" => req.quote_id}
      |> Raxol.Payments.Relay.Schemas.put_non_nil("signature", req.signature)
      |> Raxol.Payments.Relay.Schemas.put_non_nil("nonce", req.nonce)
    end
  end

  defmodule StatusResponse do
    @moduledoc false
    @enforce_keys [:transfer_id, :status]
    defstruct [
      :transfer_id,
      :status,
      :tx_hash,
      :block_number,
      :confirmations,
      :actual_to_amount,
      :actual_fees,
      :error,
      # Solver-supplied reason for a refunded transfer; present only on the
      # terminal `:refunded` status.
      :refund_reason,
      :created_at,
      :updated_at,
      terminal: false
    ]

    @type status ::
            :pending | :executing | :confirming | :completed | :failed | :refunded | :unknown

    @type t :: %__MODULE__{
            transfer_id: String.t(),
            status: status(),
            tx_hash: String.t() | nil,
            block_number: integer() | nil,
            confirmations: integer() | nil,
            actual_to_amount: String.t() | nil,
            actual_fees: map() | nil,
            error: String.t() | nil,
            refund_reason: String.t() | nil,
            created_at: String.t() | nil,
            updated_at: String.t() | nil,
            terminal: boolean()
          }

    @terminal_statuses [:completed, :failed, :refunded]

    @spec from_json(map()) :: t()
    def from_json(json) do
      status = parse_status(json["status"])

      %__MODULE__{
        transfer_id: json["transfer_id"],
        status: status,
        tx_hash: json["tx_hash"],
        block_number: json["block_number"],
        confirmations: json["confirmations"],
        actual_to_amount: json["actual_to_amount"],
        actual_fees: json["actual_fees"],
        error: json["error"],
        refund_reason: json["refund_reason"] || json["refundReason"],
        created_at: json["created_at"],
        updated_at: json["updated_at"],
        terminal: status in @terminal_statuses
      }
    end

    @spec terminal?(t()) :: boolean()
    def terminal?(%__MODULE__{terminal: terminal}), do: terminal

    defp parse_status("pending"), do: :pending
    defp parse_status("executing"), do: :executing
    defp parse_status("confirming"), do: :confirming
    defp parse_status("completed"), do: :completed
    defp parse_status("failed"), do: :failed
    defp parse_status("refunded"), do: :refunded
    defp parse_status(_), do: :unknown
  end

  @doc false
  @spec put_non_nil(map(), String.t(), term()) :: map()
  def put_non_nil(map, _key, nil), do: map
  def put_non_nil(map, key, value), do: Map.put(map, key, value)
end
