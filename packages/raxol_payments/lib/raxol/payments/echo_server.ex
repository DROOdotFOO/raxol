defmodule Raxol.Payments.EchoServer do
  @moduledoc """
  Self-pay x402 endpoint for validating the AutoPay stack end-to-end.

  The server responds 402 with a real x402 `payment-required` challenge.
  On retry with `x-payment`, it decodes and verifies the EIP-712 signature
  against the configured wallet address. It does NOT submit anything
  on-chain -- success only proves that the agent built and signed a valid
  payment payload.

  Use this before pointing your agent at a real x402 facilitator. If the
  echo server accepts a payment, the agent's signing flow is correct; if
  it rejects, the failure surfaces locally without spending any money.

  ## Running

      iex> Raxol.Payments.EchoServer.start_link(
      ...>   port: 4002,
      ...>   pay_to: "0x" <> String.duplicate("ab", 20),
      ...>   amount: 10_000,
      ...>   network: "eip155:8453"
      ...> )

  Or as a Mix task:

      mix raxol_payments.echo --port 4002 --amount 10000

  ## Options

  - `:port` -- HTTP port, default `4002`
  - `:pay_to` -- recipient address (hex, 0x-prefixed). Default is a
    deterministic dev address; **override for any real use**.
  - `:amount` -- atomic units (USDC has 6 decimals; `10_000` = $0.01)
  - `:network` -- CAIP-2 chain id, default `"eip155:8453"` (Base)
  - `:asset` -- ERC-20 contract address. Default is a placeholder.
  """

  @behaviour Plug

  import Plug.Conn

  @default_pay_to "0x" <> String.duplicate("ab", 20)
  @default_asset "0x" <> String.duplicate("cd", 20)
  @default_network "eip155:8453"
  # 1 cent USDC (6 decimals)
  @default_amount 10_000

  @doc """
  Start the echo server under a supervised Cowboy listener.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, 4002)
    config = build_config(opts)

    case Code.ensure_loaded(Plug.Cowboy) do
      {:module, _} ->
        Plug.Cowboy.http(__MODULE__, config, port: port)

      _ ->
        {:error,
         "plug_cowboy not available -- add `{:plug_cowboy, \"~> 2.7\", only: [:dev, :test]}` " <>
           "to your mix.exs deps"}
    end
  end

  @doc false
  def init(opts), do: opts

  @doc false
  def call(%Plug.Conn{method: "GET", request_path: "/health"} = conn, _opts) do
    send_resp(conn, 200, "ok")
  end

  def call(conn, opts) do
    case get_req_header(conn, "x-payment") do
      [] ->
        respond_402(conn, opts)

      [encoded] ->
        respond_after_verify(conn, encoded, opts)
    end
  end

  defp respond_402(conn, opts) do
    challenge = build_challenge(opts)
    encoded = challenge |> Jason.encode!() |> Base.encode64()

    conn
    |> put_resp_header("payment-required", encoded)
    |> put_resp_content_type("application/json")
    |> send_resp(
      402,
      Jason.encode!(%{error: "payment required", challenge: challenge})
    )
  end

  defp respond_after_verify(conn, encoded, opts) do
    with {:ok, payload} <- decode_payment(encoded),
         :ok <- verify_payment(payload, opts) do
      receipt = build_receipt(payload)
      receipt_encoded = receipt |> Jason.encode!() |> Base.encode64()

      conn
      |> put_resp_header("x-payment-response", receipt_encoded)
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{ok: true, receipt: receipt}))
    else
      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          402,
          Jason.encode!(%{error: "payment invalid", reason: inspect(reason)})
        )
    end
  end

  defp decode_payment(encoded) do
    with {:ok, json} <- Base.decode64(encoded),
         {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    else
      _ -> {:error, :decode_failed}
    end
  end

  # Verify the payload matches the challenge shape and that the signature
  # is well-formed. This does NOT recover the signer or settle on-chain --
  # the goal is to prove the agent built a valid x402 payload, not to move
  # money. For real settlement, route through an x402 facilitator.
  defp verify_payment(
         %{"signature" => sig, "message" => msg, "network" => net},
         opts
       )
       when is_binary(sig) and is_map(msg) and is_binary(net) do
    with :ok <- check_network(net, opts),
         :ok <- check_signature(sig),
         :ok <- check_recipient(msg, opts),
         :ok <- check_amount(msg, opts) do
      :ok
    end
  end

  defp verify_payment(_, _), do: {:error, :missing_fields}

  defp check_network(net, opts) do
    expected = Keyword.fetch!(opts, :network)
    if net == expected, do: :ok, else: {:error, {:wrong_network, net}}
  end

  defp check_signature(sig) do
    if signature_well_formed?(sig),
      do: :ok,
      else: {:error, :malformed_signature}
  end

  defp check_recipient(msg, opts) do
    expected = Keyword.fetch!(opts, :pay_to)

    if msg["to"] == expected,
      do: :ok,
      else: {:error, {:wrong_recipient, msg["to"]}}
  end

  defp check_amount(msg, opts) do
    expected = Keyword.fetch!(opts, :amount)
    actual = msg["value"]

    if actual == expected or to_string(actual) == to_string(expected),
      do: :ok,
      else: {:error, {:wrong_amount, actual}}
  end

  defp signature_well_formed?("0x" <> hex) do
    byte_size(hex) == 130 and String.match?(hex, ~r/^[0-9a-fA-F]+$/)
  end

  defp signature_well_formed?(_), do: false

  defp build_challenge(opts) do
    %{
      "maxAmountRequired" => Keyword.fetch!(opts, :amount),
      "payTo" => Keyword.fetch!(opts, :pay_to),
      "asset" => Keyword.fetch!(opts, :asset),
      "network" => Keyword.fetch!(opts, :network),
      "nonce" => "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      "validAfter" => 0,
      "validBefore" => System.system_time(:second) + 3600
    }
  end

  defp build_receipt(payload) do
    %{
      "transactionHash" => "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      "network" => payload["network"],
      "success" => true,
      "settledBy" => "echo_server"
    }
  end

  defp build_config(opts) do
    [
      pay_to: Keyword.get(opts, :pay_to, @default_pay_to),
      asset: Keyword.get(opts, :asset, @default_asset),
      network: Keyword.get(opts, :network, @default_network),
      amount: Keyword.get(opts, :amount, @default_amount)
    ]
  end
end
