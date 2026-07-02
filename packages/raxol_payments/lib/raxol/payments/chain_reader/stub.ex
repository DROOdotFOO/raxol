defmodule Raxol.Payments.ChainReader.Stub do
  @moduledoc """
  Deterministic in-memory `Raxol.Payments.ChainReader` for tests.

  This is the no-mock substrate: canned receipts and balances are looked up from
  plain maps, so tests inject known chain state without a mocking library. An
  unknown key returns `{:error, :not_found}`.
  """

  @behaviour Raxol.Payments.ChainReader

  @doc """
  Build a stub reader.

  Options:
    * `:receipts` -- `%{{chain_id, tx_hash} => receipt | :pending | {:error, term}}`
    * `:balances` -- `%{{chain_id, address} => wei}`
  """
  @spec new(keyword()) :: Raxol.Payments.ChainReader.reader()
  def new(opts \\ []) do
    state = %{
      receipts: Keyword.get(opts, :receipts, %{}),
      balances: Keyword.get(opts, :balances, %{}),
      erc20: Keyword.get(opts, :erc20, %{})
    }

    {__MODULE__, state}
  end

  @impl true
  def get_receipt(state, chain_id, tx_hash) do
    case Map.fetch(state.receipts, {chain_id, tx_hash}) do
      {:ok, :pending} -> {:ok, :pending}
      {:ok, {:error, _} = err} -> err
      {:ok, receipt} when is_map(receipt) -> {:ok, receipt}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def get_balance(state, chain_id, address) do
    case Map.fetch(state.balances, {chain_id, address}) do
      {:ok, wei} when is_integer(wei) -> {:ok, wei}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def get_erc20_balance(state, chain_id, token, owner) do
    case Map.fetch(state.erc20, {chain_id, token, owner}) do
      {:ok, atomic} when is_integer(atomic) -> {:ok, atomic}
      :error -> {:error, :not_found}
    end
  end
end
