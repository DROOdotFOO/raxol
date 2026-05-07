defmodule Raxol.ACP.Onchain.RPC do
  @moduledoc """
  Minimal Ethereum JSON-RPC 2.0 client for the methods
  `Raxol.ACP.ContractClient.Onchain` needs.

  ## Methods supported (v0.1)

  - `eth_chainId/1` -- sanity-check the configured RPC matches our
    expected `chain_id`
  - `eth_blockNumber/1` -- current block height; used by retry/timeout
    logic
  - `eth_getTransactionCount/2` -- nonce for an address (always
    queries `"pending"` for tx submission)
  - `eth_estimateGas/2` -- gas estimate for a call object
  - `eth_feeHistory/4` -- recent base fee + priority fee histogram for
    EIP-1559 fee suggestion
  - `eth_sendRawTransaction/2` -- broadcast a signed transaction
  - `eth_getTransactionReceipt/2` -- poll for inclusion / status

  ## Configuration

  The RPC base URL and the optional `req` adapter come from
  `Application.get_env(:raxol_acp, :rpc, ...)`. Callers can also pass a
  `client/1` opts map directly for one-off requests.

      config :raxol_acp,
        rpc: [
          url: "https://mainnet.base.org",
          # optional: a `Plug` or `{Req.Test, stub_name}` for test stubbing
          plug: nil,
          # request timeout in ms
          receive_timeout: 15_000
        ]

  ## Hex encoding

  Ethereum JSON-RPC uses 0x-prefixed lowercase hex for everything. This
  module exposes integer-friendly helpers (`get_transaction_count/2`
  takes an address and returns an integer) and binary-friendly helpers
  (`send_raw_transaction/2` takes a binary payload). Conversion happens
  at the boundary.

  ## Errors

  All public functions return `{:ok, decoded}` or `{:error, reason}`.
  The error reason has one of these shapes:

  - `{:rpc_error, %{code: code, message: msg}}` -- the node returned a
    JSON-RPC `error` object
  - `{:transport, term}` -- the HTTP transport failed (timeout, DNS,
    etc.)
  - `{:malformed_response, term}` -- the response body did not match
    JSON-RPC 2.0 shape
  - `{:hex_decode, hex, reason}` -- a response field was supposed to be
    hex but failed to decode
  """

  @type client :: Req.Request.t()

  @doc """
  Build a `Req` request configured for JSON-RPC against the
  application's configured RPC URL.

  Pass `:url` to override the URL or `:plug` to inject a stub (used by
  tests).
  """
  @spec client(keyword()) :: client()
  def client(opts \\ []) do
    config = Application.get_env(:raxol_acp, :rpc, [])
    url = Keyword.get(opts, :url) || Keyword.get(config, :url) || raise_no_url()

    receive_timeout =
      Keyword.get(opts, :receive_timeout, Keyword.get(config, :receive_timeout, 15_000))

    plug = Keyword.get(opts, :plug, Keyword.get(config, :plug))

    base = [
      url: url,
      headers: [{"content-type", "application/json"}],
      receive_timeout: receive_timeout
    ]

    base = if plug, do: Keyword.put(base, :plug, plug), else: base

    Req.new(base)
  end

  defp raise_no_url do
    raise """
    Raxol.ACP.Onchain.RPC: no RPC URL configured. Set one of:

      config :raxol_acp, rpc: [url: "https://sepolia.base.org"]
      Raxol.ACP.Onchain.RPC.client(url: "...")
    """
  end

  # -- Methods --

  @doc "Return the chain ID the RPC reports (decimal integer)."
  @spec eth_chain_id(client()) :: {:ok, pos_integer()} | {:error, term()}
  def eth_chain_id(client) do
    with {:ok, hex} <- call(client, "eth_chainId", []) do
      decode_quantity(hex)
    end
  end

  @doc "Return the current block number (decimal integer)."
  @spec eth_block_number(client()) :: {:ok, non_neg_integer()} | {:error, term()}
  def eth_block_number(client) do
    with {:ok, hex} <- call(client, "eth_blockNumber", []) do
      decode_quantity(hex)
    end
  end

  @doc """
  Return the transaction count (next nonce) for `address` at the
  pending tag.
  """
  @spec get_transaction_count(client(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def get_transaction_count(client, "0x" <> _ = address) do
    with {:ok, hex} <- call(client, "eth_getTransactionCount", [address, "pending"]) do
      decode_quantity(hex)
    end
  end

  @doc """
  Estimate gas for a call object. `tx` is a map with `:from`, `:to`,
  optional `:data` (binary), and optional `:value` (integer).
  """
  @spec estimate_gas(client(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def estimate_gas(client, tx) do
    with {:ok, hex} <- call(client, "eth_estimateGas", [encode_call_object(tx)]) do
      decode_quantity(hex)
    end
  end

  @doc """
  Return the chain's recent fee history for EIP-1559 fee suggestion.

  `block_count` is how many blocks of history to fetch. `newest_block`
  is `"latest"` or a block number. `reward_percentiles` is a list of
  integers in `0..100`.
  """
  @spec fee_history(client(), pos_integer(), String.t() | non_neg_integer(), [number()]) ::
          {:ok, map()} | {:error, term()}
  def fee_history(client, block_count, newest_block, reward_percentiles) do
    params = [
      encode_quantity(block_count),
      encode_block_tag(newest_block),
      reward_percentiles
    ]

    with {:ok, body} <- call(client, "eth_feeHistory", params) do
      {:ok, body}
    end
  end

  @doc """
  Broadcast a signed raw transaction. Returns the transaction hash as
  a 0x-prefixed hex string.
  """
  @spec send_raw_transaction(client(), binary()) ::
          {:ok, String.t()} | {:error, term()}
  def send_raw_transaction(client, raw_bytes) when is_binary(raw_bytes) do
    call(client, "eth_sendRawTransaction", ["0x" <> Base.encode16(raw_bytes, case: :lower)])
  end

  @doc """
  Fetch the receipt for a transaction. Returns `{:ok, nil}` if the tx
  is still pending; `{:ok, receipt_map}` once mined.
  """
  @spec get_transaction_receipt(client(), String.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def get_transaction_receipt(client, "0x" <> _ = tx_hash) do
    case call(client, "eth_getTransactionReceipt", [tx_hash]) do
      {:ok, nil} -> {:ok, nil}
      {:ok, receipt} when is_map(receipt) -> {:ok, receipt}
      {:error, _} = err -> err
    end
  end

  @doc """
  Poll `get_transaction_receipt/2` until non-nil or `timeout_ms`
  elapses. Polling interval defaults to 250ms.
  """
  @spec await_receipt(client(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :timeout | term()}
  def await_receipt(client, tx_hash, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    interval_ms = Keyword.get(opts, :interval_ms, 250)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_await_receipt(client, tx_hash, deadline, interval_ms)
  end

  defp do_await_receipt(client, tx_hash, deadline, interval_ms) do
    case get_transaction_receipt(client, tx_hash) do
      {:ok, receipt} when is_map(receipt) ->
        {:ok, receipt}

      {:ok, nil} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(interval_ms)
          do_await_receipt(client, tx_hash, deadline, interval_ms)
        end

      {:error, _} = err ->
        err
    end
  end

  # -- Encoding helpers --

  @doc "Encode a non-negative integer as a 0x-prefixed minimal hex quantity."
  @spec encode_quantity(non_neg_integer()) :: String.t()
  def encode_quantity(n) when is_integer(n) and n >= 0 do
    "0x" <> (n |> Integer.to_string(16) |> String.downcase())
  end

  @doc """
  Decode a 0x-prefixed hex quantity to an integer. The empty value
  `"0x"` and `"0x0"` both decode as 0.
  """
  @spec decode_quantity(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def decode_quantity("0x"), do: {:ok, 0}

  def decode_quantity("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {n, ""} -> {:ok, n}
      _ -> {:error, {:hex_decode, "0x" <> hex, :not_integer}}
    end
  end

  def decode_quantity(other), do: {:error, {:hex_decode, other, :missing_0x_prefix}}

  defp encode_block_tag(tag) when tag in ["latest", "pending", "earliest", "safe", "finalized"],
    do: tag

  defp encode_block_tag(n) when is_integer(n), do: encode_quantity(n)

  defp encode_call_object(tx) do
    %{}
    |> put_if_present(:from, Map.get(tx, :from))
    |> put_if_present(:to, Map.get(tx, :to))
    |> put_if_present(:value, encode_or_nil(Map.get(tx, :value)))
    |> put_if_present(:data, encode_data(Map.get(tx, :data)))
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp encode_or_nil(nil), do: nil
  defp encode_or_nil(n) when is_integer(n) and n >= 0, do: encode_quantity(n)

  defp encode_data(nil), do: nil
  defp encode_data(<<>>), do: "0x"
  defp encode_data(bin) when is_binary(bin), do: "0x" <> Base.encode16(bin, case: :lower)

  # -- Core call --

  defp call(client, method, params) do
    body = %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: method,
      params: params
    }

    case Req.post(client, json: body) do
      {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %Req.Response{status: 200, body: %{"error" => err}}} ->
        {:error, {:rpc_error, normalize_error(err)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:transport, {:http_status, status, body}}}

      {:ok, %Req.Response{} = resp} ->
        {:error, {:malformed_response, resp.body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp normalize_error(%{"code" => code, "message" => msg} = err) do
    %{code: code, message: msg, data: Map.get(err, "data")}
  end

  defp normalize_error(err), do: %{code: nil, message: inspect(err), data: nil}
end
