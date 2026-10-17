defmodule Raxol.Payments.Pxe.Schemas do
  @moduledoc """
  Request/response schemas for the pxe-bridge JSON-RPC API.

  pxe-bridge wraps Aztec's Private eXecution Environment, letting EVM
  solvers create shielded notes on Aztec L2 without understanding
  Aztec's privacy model.

  ## RPC Methods

  - `aztec_createNote` -- create a shielded token note for a recipient
  - `aztec_getVersion` -- return connected Aztec node version
  """

  defmodule CreateNoteParams do
    @moduledoc """
    `aztec_createNote` params. Validation mirrors the bridge's schema, so a
    request it would reject with `-32602` is refused before it is sent.

    `trade_id`, `sub_trade_index` and `total_sub_trades` are the optional
    XIP-1 trade context: all three or none.
    """
    @enforce_keys [:recipient, :token, :amount, :chain_id]
    defstruct [
      :recipient,
      :token,
      :amount,
      :chain_id,
      :trade_id,
      :sub_trade_index,
      :total_sub_trades
    ]

    @type t :: %__MODULE__{
            recipient: String.t(),
            token: String.t(),
            amount: String.t(),
            chain_id: pos_integer(),
            trade_id: String.t() | nil,
            sub_trade_index: non_neg_integer() | nil,
            total_sub_trades: 2..100 | nil
          }

    @hex32_re ~r/\A0x[0-9a-fA-F]{64}\z/
    @zero_address "0x" <> String.duplicate("0", 64)

    @spec validate(t()) :: :ok | {:error, term()}
    def validate(%__MODULE__{} = p) do
      cond do
        not hex32?(p.recipient) ->
          {:error, {:invalid_recipient, "must be 0x + 64 hex chars"}}

        String.downcase(p.recipient) == @zero_address ->
          {:error, {:invalid_recipient, "must not be the zero address"}}

        not hex32?(p.token) ->
          {:error, {:invalid_token, "must be 0x + 64 hex chars"}}

        not valid_amount?(p.amount) ->
          {:error, {:invalid_amount, "must be a positive integer string, at most 78 digits"}}

        not (is_integer(p.chain_id) and p.chain_id > 0) ->
          {:error, {:invalid_chain_id, "must be a positive integer"}}

        true ->
          validate_trade_context(p)
      end
    end

    @spec to_json(t()) :: map()
    def to_json(%__MODULE__{} = p) do
      base = %{
        "recipient" => p.recipient,
        "token" => p.token,
        "amount" => p.amount,
        "chainId" => p.chain_id
      }

      case p.trade_id do
        nil ->
          base

        trade_id ->
          Map.merge(base, %{
            "tradeId" => trade_id,
            "subTradeIndex" => p.sub_trade_index,
            "totalSubTrades" => p.total_sub_trades
          })
      end
    end

    defp validate_trade_context(%{trade_id: nil, sub_trade_index: nil, total_sub_trades: nil}),
      do: :ok

    defp validate_trade_context(%{trade_id: id, sub_trade_index: index, total_sub_trades: total}) do
      with :ok <-
             trade_check(
               Enum.all?([id, index, total], &(not is_nil(&1))),
               "trade_id, sub_trade_index and total_sub_trades go together"
             ),
           :ok <- trade_check(hex32?(id), "trade_id must be 0x + 64 hex chars"),
           :ok <- trade_check(total in 2..100, "total_sub_trades must be an integer in 2..100") do
        trade_check(index in 0..(total - 1), "sub_trade_index must be in 0..total_sub_trades-1")
      end
    end

    defp trade_check(true, _reason), do: :ok
    defp trade_check(false, reason), do: {:error, {:invalid_trade_context, reason}}

    defp hex32?(s) when is_binary(s), do: Regex.match?(@hex32_re, s)
    defp hex32?(_), do: false

    defp valid_amount?(s) when is_binary(s), do: Regex.match?(~r/\A[1-9]\d{0,77}\z/, s)
    defp valid_amount?(_), do: false
  end

  defmodule CreateNoteResult do
    @moduledoc """
    `aztec_createNote` result.

    `note_hashes` is every note hash the transfer emitted, in order (a
    `transfer_to_private` emits two). `nullifiers` is every nullifier it
    emitted; `nullifiers[0]` is the transaction's protocol nullifier, not a
    note's. The bridge also sends deprecated scalar `noteCommitment` /
    `nullifierHash` fields (index 0 of each list); they are not read.
    """
    @enforce_keys [:note_hashes, :nullifiers, :l2_tx_hash]
    defstruct [:note_hashes, :nullifiers, :l2_tx_hash]

    @type t :: %__MODULE__{
            note_hashes: [String.t()],
            nullifiers: [String.t()],
            l2_tx_hash: String.t()
          }

    @spec from_json(term()) :: {:ok, t()} | {:error, {:unexpected_result, term()}}
    def from_json(
          %{"noteHashes" => note_hashes, "nullifiers" => nullifiers, "l2TxHash" => l2_tx_hash} =
            json
        ) do
      if strings?(note_hashes) and strings?(nullifiers) and is_binary(l2_tx_hash) do
        {:ok,
         %__MODULE__{note_hashes: note_hashes, nullifiers: nullifiers, l2_tx_hash: l2_tx_hash}}
      else
        {:error, {:unexpected_result, json}}
      end
    end

    def from_json(json), do: {:error, {:unexpected_result, json}}

    defp strings?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)
  end

  defmodule HealthStatus do
    @moduledoc false
    defstruct [:status, :version]

    @type t :: %__MODULE__{
            status: :ok | :starting | :error,
            version: String.t() | nil
          }

    @spec from_json(map()) :: t()
    def from_json(json) do
      %__MODULE__{
        status: parse_status(json["status"]),
        version: json["version"]
      }
    end

    defp parse_status("ok"), do: :ok
    defp parse_status("starting"), do: :starting
    defp parse_status(_), do: :error
  end
end
