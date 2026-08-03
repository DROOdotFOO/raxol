defmodule Raxol.Earn.ProviderAdapter.Privy do
  @moduledoc """
  `Raxol.Earn.ProviderAdapter` for a Virtuals-managed (Privy + Alchemy) agent
  wallet, backed by a local Node signing sidecar.

  The agent wallet is a Privy server-managed, EIP-7702 Alchemy ModularAccountV2
  smart account controlled by a delegated **P-256 authorization key** -- there is
  no raw secp256k1 key to hold. Signing and settlement therefore cannot go through
  `Raxol.Earn.ProviderAdapter.JSONRPC` (which signs locally with `ExSecp256k1`).

  Instead the key-touching callbacks (`sign_message/3`, `sign_typed_data/3`,
  `send_calls/3`) are delegated over `127.0.0.1` HTTP to the signing sidecar
  (`priv/signer_sidecar/server.mjs`, supervised by `Raxol.Earn.SignerSidecar`),
  which wraps `@virtuals-protocol/acp-node-v2`'s `PrivyAlchemyEvmProviderAdapter`.
  The P-256 authorization key lives ONLY in the sidecar's env; the BEAM never
  reads it.

  Read-only callbacks (`get_transaction_receipt/3`, `read_contract/3`,
  `get_logs/3`) need no key, so they go straight to a Base RPC via
  `Raxol.Earn.Onchain.RPC` -- identical to the JSONRPC adapter -- rather than
  through the sidecar.

  ## Construction

      Raxol.Earn.ProviderAdapter.Privy.new(
        sidecar_url: "http://127.0.0.1:4048",
        address: "0x939ead944b5d28b86d91af1961812d3bbc46cac1",
        chains: %{8453 => "https://mainnet.base.org"}
      )

  `:address` is the managed wallet address (from `RAXOL_ACP_WALLET_ADDRESS`); the
  sidecar independently verifies it against the Privy wallet on boot. `:chains`
  maps chain_id => RPC URL for the read callbacks.

  See `Raxol.Earn.ProviderAdapter.SCA` for the other no-local-EOA adapter.
  """

  @behaviour Raxol.Earn.ProviderAdapter

  alias Raxol.Earn.{ABI, Onchain.Hex, Onchain.RPC}

  @type config :: %{
          sidecar_url: String.t(),
          address: String.t(),
          chains: %{required(pos_integer()) => String.t()},
          req_options: keyword()
        }

  @doc """
  Build an adapter map.

  ## Required options

  - `:sidecar_url` -- base URL of the signing sidecar (localhost).
  - `:address` -- the managed wallet address (0x-hex).
  - `:chains` -- map of chain_id => RPC URL, for the read callbacks.

  ## Optional

  - `:req_options` -- extra options threaded into every `Req` call to the sidecar
    (e.g. `:receive_timeout`). Defaults to a 60s receive timeout, since a
    `send_calls` blocks in the sidecar on the Alchemy prepare -> sign -> send ->
    await path.
  """
  @spec new(keyword()) :: Raxol.Earn.ProviderAdapter.adapter()
  def new(opts) do
    sidecar_url = opts |> Keyword.fetch!(:sidecar_url) |> String.trim_trailing("/")
    address = Keyword.fetch!(opts, :address)
    chains = Keyword.fetch!(opts, :chains)

    config = %{
      sidecar_url: sidecar_url,
      address: address,
      chains: chains,
      req_options: Keyword.get(opts, :req_options, receive_timeout: 60_000)
    }

    %{adapter: __MODULE__, config: config}
  end

  # -- ProviderAdapter callbacks --

  @impl Raxol.Earn.ProviderAdapter
  def get_address(%{config: %{address: addr}}), do: addr

  @impl Raxol.Earn.ProviderAdapter
  def supported_chain_ids(%{config: %{chains: chains}}), do: Map.keys(chains) |> Enum.sort()

  @impl Raxol.Earn.ProviderAdapter
  def sign_message(%{config: cfg}, chain_id, message) when is_binary(message) do
    with {:ok, %{"signature" => sig}} <-
           post(cfg, "/sign-message", %{chainId: chain_id, message: message}) do
      decode_signature(sig)
    end
  end

  @impl Raxol.Earn.ProviderAdapter
  def sign_typed_data(%{config: cfg}, chain_id, typed_data) do
    %{domain: domain, types: types, message: message} = typed_data

    payload = %{
      chainId: chain_id,
      typedData: %{domain: domain, types: normalize_types(types), message: message}
    }

    with {:ok, %{"signature" => sig}} <- post(cfg, "/sign-typed-data", payload) do
      decode_signature(sig)
    end
  end

  # The EIP-712 hasher used by the local adapters takes each type field as a
  # `{name, type}` tuple, which Jason cannot encode. viem (in the sidecar) wants the
  # object form `%{"name" => ..., "type" => ...}` -- convert before JSON transport.
  defp normalize_types(types) do
    Map.new(types, fn {type_name, fields} ->
      {type_name, Enum.map(fields, &normalize_field/1)}
    end)
  end

  defp normalize_field({name, type}), do: %{name: name, type: type}
  defp normalize_field(%{} = field), do: field

  @impl Raxol.Earn.ProviderAdapter
  def send_calls(%{config: cfg}, chain_id, calls) do
    payload = %{chainId: chain_id, calls: Enum.map(calls, &encode_call/1)}

    with {:ok, %{"txHashes" => hashes}} <- post(cfg, "/send-calls", payload) do
      {:ok, hashes}
    end
  end

  @impl Raxol.Earn.ProviderAdapter
  def get_transaction_receipt(adapter, chain_id, tx_hash) do
    with {:ok, client} <- rpc_client(adapter, chain_id) do
      RPC.get_transaction_receipt(client, tx_hash)
    end
  end

  @impl Raxol.Earn.ProviderAdapter
  def read_contract(adapter, chain_id, %{address: address, signature: signature, args: args}) do
    with {:ok, client} <- rpc_client(adapter, chain_id) do
      data = ABI.encode_call(signature, args)
      RPC.eth_call(client, %{to: address, data: data})
    end
  end

  @impl Raxol.Earn.ProviderAdapter
  def get_logs(adapter, chain_id, filter) do
    with {:ok, client} <- rpc_client(adapter, chain_id) do
      RPC.request(client, "eth_getLogs", [build_log_filter(filter)])
    end
  end

  # -- Internals --

  defp post(cfg, path, body) do
    opts =
      [url: cfg.sidecar_url <> path, json: body] ++ cfg.req_options

    case Req.post(opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 409, body: %{"error" => "approval_required"} = body}} ->
        {:error, {:approval_required, body["approvalId"], body["approvalUrl"]}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:signer, status, signer_detail(body)}}

      {:error, reason} ->
        {:error, {:signer_unreachable, reason}}
    end
  end

  defp signer_detail(%{"detail" => detail}), do: detail
  defp signer_detail(body), do: body

  # The sidecar returns "0x..." hex signatures (Privy). Callers (Auth) hex-encode
  # the raw bytes downstream, so decode to a raw binary here -- matching the
  # JSONRPC adapter's `{:ok, <<r,s,v>>}` return contract.
  defp decode_signature("0x" <> hex), do: {:ok, Base.decode16!(hex, case: :mixed)}
  defp decode_signature(hex) when is_binary(hex), do: {:ok, Base.decode16!(hex, case: :mixed)}

  # Normalize a call for JSON transport: data -> 0x-hex string, value -> decimal
  # string (BigInt-safe; the sidecar parses it back to a BigInt).
  defp encode_call(call) do
    %{
      to: Map.fetch!(call, :to),
      data: hexify(Map.get(call, :data, <<>>)),
      value: Integer.to_string(Map.get(call, :value, 0))
    }
  end

  defp hexify("0x" <> _ = hex), do: hex
  defp hexify(bin) when is_binary(bin), do: Hex.encode(bin)

  defp rpc_client(%{config: %{chains: chains}}, chain_id) do
    case Map.fetch(chains, chain_id) do
      {:ok, url} -> {:ok, RPC.client(url: url)}
      :error -> {:error, {:unsupported_chain, chain_id}}
    end
  end

  defp build_log_filter(filter) do
    Enum.reduce(filter, %{}, fn
      {:address, addr}, acc -> Map.put(acc, "address", addr)
      {:topics, topics}, acc -> Map.put(acc, "topics", topics)
      {:from_block, b}, acc -> Map.put(acc, "fromBlock", encode_block(b))
      {:to_block, b}, acc -> Map.put(acc, "toBlock", encode_block(b))
      _, acc -> acc
    end)
  end

  defp encode_block(n) when is_integer(n), do: Hex.encode_quantity(n)
  defp encode_block(b) when is_binary(b), do: b
end
