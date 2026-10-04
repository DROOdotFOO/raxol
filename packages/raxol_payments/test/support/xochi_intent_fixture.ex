defmodule Raxol.Payments.Test.XochiIntentFixture do
  @moduledoc """
  Riddler-shaped `XochiIntent` typed data for fake Xochi quote endpoints.

  `Protocols.Xochi.validate_intent/2` refuses to sign an intent whose signed
  terms differ from the request, so a fake must serve the intent Riddler would
  build for the request it received (`Riddler.Integrations.Xochi.EIP712`):
  wallet, recipient (`recipient_address`, else `wallet`), chains, tokens,
  `fromAmount`, `toAmount`, `settlementPreference` and a deadline five minutes
  out.

  A fake reads the posted quote body with `quote_body/1` and serves
  `eip712(body, to_amount)` alongside the same `to_amount` at the top level.
  Tests that exercise a hostile quote pass `:message` overrides.
  """

  alias Raxol.Payments.Xochi.Schemas.QuoteRequest

  @types %{
    "EIP712Domain" => [
      %{"name" => "name", "type" => "string"},
      %{"name" => "version", "type" => "string"},
      %{"name" => "chainId", "type" => "uint256"},
      %{"name" => "salt", "type" => "bytes32"}
    ],
    "XochiIntent" => [
      %{"name" => "intentId", "type" => "string"},
      %{"name" => "quoteId", "type" => "string"},
      %{"name" => "wallet", "type" => "address"},
      %{"name" => "recipient", "type" => "string"},
      %{"name" => "fromChainId", "type" => "uint256"},
      %{"name" => "toChainId", "type" => "uint256"},
      %{"name" => "fromToken", "type" => "string"},
      %{"name" => "toToken", "type" => "string"},
      %{"name" => "fromAmount", "type" => "uint256"},
      %{"name" => "toAmount", "type" => "uint256"},
      %{"name" => "settlementPreference", "type" => "string"},
      %{"name" => "deadline", "type" => "uint256"}
    ]
  }

  @doc "The `XochiIntent` types map Riddler serves."
  @spec types() :: map()
  def types, do: @types

  @doc """
  Read and decode a fake's posted quote body. Returns `{body, conn}`.
  """
  @spec quote_body(Plug.Conn.t()) :: {map(), Plug.Conn.t()}
  def quote_body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw), conn}
  end

  @doc """
  The served `eip712` payload for a quote request.

  `request` is the decoded wire body (string keys) or a `%QuoteRequest{}`.
  On an `exact_output` request `to_amount` defaults to its `output_amount`
  and `fromAmount` must be supplied via `from_amount:`.

  Options:

    * `:from_amount` -- the signed `fromAmount` (default: the request's).
    * `:intent_id`, `:quote_id` -- default `"int_1"` / `"q_1"`.
    * `:domain` -- replaces the served domain.
    * `:message` -- merged over the built message (string keys), to serve a
      hostile intent.
  """
  @spec eip712(map() | QuoteRequest.t(), String.t() | integer() | nil, keyword()) :: map()
  def eip712(request, to_amount \\ nil, opts \\ [])

  def eip712(%QuoteRequest{} = request, to_amount, opts) do
    request |> QuoteRequest.to_json() |> eip712(to_amount, opts)
  end

  def eip712(%{} = body, to_amount, opts) do
    from_chain = body["from_chain_id"]

    message =
      body
      |> intent_message(to_amount || body["output_amount"], opts)
      |> Map.merge(Keyword.get(opts, :message, %{}))

    %{
      "domain" => Keyword.get(opts, :domain, default_domain(from_chain)),
      "primaryType" => "XochiIntent",
      "types" => @types,
      "message" => message
    }
  end

  defp intent_message(body, to_amount, opts) do
    %{
      "intentId" => Keyword.get(opts, :intent_id, "int_1"),
      "quoteId" => Keyword.get(opts, :quote_id, "q_1"),
      "wallet" => lower(body["wallet"]),
      "recipient" => body["recipient_address"] || lower(body["wallet"]),
      "fromChainId" => body["from_chain_id"],
      "toChainId" => body["to_chain_id"],
      "fromToken" => lower(body["from_token"]),
      "toToken" => lower(body["to_token"]),
      "fromAmount" => to_string(Keyword.get(opts, :from_amount, body["from_amount"])),
      "toAmount" => to_string(to_amount),
      "settlementPreference" => body["settlement_preference"] || "public",
      "deadline" => System.system_time(:second) + 300
    }
  end

  defp default_domain(from_chain) do
    %{
      "name" => "Xochi",
      "version" => "3",
      "chainId" => from_chain,
      "salt" => "0x" <> String.duplicate("00", 31) <> "01"
    }
  end

  defp lower("0x" <> _ = address), do: String.downcase(address)
  defp lower(value), do: value
end
