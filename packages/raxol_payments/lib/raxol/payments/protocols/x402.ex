defmodule Raxol.Payments.Protocols.X402 do
  @moduledoc """
  x402 payment protocol client (Coinbase/Linux Foundation).

  Handles the HTTP 402 flow using EIP-712 signed ERC-3009
  `transferWithAuthorization` messages. The server returns a
  `payment-required` header with Base64-encoded payment requirements;
  this module decodes it, signs with the wallet, and builds the
  `x-payment` header for the retry request.

  ## Header Flow

  1. Server -> `402` + `payment-required: <base64 JSON>`
  2. Client -> retry + `x-payment: <base64 signed payload>`
  3. Server -> `200` + `x-payment-response: <base64 receipt>`
  """

  @behaviour Raxol.Payments.Protocol

  alias Raxol.Payments.Headers

  @impl true
  @spec name() :: String.t()
  def name, do: "x402"

  @impl true
  @spec detect?(integer(), Headers.headers()) :: boolean()
  def detect?(402, headers) do
    Headers.find(headers, "payment-required") |> is_binary()
  end

  def detect?(_status, _headers), do: false

  @impl true
  @spec parse_challenge(Headers.headers()) :: {:ok, map()} | {:error, term()}
  def parse_challenge(headers) do
    with {:ok, encoded} <- Headers.require(headers, "payment-required"),
         {:ok, json} <- Base.decode64(encoded),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(json),
         price when not is_nil(price) <-
           decoded["maxAmountRequired"] || decoded["price"],
         :ok <- validate_positive_amount(price),
         pay_to when not is_nil(pay_to) <- decoded["payTo"] || decoded["pay_to"],
         :ok <- validate_address(pay_to) do
      {:ok,
       %{
         price: price,
         currency: decoded["asset"] || decoded["currency"],
         network: decoded["network"],
         pay_to: pay_to,
         nonce: decoded["nonce"],
         valid_after: decoded["validAfter"] || decoded["valid_after"] || 0,
         valid_before: decoded["validBefore"] || decoded["valid_before"],
         extra: decoded
       }}
    else
      nil -> {:error, :missing_required_field}
      {:error, _} = err -> err
      _ -> {:error, :invalid_challenge}
    end
  end

  @impl true
  @spec build_payment(map(), module()) ::
          {:ok, Headers.headers()} | {:error, term()}
  def build_payment(challenge, wallet) do
    chain_id = chain_id_from_network(challenge.network)
    %{name: name, version: version} = Raxol.Payments.Assets.UsdcDomains.lookup(chain_id)

    domain = %{
      name: name,
      version: version,
      chainId: chain_id,
      verifyingContract: challenge.currency
    }

    types = %{
      "TransferWithAuthorization" => [
        {"from", "address"},
        {"to", "address"},
        {"value", "uint256"},
        {"validAfter", "uint256"},
        {"validBefore", "uint256"},
        {"nonce", "bytes32"}
      ]
    }

    message = %{
      from: wallet.address(),
      to: challenge.pay_to,
      value: normalize_amount(challenge.price),
      validAfter: challenge.valid_after,
      validBefore: challenge.valid_before || :os.system_time(:second) + 3600,
      nonce: challenge.nonce || generate_nonce()
    }

    case wallet.sign_typed_data(domain, types, message) do
      {:ok, signature} ->
        payload =
          Jason.encode!(%{
            signature: "0x" <> Base.encode16(signature, case: :lower),
            message: message,
            network: challenge.network
          })

        encoded = Base.encode64(payload)
        {:ok, [{"x-payment", encoded}]}

      {:error, reason} ->
        {:error, {:sign_failed, reason}}
    end
  end

  @impl true
  @spec parse_receipt(Headers.headers()) :: {:ok, map()} | {:error, term()}
  def parse_receipt(headers) do
    case Headers.find(headers, "x-payment-response") do
      nil ->
        {:error, :no_receipt}

      encoded ->
        with {:ok, json} <- Base.decode64(encoded),
             {:ok, decoded} <- Jason.decode(json) do
          {:ok,
           %{
             tx_hash: decoded["transactionHash"] || decoded["tx_hash"],
             network: decoded["network"],
             success: decoded["success"] != false
           }}
        end
    end
  end

  @impl true
  @spec amount(map()) :: Decimal.t()
  def amount(challenge) do
    decimals =
      Raxol.Payments.Assets.decimals(challenge.network, challenge.currency)

    Raxol.Payments.Assets.to_human(challenge.price, decimals)
  end

  # -- Private --

  defp chain_id_from_network(nil), do: 8453

  defp chain_id_from_network(network) when is_binary(network) do
    case String.split(network, ":") do
      ["eip155", chain_id] -> String.to_integer(chain_id)
      _ -> 8453
    end
  end

  defp chain_id_from_network(chain_id) when is_integer(chain_id), do: chain_id

  defp normalize_amount(amount) when is_integer(amount) and amount >= 0,
    do: amount

  defp normalize_amount(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {int, ""} when int >= 0 -> int
      _ -> 0
    end
  end

  defp normalize_amount(amount) when is_float(amount) and amount >= 0 do
    # USDC has 6 decimals; other tokens may differ
    round(amount * 1_000_000)
  end

  defp normalize_amount(_amount), do: 0

  defp generate_nonce do
    :crypto.strong_rand_bytes(32)
    |> Base.encode16(case: :lower)
    |> then(&("0x" <> &1))
  end

  defp validate_positive_amount(amount) when is_integer(amount) and amount > 0,
    do: :ok

  defp validate_positive_amount(amount) when is_float(amount) and amount > 0,
    do: :ok

  defp validate_positive_amount(amount) when is_binary(amount) do
    case Decimal.parse(amount) do
      {dec, ""} ->
        if Decimal.positive?(dec),
          do: :ok,
          else: {:error, {:invalid_amount, amount}}

      _ ->
        {:error, {:invalid_amount, amount}}
    end
  rescue
    Decimal.Error -> {:error, {:invalid_amount, amount}}
  end

  defp validate_positive_amount(amount), do: {:error, {:invalid_amount, amount}}

  @address_regex ~r/\A0x[0-9a-fA-F]{40}\z/

  defp validate_address(addr) when is_binary(addr) do
    if Regex.match?(@address_regex, addr),
      do: :ok,
      else: {:error, {:invalid_address, addr}}
  end

  defp validate_address(addr), do: {:error, {:invalid_address, addr}}
end
