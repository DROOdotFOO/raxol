defmodule Raxol.Payments.Actions.Payments.ExecuteXochiIntent do
  @moduledoc """
  Agent Action that runs a cross-chain (and optionally stealth) Xochi intent.

  Quotes the intent, authorizes the spend through `SpendGate` before any
  signature is released, signs and submits via the wallet, and returns the
  intent id and initial status. Poll for the terminal status with
  `Raxol.Payments.Actions.Payments.PollXochiStatus`.

  The spend is gated on the human-decimal `amount`; the atomic `from_amount`
  sent to Xochi is derived from the token's decimals. If execution fails after
  the gate reserved budget, the reservation is released.

  ## Context keys

  * `:wallet` -- wallet module signing the EIP-712 intent.
  * `:xochi_config` -- `%{base_url:, auth_token:}` for `Xochi.Client`.
  * `:policy`, `:ledger`, `:agent_id`, `:on_confirm` -- see `SpendGate`.
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_execute_xochi_intent",
    description:
      "Execute a cross-chain or stealth payment through Xochi: quote, authorize the spend, sign the EIP-712 intent, and submit. Returns the intent id and status to poll.",
    schema: [
      input: [
        amount: [
          type: :string,
          required: true,
          description: "Human-decimal amount to send, e.g. \"1.00\""
        ],
        from_chain_id: [type: :integer, required: true],
        to_chain_id: [type: :integer, required: true],
        from_token: [
          type: :string,
          required: true,
          description: "Source token contract (0x...)"
        ],
        to_token: [
          type: :string,
          required: true,
          description: "Destination token contract (0x...)"
        ],
        settlement: [
          type: :string,
          description: "public | stealth | shielded (default: stealth)"
        ],
        recipient_meta_address: [
          type: :string,
          description: "Recipient ERC-6538 stealth meta-address (st:eth:0x...)"
        ],
        slippage_bps: [type: :integer, description: "Max slippage (default 50)"],
        trust_score: [type: :integer, description: "Trust score for tier/fee"]
      ],
      output: [
        intent_id: [type: :string],
        status: [type: :string],
        from_amount: [type: :string],
        to_amount: [type: :string],
        xochi_fee: [type: :string],
        stealth_address: [type: :string]
      ]
    ]

  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.{Assets, Failure, Router}
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse}
  alias Raxol.Payments.Xochi.Stealth

  @spec run(map(), map()) :: {:ok, map()} | {:error, Failure.t()}
  @impl true
  def run(params, context) do
    with {:ok, wallet} <- fetch(context, :wallet),
         {:ok, config} <- fetch(context, :xochi_config),
         {:ok, request, amount} <- build_request(params, wallet) do
      settle(config, wallet, request, amount, params, context)
    end
    |> normalize_error()
  end

  defp normalize_error({:ok, _result} = ok), do: ok
  defp normalize_error({:error, reason}), do: {:error, Failure.from(reason)}

  defp settle(config, wallet, request, amount, params, context) do
    with :ok <- assert_xochi_route(params),
         {:ok, quote} <- solvable_quote(config, request),
         :ok <- authorize(context, config, amount),
         {:ok, exec, filled_quote} <- execute(config, request, quote, wallet, context, amount) do
      {:ok, summary(request, filled_quote, exec)}
    end
  end

  defp fetch(context, key) do
    case Map.fetch(context, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_context, key}}
    end
  end

  defp build_request(params, wallet) do
    amount = Decimal.new(Map.fetch!(params, :amount))
    from_token = Map.fetch!(params, :from_token)
    from_chain = Map.fetch!(params, :from_chain_id)
    decimals = Assets.decimals(from_chain, from_token)
    from_amount = Integer.to_string(Assets.to_atomic(amount, decimals))
    settlement = settlement(params)

    with {:ok, spending_key, viewing_key} <- stealth_keys(settlement, params) do
      request = %QuoteRequest{
        wallet: wallet.address(),
        from_chain_id: from_chain,
        to_chain_id: Map.fetch!(params, :to_chain_id),
        from_token: from_token,
        to_token: Map.fetch!(params, :to_token),
        from_amount: from_amount,
        settlement_preference: settlement,
        slippage_bps: Map.get(params, :slippage_bps, 50),
        trust_score: Map.get(params, :trust_score),
        stealth_spending_pub_key: spending_key,
        stealth_viewing_pub_key: viewing_key
      }

      {:ok, request, amount}
    end
  end

  defp settlement(params), do: Map.get(params, :settlement, "stealth")

  # Stealth settlement: derive the recipient's compressed spending and viewing
  # public keys from their ERC-6538 meta-address. Xochi (Riddler) rejects a
  # stealth quote without them, and derives the stealth address + announcement
  # server-side from these keys, so the client only supplies the keys.
  defp stealth_keys("stealth", %{recipient_meta_address: meta, to_chain_id: chain})
       when is_binary(meta) do
    case Stealth.decode_meta_address(meta, chain) do
      {:ok, %{spending_pub_key: spending, viewing_pub_key: viewing}} ->
        {:ok, encode_pub_key(spending), encode_pub_key(viewing)}

      {:error, reason} ->
        {:error, {:invalid_meta_address, reason}}
    end
  end

  defp stealth_keys("stealth", _params), do: {:error, :stealth_meta_address_required}
  defp stealth_keys(_settlement, _params), do: {:ok, nil, nil}

  defp encode_pub_key(pub_key), do: "0x" <> Base.encode16(pub_key, case: :lower)

  defp assert_xochi_route(params) do
    cross_chain = Map.fetch!(params, :from_chain_id) != Map.fetch!(params, :to_chain_id)

    case settlement_atom(settlement(params)) do
      :invalid ->
        {:error, {:invalid_settlement, settlement(params)}}

      privacy ->
        case Router.select(cross_chain: cross_chain, privacy: privacy) do
          :xochi -> :ok
          other -> {:error, {:not_xochi_route, other}}
        end
    end
  end

  defp settlement_atom("public"), do: :public
  defp settlement_atom("stealth"), do: :stealth
  defp settlement_atom("shielded"), do: :shielded
  defp settlement_atom(_), do: :invalid

  defp solvable_quote(config, request) do
    case Xochi.get_quote(config, request) do
      {:ok, %QuoteResponse{can_solve: true} = quote} -> {:ok, quote}
      {:ok, %QuoteResponse{error: err}} -> {:error, {:cannot_solve, err}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize(context, config, amount) do
    host = config |> Map.fetch!(:base_url) |> URI.parse() |> Map.get(:host)
    SpendGate.authorize(context, amount, target: {:domain, host}, metadata: %{protocol: :xochi})
  end

  # Load-balanced Riddler nodes occasionally miss a freshly issued quote and
  # reject the execute as expired/not-found. Re-quote and re-execute once under
  # the same spend reservation (same logical payment, so no second authorize).
  defp execute(config, request, quote, wallet, context, amount) do
    case Xochi.execute(config, quote, wallet) do
      {:ok, exec} ->
        {:ok, exec, quote}

      {:error, reason} ->
        if quote_expired?(reason),
          do: retry_execute(config, request, wallet, context, amount),
          else: release_and_error(context, amount, reason)
    end
  end

  defp retry_execute(config, request, wallet, context, amount) do
    with {:ok, quote} <- solvable_quote(config, request),
         {:ok, exec} <- Xochi.execute(config, quote, wallet) do
      {:ok, exec, quote}
    else
      {:error, reason} -> release_and_error(context, amount, reason)
    end
  end

  defp release_and_error(context, amount, reason) do
    SpendGate.release(context, amount, %{protocol: :xochi, reason: :execute_failed})
    {:error, {:execute_failed, reason}}
  end

  defp quote_expired?({:http, _status, body}) when is_map(body) do
    code = to_string(body["error"] || body["reason"] || "")
    message = to_string(body["message"] || "")

    String.contains?(code, "quote_expired") or code == "not_found" or
      String.contains?(String.downcase(message), "expired")
  end

  defp quote_expired?(_reason), do: false

  # The stealth address is whatever Xochi derived and announced server-side from
  # the supplied keys. We report that authoritative value; we do not derive one
  # client-side, since an independent derivation uses a different ephemeral key
  # and would name an address the funds never landed on.
  defp summary(request, quote, exec) do
    %{
      intent_id: exec.intent_id,
      status: to_string(exec.status),
      from_amount: request.from_amount,
      to_amount: quote.to_amount,
      xochi_fee: quote.xochi_fee,
      stealth_address: exec.stealth_address
    }
  end
end
