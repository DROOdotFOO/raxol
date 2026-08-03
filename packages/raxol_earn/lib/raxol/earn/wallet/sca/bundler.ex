defmodule Raxol.Earn.Wallet.SCA.Bundler do
  @moduledoc """
  ERC-4337 v0.7 bundler JSON-RPC client.

  Speaks the canonical bundler RPC over HTTP via `Req`. Implementations
  like Alchemy's Bundler API, Pimlico, Stackup, and Biconomy all
  expose the same set of methods documented in EIP-4337:

      eth_sendUserOperation
      eth_estimateUserOperationGas
      eth_getUserOperationReceipt
      eth_getUserOperationByHash
      eth_supportedEntryPoints
      eth_chainId

  ## UserOp shape on the wire (v0.7)

  The bundler RPC takes the **unpacked** UserOp -- separate gas/fee
  fields, not the bytes32-packed `accountGasLimits` / `gasFees` that
  EntryPoint v0.7 stores on-chain. We accept a
  `Raxol.Earn.Wallet.SCA.UserOp` struct and serialize it to the RPC
  shape; `pack_for_rpc/1` is the public helper.

  ## Hex quantity encoding

  Bundler methods follow Ethereum JSON-RPC's "quantity" encoding for
  integers: `0x`-prefixed, lower-case hex, no leading zeros except a
  single `0x0` for zero. We hand-roll that to avoid pulling in another
  dep.

  ## Returns

  Methods return `{:ok, decoded}` or `{:error, reason}` where reason
  is one of:

      :transport_error           # HTTP/connection problem
      {:rpc_error, code, msg}    # JSON-RPC error response
      {:unexpected, value}       # response shape we don't recognize
  """

  alias Raxol.Earn.Onchain.Hex
  alias Raxol.Earn.Wallet.SCA.UserOp

  @type address :: String.t()
  @type hex :: String.t()
  @type rpc_error ::
          :transport_error | {:rpc_error, integer(), String.t()} | {:unexpected, term()}

  @doc """
  Send a fully-signed UserOp to the bundler. Returns the `userOpHash`
  the bundler computes (matches `UserOp.hash/3` locally if everything
  is in sync).

  Options:
  - `:req` -- override the Req struct (for tests).
  """
  @spec send_user_operation(String.t(), UserOp.t(), address(), keyword()) ::
          {:ok, hex()} | {:error, rpc_error()}
  def send_user_operation(url, %UserOp{} = op, entry_point, opts \\ []) do
    rpc(url, "eth_sendUserOperation", [pack_for_rpc(op), entry_point], opts)
  end

  @doc """
  Ask the bundler to estimate gas for a UserOp. Returns a map with
  `preVerificationGas`, `verificationGasLimit`, `callGasLimit`, and
  optionally `paymasterVerificationGasLimit` / `paymasterPostOpGasLimit`
  (all as integers, decoded from the RPC hex quantities).
  """
  @spec estimate_user_operation_gas(String.t(), UserOp.t(), address(), keyword()) ::
          {:ok, map()} | {:error, rpc_error()}
  def estimate_user_operation_gas(url, %UserOp{} = op, entry_point, opts \\ []) do
    case rpc(url, "eth_estimateUserOperationGas", [pack_for_rpc(op), entry_point], opts) do
      {:ok, gas_map} when is_map(gas_map) -> {:ok, decode_gas_map(gas_map)}
      other -> other
    end
  end

  @doc """
  Look up a UserOp's receipt by its `userOpHash`. Returns `{:ok, nil}`
  if the bundler hasn't seen it yet (still in mempool or unknown).
  """
  @spec get_user_operation_receipt(String.t(), hex(), keyword()) ::
          {:ok, map() | nil} | {:error, rpc_error()}
  def get_user_operation_receipt(url, op_hash, opts \\ []) do
    rpc(url, "eth_getUserOperationReceipt", [op_hash], opts)
  end

  @doc """
  Look up a UserOp by its hash. Useful for confirming the bundler
  accepted the op (returns the userOp + block info once mined).
  """
  @spec get_user_operation_by_hash(String.t(), hex(), keyword()) ::
          {:ok, map() | nil} | {:error, rpc_error()}
  def get_user_operation_by_hash(url, op_hash, opts \\ []) do
    rpc(url, "eth_getUserOperationByHash", [op_hash], opts)
  end

  @doc "Return the list of EntryPoint addresses the bundler supports."
  @spec supported_entry_points(String.t(), keyword()) ::
          {:ok, [address()]} | {:error, rpc_error()}
  def supported_entry_points(url, opts \\ []) do
    rpc(url, "eth_supportedEntryPoints", [], opts)
  end

  @doc "Return the chain id the bundler reports for the connected network."
  @spec chain_id(String.t(), keyword()) :: {:ok, pos_integer()} | {:error, rpc_error()}
  def chain_id(url, opts \\ []) do
    case rpc(url, "eth_chainId", [], opts) do
      {:ok, hex_quantity} -> {:ok, decode_quantity(hex_quantity)}
      other -> other
    end
  end

  @doc """
  Wait for a UserOp to be mined, polling at most `max_attempts` times
  with `interval_ms` between attempts. Returns the receipt or
  `{:error, :timeout}`.
  """
  @spec wait_for_receipt(String.t(), hex(), keyword()) ::
          {:ok, map()} | {:error, :timeout | rpc_error()}
  def wait_for_receipt(url, op_hash, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 30)
    interval_ms = Keyword.get(opts, :interval_ms, 1_000)
    do_wait_for_receipt(url, op_hash, opts, max_attempts, interval_ms)
  end

  defp do_wait_for_receipt(_url, _hash, _opts, 0, _interval), do: {:error, :timeout}

  defp do_wait_for_receipt(url, hash, opts, attempts, interval) do
    case get_user_operation_receipt(url, hash, opts) do
      {:ok, nil} ->
        Process.sleep(interval)
        do_wait_for_receipt(url, hash, opts, attempts - 1, interval)

      {:ok, receipt} when is_map(receipt) ->
        {:ok, receipt}

      {:error, _} = err ->
        err
    end
  end

  # -- UserOp <-> RPC shape --

  @doc """
  Serialize a `UserOp` struct to the bundler RPC JSON shape (unpacked
  v0.7 format). All integer fields become hex quantities and all
  binary fields become 0x-prefixed hex strings.

  Optional fields (paymaster, factory) are omitted when nil/empty so
  the bundler treats them as "not present" rather than zero-padded.
  """
  @spec pack_for_rpc(UserOp.t()) :: map()
  def pack_for_rpc(%UserOp{} = op) do
    base = %{
      "sender" => op.sender,
      "nonce" => encode_quantity(op.nonce),
      "callData" => hex_bytes(op.call_data),
      "callGasLimit" => encode_quantity(op.call_gas_limit),
      "verificationGasLimit" => encode_quantity(op.verification_gas_limit),
      "preVerificationGas" => encode_quantity(op.pre_verification_gas),
      "maxFeePerGas" => encode_quantity(op.max_fee_per_gas),
      "maxPriorityFeePerGas" => encode_quantity(op.max_priority_fee_per_gas),
      "signature" => hex_bytes(op.signature)
    }

    base
    |> maybe_put_init_code(op.init_code)
    |> maybe_put_paymaster(op)
  end

  defp maybe_put_init_code(map, <<>>), do: map

  defp maybe_put_init_code(map, init_code) when is_binary(init_code) do
    # v0.7 splits initCode into factory (first 20 bytes) + factoryData.
    <<factory::binary-size(20), factory_data::binary>> = init_code

    map
    |> Map.put("factory", Hex.encode(factory))
    |> Map.put("factoryData", hex_bytes(factory_data))
  end

  defp maybe_put_paymaster(map, %UserOp{paymaster: nil}), do: map

  defp maybe_put_paymaster(map, %UserOp{} = op) do
    map
    |> Map.put("paymaster", op.paymaster)
    |> Map.put(
      "paymasterVerificationGasLimit",
      encode_quantity(op.paymaster_verification_gas_limit)
    )
    |> Map.put(
      "paymasterPostOpGasLimit",
      encode_quantity(op.paymaster_post_op_gas_limit)
    )
    |> Map.put("paymasterData", hex_bytes(op.paymaster_data))
  end

  # -- RPC plumbing --

  defp rpc(url, method, params, opts) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive, :monotonic]),
      "method" => method,
      "params" => params
    }

    req = Keyword.get(opts, :req, Req.new(url: url))

    case Req.post(req, json: body) do
      {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %Req.Response{status: 200, body: %{"error" => %{"code" => code, "message" => msg}}}} ->
        {:error, {:rpc_error, code, msg}}

      {:ok, %Req.Response{body: body}} ->
        {:error, {:unexpected, body}}

      {:error, _reason} ->
        {:error, :transport_error}
    end
  end

  # -- Hex quantity encoding --

  @doc "Encode a non-negative integer as a JSON-RPC quantity hex string."
  @spec encode_quantity(non_neg_integer()) :: hex()
  def encode_quantity(n) when is_integer(n) and n >= 0, do: Hex.encode_quantity(n)

  @doc "Decode a JSON-RPC quantity hex string into an integer."
  @spec decode_quantity(hex()) :: non_neg_integer()
  def decode_quantity(hex), do: Hex.decode_quantity!(hex)

  defp hex_bytes(<<>>), do: "0x"
  defp hex_bytes(bin) when is_binary(bin), do: Hex.encode(bin)

  defp decode_gas_map(map) do
    keys = [
      "preVerificationGas",
      "verificationGasLimit",
      "callGasLimit",
      "paymasterVerificationGasLimit",
      "paymasterPostOpGasLimit"
    ]

    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.get(map, key) do
        nil -> acc
        hex when is_binary(hex) -> Map.put(acc, atom_key(key), decode_quantity(hex))
      end
    end)
  end

  defp atom_key("preVerificationGas"), do: :pre_verification_gas
  defp atom_key("verificationGasLimit"), do: :verification_gas_limit
  defp atom_key("callGasLimit"), do: :call_gas_limit
  defp atom_key("paymasterVerificationGasLimit"), do: :paymaster_verification_gas_limit
  defp atom_key("paymasterPostOpGasLimit"), do: :paymaster_post_op_gas_limit
end
