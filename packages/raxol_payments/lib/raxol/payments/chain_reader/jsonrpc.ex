defmodule Raxol.Payments.ChainReader.JSONRPC do
  @moduledoc """
  `Req`-backed `Raxol.Payments.ChainReader` over per-chain JSON-RPC endpoints.

  Implements only the two read-only methods the accounting layer needs
  (`eth_getTransactionReceipt`, `eth_getBalance`). Self-contained on purpose:
  `raxol_payments` cannot depend on `raxol_acp`'s RPC (that package depends on
  this one), so this mirrors the shape of `Raxol.ACP.Onchain.RPC` without the
  dependency.
  """

  @behaviour Raxol.Payments.ChainReader

  @doc """
  Build a reader handle over a `chain_id => rpc_url` map.

  Options:
    * `:chains` -- `%{pos_integer() => String.t()}` (required)
    * `:req_options` -- extra `Req` options merged into every request (e.g.
      `plug:` for `Req.Test`, `receive_timeout:`)
  """
  @spec new(keyword()) :: Raxol.Payments.ChainReader.reader()
  def new(opts) do
    chains = Keyword.fetch!(opts, :chains)
    req_options = Keyword.get(opts, :req_options, [])
    {__MODULE__, %{chains: chains, req_options: req_options}}
  end

  @impl true
  def get_receipt(state, chain_id, "0x" <> _ = tx_hash) do
    case call(state, chain_id, "eth_getTransactionReceipt", [tx_hash]) do
      {:ok, nil} -> {:ok, :pending}
      {:ok, receipt} when is_map(receipt) -> parse_receipt(receipt)
      {:error, _} = err -> err
    end
  end

  def get_receipt(_state, _chain_id, _tx_hash), do: {:error, :invalid_tx_hash}

  @impl true
  def get_balance(state, chain_id, "0x" <> _ = address) do
    with {:ok, hex} <- call(state, chain_id, "eth_getBalance", [address, "latest"]) do
      decode_quantity(hex)
    end
  end

  def get_balance(_state, _chain_id, _address), do: {:error, :invalid_address}

  # balanceOf(address) selector 0x70a08231 + the 32-byte left-padded owner.
  @balance_of_selector "0x70a08231"

  @impl true
  def get_erc20_balance(state, chain_id, "0x" <> _ = token, "0x" <> _ = owner) do
    data = @balance_of_selector <> pad_address(owner)

    with {:ok, hex} <- call(state, chain_id, "eth_call", [%{to: token, data: data}, "latest"]) do
      decode_quantity(hex)
    end
  end

  def get_erc20_balance(_state, _chain_id, _token, _owner), do: {:error, :invalid_argument}

  # -- internal --

  defp pad_address("0x" <> hex), do: hex |> String.downcase() |> String.pad_leading(64, "0")

  defp parse_receipt(receipt) do
    with {:ok, gas_used} <- decode_quantity(receipt["gasUsed"]),
         {:ok, gas_price} <- effective_gas_price(receipt) do
      {:ok,
       %{
         gas_used: gas_used,
         effective_gas_price: gas_price,
         status: receipt_status(receipt["status"])
       }}
    end
  end

  # Post-London receipts carry effectiveGasPrice; fall back to gasPrice for older
  # nodes/chains that omit it.
  defp effective_gas_price(%{"effectiveGasPrice" => hex}) when is_binary(hex),
    do: decode_quantity(hex)

  defp effective_gas_price(%{"gasPrice" => hex}) when is_binary(hex),
    do: decode_quantity(hex)

  defp effective_gas_price(_), do: {:ok, 0}

  defp receipt_status("0x1"), do: :success
  defp receipt_status(_), do: :reverted

  defp call(state, chain_id, method, params) do
    case Map.fetch(state.chains, chain_id) do
      {:ok, url} -> do_call(url, state.req_options, method, params)
      :error -> {:error, {:no_rpc_for_chain, chain_id}}
    end
  end

  defp do_call(url, req_options, method, params) do
    body = %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: method,
      params: params
    }

    req =
      [url: url, headers: [{"content-type", "application/json"}]]
      |> Keyword.merge(req_options)
      |> Req.new()

    case Req.post(req, json: body) do
      {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %Req.Response{status: 200, body: %{"error" => err}}} ->
        {:error, {:rpc_error, err}}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, {:http, status, resp_body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # 0x-prefixed hex quantity -> integer. "0x" and "0x0" both decode as 0.
  defp decode_quantity("0x"), do: {:ok, 0}

  defp decode_quantity("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {n, ""} -> {:ok, n}
      _ -> {:error, {:hex_decode, "0x" <> hex}}
    end
  end

  defp decode_quantity(other), do: {:error, {:hex_decode, other}}
end
