defmodule Raxol.Payments.ChainReader do
  @moduledoc """
  Read-only, multi-chain on-chain reader used by the settlement accounting and
  rebalance advisor: fetch a transaction receipt (to price the gas a fill burned)
  and read a native/token balance (to size a refuel).

  A reader is a `{module, state}` handle so a concrete JSON-RPC adapter and a
  deterministic in-memory stub are fully substitutable -- tests inject
  `Raxol.Payments.ChainReader.Stub`, the live path injects
  `Raxol.Payments.ChainReader.JSONRPC`. `raxol_payments` deliberately owns a small
  `Req`-based adapter rather than reaching into `raxol_earn`'s RPC, because
  `raxol_earn` depends on `raxol_payments` and the reverse alias would be a cycle.
  """

  @type state :: term()
  @type reader :: {module(), state()}

  @typedoc """
  A normalized, mined-transaction receipt. `gas_used * effective_gas_price` is the
  native-token (wei) cost of the transaction.
  """
  @type receipt :: %{
          gas_used: non_neg_integer(),
          effective_gas_price: non_neg_integer(),
          status: :success | :reverted
        }

  @callback get_receipt(state(), chain_id :: pos_integer(), tx_hash :: String.t()) ::
              {:ok, receipt()} | {:ok, :pending} | {:error, term()}

  @callback get_balance(state(), chain_id :: pos_integer(), address :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @callback get_erc20_balance(
              state(),
              chain_id :: pos_integer(),
              token :: String.t(),
              owner :: String.t()
            ) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Fetch a receipt for `tx_hash` on `chain_id`. `{:ok, :pending}` means the tx is
  not yet mined; the caller decides whether to retry.
  """
  @spec get_receipt(reader(), pos_integer(), String.t()) ::
          {:ok, receipt()} | {:ok, :pending} | {:error, term()}
  def get_receipt({module, state}, chain_id, tx_hash) do
    module.get_receipt(state, chain_id, tx_hash)
  end

  @doc "Read the native-token balance (wei) of `address` on `chain_id`."
  @spec get_balance(reader(), pos_integer(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def get_balance({module, state}, chain_id, address) do
    module.get_balance(state, chain_id, address)
  end

  @doc "Read the ERC-20 `token` balance (atomic units) of `owner` on `chain_id`."
  @spec get_erc20_balance(reader(), pos_integer(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def get_erc20_balance({module, state}, chain_id, token, owner) do
    module.get_erc20_balance(state, chain_id, token, owner)
  end
end
