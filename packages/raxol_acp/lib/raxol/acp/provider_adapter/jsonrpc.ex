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

  ## Nonce management

  Nonce assignment is serialized through a `Raxol.ACP.Wallet.NonceServer`
  (the `:nonce_server` config, default the umbrella instance). Every
  transaction takes its nonce from the server's mailbox, so two concurrent
  `send_calls/3` for the same EOA -- e.g. two in-flight seller jobs each
  writing a hook call -- can never sign the same nonce. A send that fails
  before broadcast resyncs the server so the next send re-fetches the
  pending nonce from chain and re-fills the gap. One `NonceServer` instance
  serializes one wallet address; run one instance per wallet.

  ## What's NOT covered

  - **Smart-contract account flows**: this adapter signs EIP-1559
    transactions as a plain EOA. For Modular Account v2 / paymaster
    flows, use `Raxol.ACP.ProviderAdapter.SCA`, which wraps
    `Raxol.ACP.Wallet.SCA` and uses ERC-4337 EntryPoint nonces instead.
  - **Batch submission**: `send_calls/3` submits one EIP-1559 tx per
    call. The SDK's batch semantics (return one hash per call)
    are preserved, but the bundling efficiencies aren't.
  """

  @behaviour Raxol.ACP.ProviderAdapter

  alias Raxol.ACP.{ABI, Onchain.RPC, Onchain.Transaction, Secret}
  alias Raxol.ACP.Wallet.NonceServer

  @type config :: %{
          chains: %{required(pos_integer()) => String.t()},
          private_key: Secret.t(),
          address: String.t(),
          fee_overrides: %{optional(pos_integer()) => fee_override()},
          nonce_server: GenServer.server(),
          receipt_wait_opts: keyword()
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
  - `:nonce_server` -- the `Raxol.ACP.Wallet.NonceServer` instance that
    serializes nonce assignment for THIS adapter's wallet address
    (default `Raxol.ACP.Wallet.NonceServer`, the umbrella instance the
    supervisor starts). One instance must map to exactly one address:
    two concurrent `send_calls/3` for the same EOA route through the
    server's mailbox so they can never sign the same nonce. If you run
    more than one wallet, construct each adapter with a distinct
    `:nonce_server`.
  - `:receipt_wait_opts` -- keyword passed to `RPC.await_receipt/3` when
    confirming a broadcast tx (`:timeout_ms` default 30_000, `:interval_ms`
    default 250). `send_calls/3` waits for the receipt and rejects a
    reverted tx before reporting success.
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
      private_key: Secret.new(private_key),
      address: address,
      fee_overrides: Keyword.get(opts, :fee_overrides, %{}),
      nonce_server: Keyword.get(opts, :nonce_server, NonceServer),
      receipt_wait_opts: Keyword.get(opts, :receipt_wait_opts, [])
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

    case ExSecp256k1.sign(digest, Secret.reveal(pk)) do
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
        case ExSecp256k1.sign(digest, Secret.reveal(pk)) do
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
    nonce_server = adapter.config.nonce_server

    results =
      Enum.map(calls, fn call ->
        with {:ok, nonce} <- acquire_nonce(nonce_server, client, address),
             {:ok, hash} <- submit_one(client, adapter, chain_id, call, private_key, nonce) do
          {:ok, hash}
        else
          {:error, _} = err ->
            # Re-sync the nonce counter to chain truth on any failure. A
            # pre-broadcast failure (sign/estimate/send) leaves the nonce
            # unconsumed; a post-broadcast failure (the tx reverted, or its
            # receipt didn't arrive before the await timeout) already consumed
            # it. Either way, marking the counter unseeded makes the next
            # acquisition re-fetch the pending nonce from chain -- which reflects
            # whichever happened -- so we never reuse a consumed nonce nor strand
            # an unconsumed one.
            NonceServer.resync(nonce_server)
            err
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, hash} -> hash end)}
      err -> err
    end
  end

  # Assign the next nonce, serialized through the wallet's NonceServer so two
  # concurrent `send_calls` for the same EOA can never sign the same nonce (the
  # GenServer mailbox is the serialization point). When the counter is unseeded
  # -- first use, or after a failed send reset it -- fetch the pending nonce from
  # chain once and adopt it atomically: `seed_and_next/2` closes the first-use
  # race so two callers that both observe `:unseeded` still receive distinct,
  # monotonic nonces.
  defp acquire_nonce(nonce_server, client, address) do
    case NonceServer.get_next_if_seeded(nonce_server) do
      {:ok, nonce} ->
        {:ok, nonce}

      :unseeded ->
        with {:ok, chain_nonce} <- RPC.get_transaction_count(client, address) do
          {:ok, NonceServer.seed_and_next(nonce_server, chain_nonce)}
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
         {:ok, hash} <- RPC.send_raw_transaction(client, signed),
         {:ok, receipt} <- RPC.await_receipt(client, hash, adapter.config.receipt_wait_opts),
         :ok <- confirm_success(receipt, hash) do
      {:ok, hash}
    end
  end

  # A broadcast tx is only a successful write once it is MINED and its receipt
  # reports success. `eth_getTransactionReceipt.status` is `0x0` for a reverted
  # tx (mined, nonce consumed, but the call rolled back); returning `{:ok, hash}`
  # for it would let the Provider mirror a write the chain undid. Reject an
  # explicit revert so the session stays put -- parity with the SCA path, which
  # checks the UserOp receipt's `success` flag. A receipt without a `status`
  # keeps the prior lenient behavior.
  defp confirm_success(receipt, hash) do
    if reverted?(receipt), do: {:error, {:tx_reverted, hash}}, else: :ok
  end

  defp reverted?(%{"status" => "0x" <> hex}), do: match?({0, ""}, Integer.parse(hex, 16))
  defp reverted?(_receipt), do: false

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

            prio =
              reward |> List.first() |> List.first() |> decode_hex_uint!() |> max(1_000_000_000)

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

    case ExSecp256k1.sign(digest, Secret.reveal(private_key)) do
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
