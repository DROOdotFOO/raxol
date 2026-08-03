defmodule Raxol.Earn.Wallet.SCA.Paymaster do
  @moduledoc """
  Alchemy Gas Manager integration -- the sponsorship step that makes
  agent UserOperations gasless.

  Verified against `@account-kit/infra@4.88.4`
  (`alchemyGasAndPaymasterAndDataMiddleware`). Alchemy exposes a single
  combined RPC method that estimates gas **and** returns the paymaster
  sponsorship in one round trip:

      alchemy_requestGasAndPaymasterAndData

  The request goes to the same Alchemy endpoint as the bundler (Alchemy
  multiplexes node + bundler + paymaster on one API-keyed URL).

  ## Request

      params: [{
        policyId,
        entryPoint,
        userOperation: <unpacked v0.7 userOp, sender/nonce/callData
                        + factory if deploying; gas fields optional>,
        dummySignature,
        overrides?,        # gas/fee multipliers or absolute overrides
        webhookData?,
        erc20Context?      # only for erc20-token policies
      }]

  ## Response

  A partial UserOp the caller merges over its own
  (`{ ...uo, ...result }` in the SDK):

      paymaster, paymasterData,
      paymasterVerificationGasLimit, paymasterPostOpGasLimit,
      callGasLimit, verificationGasLimit, preVerificationGas,
      maxFeePerGas, maxPriorityFeePerGas

  `sponsor/4` performs the call and folds the response into a
  `Raxol.Earn.Wallet.SCA.UserOp`, leaving only the signature to fill.
  """

  alias Raxol.Earn.Onchain.Hex
  alias Raxol.Earn.Wallet.SCA.{Bundler, ModularAccount, UserOp}

  @rpc_method "alchemy_requestGasAndPaymasterAndData"

  @type sponsor_error ::
          Bundler.rpc_error() | {:missing_field, String.t()}

  @doc """
  Sponsor a UserOp: ask the Alchemy gas manager to fill gas estimates
  and paymaster data, then fold the result into `op`.

  The returned UserOp has every field except `signature` populated and
  is ready to hash + sign + send.

  Options:
  - `:dummy_signature` -- override the dummy sig (default
    `ModularAccount.dummy_uo_signature/0`).
  - `:overrides` -- map of gas/fee overrides passed through verbatim.
  - `:req` -- override the Req struct (for tests).
  """
  @spec sponsor(String.t(), String.t(), String.t(), UserOp.t(), keyword()) ::
          {:ok, UserOp.t()} | {:error, sponsor_error()}
  def sponsor(url, policy_id, entry_point, %UserOp{} = op, opts \\ []) do
    dummy_sig = Keyword.get(opts, :dummy_signature, ModularAccount.dummy_uo_signature())

    request = %{
      "policyId" => policy_id,
      "entryPoint" => entry_point,
      "userOperation" => request_user_op(op),
      "dummySignature" => Hex.encode(dummy_sig)
    }

    request = maybe_put_overrides(request, Keyword.get(opts, :overrides))

    case rpc(url, @rpc_method, [request], opts) do
      {:ok, result} when is_map(result) -> {:ok, merge_response(op, result)}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, _} = err -> err
    end
  end

  # The userOp we send for sponsorship: identity + callData (+ factory).
  # Gas/fee fields are intentionally omitted -- the gas manager fills
  # them. We reuse the bundler's RPC serializer then strip the gas
  # fields so the manager doesn't treat zeros as hard overrides.
  defp request_user_op(op) do
    op
    |> Bundler.pack_for_rpc()
    |> Map.drop([
      "callGasLimit",
      "verificationGasLimit",
      "preVerificationGas",
      "maxFeePerGas",
      "maxPriorityFeePerGas",
      "paymaster",
      "paymasterVerificationGasLimit",
      "paymasterPostOpGasLimit",
      "paymasterData",
      "signature"
    ])
  end

  defp maybe_put_overrides(request, nil), do: request
  defp maybe_put_overrides(request, overrides), do: Map.put(request, "overrides", overrides)

  # Fold the gas-manager response into the UserOp struct. Quantity
  # fields decode to integers; paymaster/paymasterData decode to bytes.
  defp merge_response(op, result) do
    %{
      op
      | call_gas_limit: quantity(result, "callGasLimit", op.call_gas_limit),
        verification_gas_limit:
          quantity(result, "verificationGasLimit", op.verification_gas_limit),
        pre_verification_gas: quantity(result, "preVerificationGas", op.pre_verification_gas),
        max_fee_per_gas: quantity(result, "maxFeePerGas", op.max_fee_per_gas),
        max_priority_fee_per_gas:
          quantity(result, "maxPriorityFeePerGas", op.max_priority_fee_per_gas),
        paymaster: Map.get(result, "paymaster", op.paymaster),
        paymaster_verification_gas_limit:
          quantity(result, "paymasterVerificationGasLimit", op.paymaster_verification_gas_limit),
        paymaster_post_op_gas_limit:
          quantity(result, "paymasterPostOpGasLimit", op.paymaster_post_op_gas_limit),
        paymaster_data: bytes(result, "paymasterData", op.paymaster_data)
    }
  end

  defp quantity(map, key, default) do
    case Map.get(map, key) do
      nil -> default
      hex when is_binary(hex) -> Bundler.decode_quantity(hex)
    end
  end

  defp bytes(map, key, default) do
    case Map.get(map, key) do
      nil -> default
      "0x" <> hex -> Base.decode16!(hex, case: :mixed)
    end
  end

  # Shares the bundler's JSON-RPC envelope.
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
end
