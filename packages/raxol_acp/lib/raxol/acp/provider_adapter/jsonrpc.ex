defmodule Raxol.ACP.ProviderAdapter.JSONRPC do
  @moduledoc """
  Production `Raxol.ACP.ProviderAdapter` backed by raw Ethereum
  JSON-RPC and an EOA private key.

  Reuses `Raxol.ACP.Onchain.RPC` for the wire layer and
  `Raxol.ACP.Onchain.Transaction` for EIP-1559 transaction
  construction. ECDSA signing goes through `ExSecp256k1`.

  ## Construction

      adapter =
        Raxol.ACP.ProviderAdapter.JSONRPC.new(
          chains: %{
            8453 => "https://mainnet.base.org",
            84_532 => "https://sepolia.base.org"
          },
          private_key: <<...32 bytes...>>
        )

  The map keys are chain IDs; the values are RPC URLs. The adapter
  picks the URL for the chain ID passed on each call.

  ## Test substrate

  `test/support/anvil_harness.ex` spins up `anvil --fork-url
  https://mainnet.base.org` and returns an RPC URL the adapter can
  use. Tests tagged `:live_chain` (requires `anvil` on PATH) run
  against this fork.

  ## What's NOT covered

  - **Smart-contract account flows**: this adapter signs EIP-1559
    transactions as a plain EOA. For Modular Account v2 / paymaster
    flows, use `Raxol.ACP.ProviderAdapter.SCA` (follow-up) which
    wraps `Raxol.ACP.Wallet.SCA`.
  - **Batch submission**: `send_calls/3` submits one EIP-1559 tx per
    call. The SDK's batch semantics (return one hash per call)
    are preserved, but the bundling efficiencies aren't.
  """

  @behaviour Raxol.ACP.ProviderAdapter

  alias Raxol.ACP.{ABI, Onchain.RPC, Onchain.Transaction}

  @type config :: %{
          chains: %{required(pos_integer()) => String.t()},
          private_key: <<_::256>>,
          address: String.t(),
          fee_overrides: %{optional(pos_integer()) => fee_override()}
        }

  @type fee_override :: %{
          optional(:max_priority_fee_per_gas) => non_neg_integer(),
          optional(:max_fee_per_gas) => non_neg_integer()
        }

  @doc """
  Build an adapter map.

  ## Required options

  - `:chains` -- map of chain_id => RPC URL.
  - `:private_key` -- 32-byte raw private key.

  ## Optional

  - `:fee_overrides` -- per-chain `%{max_priority_fee_per_gas,
    max_fee_per_gas}` map. Use to short-circuit fee discovery on
    test forks (anvil's default fees are zero).
  """
  @spec new(keyword()) :: Raxol.ACP.ProviderAdapter.adapter()
  def new(opts) do
    chains = Keyword.fetch!(opts, :chains)
    private_key = Keyword.fetch!(opts, :private_key)

    if not is_binary(private_key) or byte_size(private_key) != 32 do
      raise ArgumentError, "private_key must be a 32-byte binary"
    end

    address = address_from_private_key(private_key)

    config = %{
      chains: chains,
      private_key: private_key,
      address: address,
      fee_overrides: Keyword.get(opts, :fee_overrides, %{})
    }

    %{adapter: __MODULE__, config: config}
  end

  # -- ProviderAdapter callbacks --

  @impl Raxol.ACP.ProviderAdapter
  def get_address(%{config: %{address: addr}}), do: addr

  @impl Raxol.ACP.ProviderAdapter
  def supported_chain_ids(%{config: %{chains: chains}}), do: Map.keys(chains) |> Enum.sort()

  @impl Raxol.ACP.ProviderAdapter
  def send_calls(%{config: cfg} = adapter, chain_id, calls) do
    with {:ok, client} <- rpc_client(adapter, chain_id),
         {:ok, hashes} <- send_each(client, adapter, chain_id, calls, cfg.private_key) do
      {:ok, hashes}
    end
  end

  @impl Raxol.ACP.ProviderAdapter
  def sign_message(%{config: %{private_key: pk}}, _chain_id, message) when is_binary(message) do
    digest = eip191_digest(message)

    case ExSecp256k1.sign(digest, pk) do
      {:ok, {r, s, v}} ->
        {:ok, <<r::binary-size(32), s::binary-size(32), v + 27>>}

      {:error, _} = err ->
        err
    end
  end

  @impl Raxol.ACP.ProviderAdapter
  def sign_typed_data(%{config: %{private_key: pk}}, _chain_id, typed_data) do
    %{domain: domain, types: types, message: message} = typed_data

    case Raxol.Payments.EIP712.hash(domain, types, message) do
      {:ok, digest} ->
        case ExSecp256k1.sign(digest, pk) do
          {:ok, {r, s, v}} ->
            {:ok, <<r::binary-size(32), s::binary-size(32), v + 27>>}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  @impl Raxol.ACP.ProviderAdapter
  def get_transaction_receipt(adapter, chain_id, tx_hash) do
    with {:ok, client} <- rpc_client(adapter, chain_id) do
      RPC.get_transaction_receipt(client, tx_hash)
    end
  end

  @impl Raxol.ACP.ProviderAdapter
  def read_contract(adapter, chain_id, %{address: address, signature: signature, args: args}) do
    with {:ok, client} <- rpc_client(adapter, chain_id) do
      # Pass raw binary; RPC.eth_call's encode_data hex-encodes for us.
      data = ABI.encode_call(signature, args)
      RPC.eth_call(client, %{to: address, data: data})
    end
  end

  @impl Raxol.ACP.ProviderAdapter
  def get_logs(adapter, chain_id, filter) do
    with {:ok, client} <- rpc_client(adapter, chain_id) do
      params = build_log_filter(filter)
      RPC.request(client, "eth_getLogs", [params])
    end
  end

  # -- Internals --

  defp rpc_client(%{config: %{chains: chains}}, chain_id) do
    case Map.fetch(chains, chain_id) do
      {:ok, url} -> {:ok, RPC.client(url: url)}
      :error -> {:error, {:unsupported_chain, chain_id}}
    end
  end

  defp send_each(client, adapter, chain_id, calls, private_key) do
    address = adapter.config.address

    with {:ok, starting_nonce} <- RPC.get_transaction_count(client, address) do
      {results, _next_nonce} =
        Enum.map_reduce(calls, starting_nonce, fn call, nonce ->
          case submit_one(client, adapter, chain_id, call, private_key, nonce) do
            {:ok, hash} -> {{:ok, hash}, nonce + 1}
            {:error, _} = err -> {err, nonce}
          end
        end)

      case Enum.find(results, &match?({:error, _}, &1)) do
        nil -> {:ok, Enum.map(results, fn {:ok, hash} -> hash end)}
        err -> err
      end
    end
  end

  defp submit_one(client, adapter, chain_id, call, private_key, nonce) do
    address = adapter.config.address

    with {:ok, fees} <- fees(client, adapter.config.fee_overrides, chain_id),
         tx_attrs <- build_tx_attrs(chain_id, nonce, call, fees),
         {:ok, gas_limit} <- estimate_gas(client, address, call),
         tx <- Transaction.new(Map.put(tx_attrs, :gas_limit, gas_limit)),
         {:ok, signature} <- sign_tx(tx, private_key),
         signed <- Transaction.serialize(tx, signature),
         {:ok, hash} <- RPC.send_raw_transaction(client, signed) do
      {:ok, hash}
    end
  end

  defp fees(client, fee_overrides, chain_id) do
    case Map.get(fee_overrides, chain_id) do
      %{max_priority_fee_per_gas: prio, max_fee_per_gas: max_fee} ->
        {:ok, %{max_priority_fee_per_gas: prio, max_fee_per_gas: max_fee}}

      _ ->
        # Best-effort fee discovery from recent block history. Anvil
        # forks usually have very low fees so the floor is generous.
        case RPC.fee_history(client, 5, "latest", [50]) do
          {:ok, %{"baseFeePerGas" => base_fees, "reward" => reward}} ->
            base = base_fees |> List.last() |> decode_hex_uint!()
            prio = reward |> List.first() |> List.first() |> decode_hex_uint!() |> max(1_000_000_000)
            {:ok, %{max_priority_fee_per_gas: prio, max_fee_per_gas: base * 2 + prio}}

          _ ->
            # Static fallback: 2 gwei priority, 5 gwei max.
            {:ok, %{max_priority_fee_per_gas: 2_000_000_000, max_fee_per_gas: 5_000_000_000}}
        end
    end
  end

  defp build_tx_attrs(chain_id, nonce, call, fees) do
    %{
      chain_id: chain_id,
      nonce: nonce,
      to: Map.fetch!(call, :to),
      data: normalize_data(Map.get(call, :data, <<>>)),
      value: Map.get(call, :value, 0),
      access_list: [],
      max_priority_fee_per_gas: fees.max_priority_fee_per_gas,
      max_fee_per_gas: fees.max_fee_per_gas
    }
  end

  defp estimate_gas(client, from, call) do
    # RPC.estimate_gas's encode_call_object expects raw integer for :value
    # and either raw bytes or "0x..." for :data. Hand it both as binaries
    # the encoder knows; don't pre-encode value.
    tx = %{
      from: from,
      to: call.to,
      data: normalize_data(Map.get(call, :data, <<>>)),
      value: Map.get(call, :value, 0)
    }

    case RPC.estimate_gas(client, tx) do
      {:ok, n} ->
        # Add a 10% safety buffer; gas estimation can underestimate on
        # storage-touching calls.
        {:ok, div(n * 110, 100)}

      _ ->
        {:ok, Map.get(call, :gas, 500_000)}
    end
  end

  defp sign_tx(tx, private_key) do
    digest = Transaction.signing_hash(tx)

    case ExSecp256k1.sign(digest, private_key) do
      {:ok, {r, s, v}} -> {:ok, <<r::binary-size(32), s::binary-size(32), v::8>>}
      err -> err
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

  defp encode_block(n) when is_integer(n), do: encode_quantity(n)
  defp encode_block(b) when is_binary(b), do: b

  defp encode_quantity(n) when is_integer(n) and n >= 0,
    do: "0x" <> Integer.to_string(n, 16)

  defp decode_hex_uint!("0x" <> hex), do: String.to_integer(hex, 16)

  defp normalize_data("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp normalize_data(bin) when is_binary(bin), do: bin

  defp eip191_digest(message) do
    prefix = "\x19Ethereum Signed Message:\n#{byte_size(message)}"
    ExKeccak.hash_256(prefix <> message)
  end

  # secp256k1: address = last 20 bytes of keccak256(uncompressed_public_key[1..])
  defp address_from_private_key(<<_::binary-size(32)>> = private_key) do
    {:ok, public_key} = ExSecp256k1.create_public_key(private_key)
    <<_prefix::8, payload::binary-size(64)>> = public_key
    hash = ExKeccak.hash_256(payload)
    <<_padding::binary-size(12), addr::binary-size(20)>> = hash
    "0x" <> Base.encode16(addr, case: :lower)
  end
end
