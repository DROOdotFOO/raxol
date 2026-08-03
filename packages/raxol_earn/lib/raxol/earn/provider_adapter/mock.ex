defmodule Raxol.Earn.ProviderAdapter.Mock do
  @moduledoc """
  In-process mock for `Raxol.Earn.ProviderAdapter`.

  Records every call and lets tests pre-canned return values.

  ## Usage

      adapter =
        Raxol.Earn.ProviderAdapter.Mock.new(
          address: "0xabc...",
          supported_chain_ids: [8453]
        )

      Raxol.Earn.ProviderAdapter.Mock.set_receipt(adapter, "0xtx", %{status: 1})
      {:ok, ["0xtx1"]} = Raxol.Earn.ProviderAdapter.send_calls(adapter, 8453, [call])

      Raxol.Earn.ProviderAdapter.Mock.sent_calls(adapter)
      # => [{8453, [call]}]
  """

  @behaviour Raxol.Earn.ProviderAdapter

  @doc "Construct a fresh mock adapter."
  @spec new(keyword()) :: Raxol.Earn.ProviderAdapter.adapter()
  def new(opts \\ []) do
    table = :ets.new(:raxol_earn_provider_mock, [:set, :public])

    :ets.insert(
      table,
      {:address, Keyword.get(opts, :address, "0x" <> String.duplicate("ab", 20))}
    )

    :ets.insert(table, {:supported_chain_ids, Keyword.get(opts, :supported_chain_ids, [8453])})
    :ets.insert(table, {:sent_calls, []})
    :ets.insert(table, {:sent_signatures, []})
    :ets.insert(table, {:tx_counter, 0})
    :ets.insert(table, {:receipts, %{}})
    :ets.insert(table, {:contract_reads, %{}})
    :ets.insert(table, {:logs, []})
    :ets.insert(table, {:send_calls_error, nil})

    %{adapter: __MODULE__, config: %{table: table}}
  end

  @doc "Set the receipt returned by `get_transaction_receipt/3`."
  @spec set_receipt(Raxol.Earn.ProviderAdapter.adapter(), String.t(), map()) :: :ok
  def set_receipt(%{config: %{table: table}}, tx_hash, receipt) do
    [{:receipts, current}] = :ets.lookup(table, :receipts)
    :ets.insert(table, {:receipts, Map.put(current, tx_hash, receipt)})
    :ok
  end

  @doc "Set the value returned by `read_contract/3` for a given `{address, signature}`."
  @spec set_contract_read(Raxol.Earn.ProviderAdapter.adapter(), String.t(), String.t(), term()) ::
          :ok
  def set_contract_read(%{config: %{table: table}}, contract_address, signature, return_value) do
    [{:contract_reads, current}] = :ets.lookup(table, :contract_reads)
    key = {String.downcase(contract_address), signature}
    :ets.insert(table, {:contract_reads, Map.put(current, key, return_value)})
    :ok
  end

  @doc "Seed event logs returned by `get_logs/3`."
  @spec set_logs(Raxol.Earn.ProviderAdapter.adapter(), [map()]) :: :ok
  def set_logs(%{config: %{table: table}}, logs) do
    :ets.insert(table, {:logs, logs})
    :ok
  end

  @doc """
  Make `send_calls/3` fail with `{:error, reason}`, simulating a bundler / RPC
  failure so tests can exercise the on-chain-write-fails path. Pass `nil` to
  clear. A failed call is not recorded in `sent_calls/1`.
  """
  @spec set_send_calls_error(Raxol.Earn.ProviderAdapter.adapter(), term()) :: :ok
  def set_send_calls_error(%{config: %{table: table}}, reason) do
    :ets.insert(table, {:send_calls_error, reason})
    :ok
  end

  @doc "All `send_calls/3` invocations in order: `[{chain_id, calls}, ...]`."
  @spec sent_calls(Raxol.Earn.ProviderAdapter.adapter()) :: [{pos_integer(), [map()]}]
  def sent_calls(%{config: %{table: table}}) do
    [{:sent_calls, list}] = :ets.lookup(table, :sent_calls)
    Enum.reverse(list)
  end

  @doc "All signature requests, in order. Useful to assert on EIP-712 payloads."
  @spec sent_signatures(Raxol.Earn.ProviderAdapter.adapter()) :: [tuple()]
  def sent_signatures(%{config: %{table: table}}) do
    [{:sent_signatures, list}] = :ets.lookup(table, :sent_signatures)
    Enum.reverse(list)
  end

  # -- Behaviour callbacks --

  @impl Raxol.Earn.ProviderAdapter
  def send_calls(%{config: %{table: table}}, chain_id, calls) do
    case :ets.lookup(table, :send_calls_error) do
      [{:send_calls_error, nil}] ->
        record(table, :sent_calls, {chain_id, calls})
        hashes = Enum.map(calls, fn _ -> mint_tx_hash(table) end)
        {:ok, hashes}

      [{:send_calls_error, reason}] ->
        {:error, reason}
    end
  end

  @impl Raxol.Earn.ProviderAdapter
  def sign_message(%{config: %{table: table}}, chain_id, message) do
    record(table, :sent_signatures, {:message, chain_id, message})
    {:ok, <<0xDE, 0xAD>>}
  end

  @impl Raxol.Earn.ProviderAdapter
  def sign_typed_data(%{config: %{table: table}}, chain_id, typed_data) do
    record(table, :sent_signatures, {:typed_data, chain_id, typed_data})
    {:ok, <<0xBE, 0xEF>>}
  end

  @impl Raxol.Earn.ProviderAdapter
  def get_transaction_receipt(%{config: %{table: table}}, _chain_id, tx_hash) do
    [{:receipts, r}] = :ets.lookup(table, :receipts)
    {:ok, Map.get(r, tx_hash)}
  end

  @impl Raxol.Earn.ProviderAdapter
  def read_contract(%{config: %{table: table}}, _chain_id, %{address: addr, signature: sig}) do
    [{:contract_reads, r}] = :ets.lookup(table, :contract_reads)
    key = {String.downcase(addr), sig}

    case Map.fetch(r, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:no_canned_read, addr, sig}}
    end
  end

  @impl Raxol.Earn.ProviderAdapter
  def get_logs(%{config: %{table: table}}, _chain_id, _filter) do
    [{:logs, logs}] = :ets.lookup(table, :logs)
    {:ok, logs}
  end

  @impl Raxol.Earn.ProviderAdapter
  def get_address(%{config: %{table: table}}) do
    [{:address, a}] = :ets.lookup(table, :address)
    a
  end

  @impl Raxol.Earn.ProviderAdapter
  def supported_chain_ids(%{config: %{table: table}}) do
    [{:supported_chain_ids, ids}] = :ets.lookup(table, :supported_chain_ids)
    ids
  end

  # -- Internal --

  defp record(table, key, entry) do
    [{^key, list}] = :ets.lookup(table, key)
    :ets.insert(table, {key, [entry | list]})
  end

  defp mint_tx_hash(table) do
    [{:tx_counter, n}] = :ets.lookup(table, :tx_counter)
    :ets.insert(table, {:tx_counter, n + 1})
    "0x" <> String.pad_leading(Integer.to_string(n + 1, 16), 64, "0")
  end
end
