defmodule Raxol.Payments.Protocols.Riddler do
  @moduledoc """
  Riddler cross-chain intent solver protocol.

  **Deprecated:** Use `Raxol.Payments.Protocols.Xochi` instead. This module
  now delegates to Xochi internally, routing through `/xochi/*` endpoints
  instead of `/commerce/*`. The Commerce API remains available for B2B
  integrations but is not intended for agent use.

  ## Migration

  Replace:

      config = %{base_url: "https://riddler.example.com", api_key: "..."}
      Riddler.get_quote(config, %Riddler.Schemas.QuoteRequest{...})

  With:

      config = %{base_url: "https://riddler.example.com", auth_token: "..."}
      Xochi.get_quote(config, %Xochi.Schemas.QuoteRequest{...})
  """

  @behaviour Raxol.Payments.Protocol

  alias Raxol.Payments.Protocols.Xochi, as: XochiProtocol
  alias Raxol.Payments.Riddler.Schemas.{QuoteRequest, QuoteResponse, OrderStatus}
  alias Raxol.Payments.Xochi.Schemas, as: XochiSchemas

  @default_poll_interval_ms 2_000
  @default_poll_timeout_ms 120_000

  # -- Protocol behaviour (stubs -- Riddler is not a 402 protocol) --

  @impl true
  @spec name() :: String.t()
  def name, do: "Riddler"

  @impl true
  @spec detect?(integer(), [{String.t(), String.t()}]) :: boolean()
  def detect?(_status, _headers), do: false

  @impl true
  @spec parse_challenge([{String.t(), String.t()}]) :: {:error, :not_a_402_protocol}
  def parse_challenge(_headers), do: {:error, :not_a_402_protocol}

  @impl true
  @spec build_payment(map(), module()) :: {:error, :not_a_402_protocol}
  def build_payment(_challenge, _wallet), do: {:error, :not_a_402_protocol}

  @impl true
  @spec parse_receipt([{String.t(), String.t()}]) :: {:error, :not_a_402_protocol}
  def parse_receipt(_headers), do: {:error, :not_a_402_protocol}

  @impl true
  @spec amount(map()) :: Decimal.t()
  def amount(%{output_amount: amt}) when is_binary(amt), do: Decimal.new(amt)
  def amount(_challenge), do: Decimal.new(0)

  # -- Direct API (delegates to Xochi) --

  @doc """
  Request a cross-chain transfer quote.

  Deprecated: use `Raxol.Payments.Protocols.Xochi.get_quote/2`.

  Accepts either a `Riddler.Schemas.QuoteRequest` (mapped to Xochi format)
  or a `Xochi.Schemas.QuoteRequest` directly.
  """
  @spec get_quote(map(), QuoteRequest.t() | XochiSchemas.QuoteRequest.t()) ::
          {:ok, QuoteResponse.t()} | {:error, term()}
  def get_quote(config, %QuoteRequest{} = request) do
    xochi_config = to_xochi_config(config)
    xochi_request = to_xochi_quote_request(request)

    case XochiProtocol.get_quote(xochi_config, xochi_request) do
      {:ok, xochi_resp} -> {:ok, from_xochi_quote_response(xochi_resp)}
      {:error, _} = err -> err
    end
  end

  def get_quote(config, %XochiSchemas.QuoteRequest{} = request) do
    xochi_config = to_xochi_config(config)

    case XochiProtocol.get_quote(xochi_config, request) do
      {:ok, xochi_resp} -> {:ok, from_xochi_quote_response(xochi_resp)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Sign and submit an order for a given quote.

  Deprecated: use `Raxol.Payments.Protocols.Xochi.execute/4`.

  Signs with EIP-712 (Xochi typed data) instead of ERC-3009/Permit2.
  The quote must contain `eip712_data` with a `message` field, and its intent
  must match `request` (the request the quote was fetched for) or nothing is
  signed -- see `Raxol.Payments.Protocols.Xochi.validate_intent/2`.
  """
  @spec submit_order(map(), QuoteResponse.t(), module(), XochiSchemas.QuoteRequest.t()) ::
          {:ok, map()} | {:error, term()}
  def submit_order(
        config,
        %QuoteResponse{} = quote_resp,
        wallet,
        %XochiSchemas.QuoteRequest{} = request
      ) do
    xochi_config = to_xochi_config(config)
    xochi_quote = to_xochi_quote_response(quote_resp)

    case XochiProtocol.execute(xochi_config, xochi_quote, wallet, request) do
      {:ok, exec_resp} ->
        {:ok, %{"intentId" => exec_resp.intent_id, "status" => to_string(exec_resp.status)}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Poll order status until terminal or timeout.

  Deprecated: use `Raxol.Payments.Protocols.Xochi.poll_status/3`.

  ## Options

  - `:interval_ms` -- poll interval (default: #{@default_poll_interval_ms}ms)
  - `:timeout_ms` -- max wait time (default: #{@default_poll_timeout_ms}ms)
  """
  @spec poll_status(map(), String.t(), keyword()) ::
          {:ok, OrderStatus.t()} | {:error, term()}
  def poll_status(config, intent_id, opts \\ []) do
    xochi_config = to_xochi_config(config)

    xochi_opts = [
      interval_ms: Keyword.get(opts, :interval_ms, @default_poll_interval_ms),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_poll_timeout_ms)
    ]

    case XochiProtocol.poll_status(xochi_config, intent_id, xochi_opts) do
      {:ok, xochi_status} -> {:ok, from_xochi_intent_status(xochi_status)}
      {:error, _} = err -> err
    end
  end

  # -- Schema mapping --

  defp to_xochi_config(%{base_url: base_url, api_key: api_key}) do
    %{base_url: base_url, auth_token: api_key}
  end

  defp to_xochi_config(%{base_url: base_url, auth_token: auth_token}) do
    %{base_url: base_url, auth_token: auth_token}
  end

  defp to_xochi_quote_request(%QuoteRequest{} = req) do
    %XochiSchemas.QuoteRequest{
      wallet: req.refund_address,
      from_chain_id: req.input_chain_id,
      to_chain_id: req.output_chain_id,
      from_token: req.input_token,
      to_token: req.output_token,
      from_amount: req.input_amount,
      settlement_preference: "public",
      slippage_bps: 50
    }
  end

  defp from_xochi_quote_response(%XochiSchemas.QuoteResponse{} = resp) do
    %QuoteResponse{
      quote_id: resp.quote_id,
      output_amount: resp.to_amount,
      quote_expires: parse_expiry(resp.expiry),
      eip712_data: resp.eip712_data
    }
  end

  defp to_xochi_quote_response(%QuoteResponse{} = resp) do
    %XochiSchemas.QuoteResponse{
      intent_id: extract_intent_id(resp),
      quote_id: resp.quote_id,
      can_solve: true,
      to_amount: resp.output_amount,
      expiry: to_string(resp.quote_expires),
      eip712_data: resp.eip712_data
    }
  end

  defp from_xochi_intent_status(%XochiSchemas.IntentStatus{} = status) do
    %OrderStatus{
      order_id: status.intent_id,
      status: map_xochi_status(status.status),
      input_transaction: status.tx_hash,
      output_transaction: status.receiving_tx_hash,
      error_reason: status.error
    }
  end

  defp map_xochi_status(:executing), do: :settling
  defp map_xochi_status(:completed), do: :completed
  defp map_xochi_status(:failed), do: :failed
  defp map_xochi_status(:expired), do: :expired
  defp map_xochi_status(:pending), do: :pending
  defp map_xochi_status(other), do: other

  defp parse_expiry(nil), do: 0
  defp parse_expiry(val) when is_integer(val) and val >= 0, do: val
  defp parse_expiry(val) when is_integer(val), do: 0

  defp parse_expiry(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} when int >= 0 -> int
      _ -> 0
    end
  end

  defp extract_intent_id(%QuoteResponse{eip712_data: %{"message" => %{"intentId" => id}}}), do: id
  defp extract_intent_id(%QuoteResponse{eip712_data: %{message: %{intentId: id}}}), do: id
  defp extract_intent_id(_), do: nil
end
