defmodule Raxol.Payments.Actions.Payments.ExecuteRelayTransfer do
  @moduledoc """
  Agent Action that initiates a Tron cross-chain transfer through the Relay rail.

  Relay is deposit-address based: this Action quotes the transfer (which returns
  a Riddler-managed deposit address), authorizes the spend through `SpendGate`,
  and initiates execution. It does not broadcast the on-chain deposit itself --
  the wallet that holds the source funds sends them to the returned
  `deposit_address`; poll the result with
  `Raxol.Payments.Actions.Payments.PollRelayStatus`.

  Tron has no stealth settlement. A stealth or shielded request to a Tron
  destination is downgraded to public and a `:stealth_unavailable_on_tron`
  warning is attached to the result; the transfer still proceeds.

  ## Funding the deposit

  Three paths, picked from the quote and context:

  * **Gasless (A)** -- when the quote returns a `gasless` typed-data block, the
    wallet signs it and the signature rides on execute so the solver pulls. No
    broadcast. (Pending Riddler support on the Tron route, axol-io/Riddler#120.)
  * **Broadcast (B)** -- when a `:broadcaster` is in context, it sends the
    on-chain token transfer to the deposit address. Used until the gasless pull
    lands.
  * **External (C)** -- otherwise the deposit address is returned for an outside
    wallet to fund.

  ## Context keys

  * `:relay_config` -- `%{base_url:, auth_token:}` for `Relay.Client`.
  * `:wallet` -- defaults `from_address`; signs the gasless authorization (A).
  * `:broadcaster` -- a `Raxol.Payments.Relay.Broadcaster` module (B).
  * `:policy`, `:ledger`, `:agent_id`, `:on_confirm` -- see `SpendGate`.
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_execute_relay_transfer",
    description:
      "Initiate a Tron cross-chain transfer through Riddler Relay: quote, authorize the spend, and start execution. Returns the deposit address to fund and the transfer id to poll. Tron is public-only; a stealth request is downgraded with a warning.",
    schema: [
      input: [
        amount: [
          type: :string,
          required: true,
          description: "Human-decimal amount, e.g. \"1.00\""
        ],
        from_chain_id: [type: :integer, required: true],
        to_chain_id: [type: :integer, required: true],
        from_token: [type: :string, required: true],
        to_token: [type: :string, required: true],
        to_address: [
          type: :string,
          required: true,
          description: "Recipient address (Tron or EVM)"
        ],
        from_address: [
          type: :string,
          description: "Source address (defaults to the wallet address)"
        ],
        settlement: [
          type: :string,
          description: "public | stealth | shielded (Tron is public-only)"
        ],
        slippage_bps: [type: :integer, description: "Max slippage (default 50)"]
      ],
      output: [
        transfer_id: [type: :string],
        quote_id: [type: :string],
        deposit_address: [type: :string],
        deposit_tx_hash: [type: :string],
        funding: [type: :string],
        status: [type: :string],
        to_amount: [type: :string],
        warnings: [type: :list]
      ]
    ]

  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.{Assets, Failure, Relay, Router}
  alias Raxol.Payments.Relay.Schemas.{QuoteRequest, QuoteResponse}

  @spec run(map(), map()) :: {:ok, map()} | {:error, Failure.t()}
  @impl true
  def run(params, context) do
    with {:ok, config} <- fetch(context, :relay_config),
         {:ok, from_address} <- resolve_from_address(params, context),
         {:ok, request, amount, warnings} <- build_request(params, from_address) do
      settle(config, request, amount, warnings, context)
    end
    |> normalize_error()
  end

  defp normalize_error({:ok, _result} = ok), do: ok
  defp normalize_error({:error, reason}), do: {:error, Failure.from(reason)}

  defp settle(config, request, amount, warnings, context) do
    with :ok <- assert_relay_route(request),
         {:ok, quote} <- fillable_quote(config, request),
         :ok <- authorize(context, config, amount),
         {:ok, signature} <- maybe_sign_gasless(quote, context, amount),
         {:ok, status} <- execute(config, quote, signature, context, amount),
         {:ok, deposit_tx} <- maybe_broadcast(quote, request, signature, context, amount) do
      {:ok, summary(quote, status, warnings, signature, deposit_tx)}
    end
  end

  defp fetch(context, key) do
    case Map.fetch(context, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_context, key}}
    end
  end

  defp resolve_from_address(params, context) do
    case Map.get(params, :from_address) do
      addr when is_binary(addr) ->
        {:ok, addr}

      _ ->
        case Map.get(context, :wallet) do
          nil -> {:error, {:missing_context, :wallet}}
          wallet -> {:ok, wallet.address()}
        end
    end
  end

  defp build_request(params, from_address) do
    amount = Decimal.new(Map.fetch!(params, :amount))
    from_chain = Map.fetch!(params, :from_chain_id)
    from_token = Map.fetch!(params, :from_token)
    to_chain = Map.fetch!(params, :to_chain_id)
    decimals = Assets.decimals(from_chain, from_token)
    from_amount = Integer.to_string(Assets.to_atomic(amount, decimals))
    warnings = downgrade_warnings(Map.get(params, :settlement, "public"), to_chain)

    request = %QuoteRequest{
      transfer_id: generate_transfer_id(),
      from_chain_id: from_chain,
      to_chain_id: to_chain,
      from_token: from_token,
      to_token: Map.fetch!(params, :to_token),
      from_amount: from_amount,
      from_address: from_address,
      to_address: Map.fetch!(params, :to_address),
      slippage_bps: Map.get(params, :slippage_bps, 50)
    }

    {:ok, request, amount, warnings}
  end

  # Tron is public-only: a stealth/shielded request is downgraded to public and
  # the loss of privacy is surfaced, rather than silently dropped or blocked.
  defp downgrade_warnings(settlement, to_chain) do
    if settlement in ["stealth", "shielded"] and Relay.Schemas.tron_chain?(to_chain) do
      [
        %{
          code: :stealth_unavailable_on_tron,
          message:
            "Tron has no stealth settlement yet; this transfer was sent publicly. " <>
              "Use an EVM destination for a private settlement."
        }
      ]
    else
      []
    end
  end

  defp generate_transfer_id do
    "relay_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  defp assert_relay_route(%QuoteRequest{from_chain_id: from_chain, to_chain_id: to_chain}) do
    case Router.select(from_chain_id: from_chain, to_chain_id: to_chain) do
      :relay -> :ok
      other -> {:error, {:not_relay_route, other}}
    end
  end

  defp fillable_quote(config, request) do
    case Relay.get_quote(config, request) do
      {:ok, %QuoteResponse{can_fill: true} = quote} -> {:ok, quote}
      {:ok, %QuoteResponse{}} -> {:error, {:cannot_solve, nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize(context, config, amount) do
    host = config |> Map.fetch!(:base_url) |> URI.parse() |> Map.get(:host)
    SpendGate.authorize(context, amount, target: {:domain, host}, metadata: %{protocol: :relay})
  end

  # A (gasless): sign the quote's typed data before execute so the solver pulls.
  defp maybe_sign_gasless(%QuoteResponse{gasless: gasless}, context, amount)
       when is_map(gasless) do
    case Map.get(context, :wallet) do
      nil -> release_and_error(context, amount, {:missing_context, :wallet})
      wallet -> sign_gasless(gasless, wallet, context, amount)
    end
  end

  defp maybe_sign_gasless(_quote, _context, _amount), do: {:ok, nil}

  defp sign_gasless(gasless, wallet, context, amount) do
    domain = eip712_domain(gasless["domain"] || %{})
    types = eip712_types(gasless["types"] || %{})
    message = gasless["message"] || %{}

    case wallet.sign_typed_data(domain, types, message) do
      {:ok, sig} -> {:ok, "0x" <> Base.encode16(sig, case: :lower)}
      {:error, reason} -> release_and_error(context, amount, {:sign_failed, reason})
    end
  end

  defp eip712_domain(d) do
    %{
      name: d["name"],
      version: d["version"],
      chainId: d["chainId"],
      verifyingContract: d["verifyingContract"]
    }
  end

  defp eip712_types(types) do
    types
    |> Map.drop(["EIP712Domain"])
    |> Map.new(fn {name, fields} -> {name, Enum.map(fields, &{&1["name"], &1["type"]})} end)
  end

  defp execute(config, quote, signature, context, amount) do
    case Relay.execute(config, quote.transfer_id, quote.quote_id, signature: signature) do
      {:ok, status} ->
        {:ok, status}

      {:error, reason} ->
        SpendGate.release(context, amount, %{protocol: :relay, reason: :execute_failed})
        {:error, {:execute_failed, reason}}
    end
  end

  # B (broadcast): if not gasless, an injected broadcaster sends the deposit on an
  # EVM source. Runs after execute so a failure before funds move releases the
  # reservation cleanly; raxol cannot broadcast a Tron source leg.
  defp maybe_broadcast(_quote, _request, signature, _context, _amount) when is_binary(signature),
    do: {:ok, nil}

  defp maybe_broadcast(
         %QuoteResponse{deposit_address: deposit} = quote,
         request,
         _sig,
         context,
         amount
       )
       when is_binary(deposit) do
    broadcaster = Map.get(context, :broadcaster)

    if broadcaster && not Relay.Schemas.tron_chain?(request.from_chain_id),
      do: broadcast_deposit(broadcaster, quote, request, context, amount),
      else: {:ok, nil}
  end

  defp maybe_broadcast(_quote, _request, _sig, _context, _amount), do: {:ok, nil}

  defp broadcast_deposit(broadcaster, quote, request, context, amount) do
    params = %{
      transfer_id: quote.transfer_id,
      chain_id: request.from_chain_id,
      token: request.from_token,
      to: quote.deposit_address,
      amount_atomic: request.from_amount,
      wallet: Map.get(context, :wallet)
    }

    case broadcaster.send_deposit(params) do
      {:ok, tx_hash} ->
        {:ok, tx_hash}

      {:error, reason} ->
        SpendGate.release(context, amount, %{protocol: :relay, reason: :deposit_broadcast_failed})
        {:error, {:deposit_broadcast_failed, reason}}
    end
  end

  defp release_and_error(context, amount, reason) do
    SpendGate.release(context, amount, %{protocol: :relay, reason: :funding_failed})
    {:error, reason}
  end

  defp summary(quote, status, warnings, signature, deposit_tx) do
    %{
      transfer_id: quote.transfer_id,
      quote_id: quote.quote_id,
      deposit_address: quote.deposit_address,
      deposit_tx_hash: deposit_tx,
      funding: funding_mode(signature, deposit_tx),
      status: to_string(status.status),
      to_amount: quote.to_amount,
      warnings: warnings
    }
  end

  defp funding_mode(signature, _deposit_tx) when is_binary(signature), do: "gasless"
  defp funding_mode(_signature, deposit_tx) when is_binary(deposit_tx), do: "broadcast"
  defp funding_mode(_signature, _deposit_tx), do: "external"
end
