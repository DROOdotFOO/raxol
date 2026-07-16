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

  ## Idempotent recovery

  When a `:checkpoint` store is supplied, the intent is checkpointed by a stable
  idempotency key before it is submitted. If the process crashes mid-settlement
  and the Action runs again for the same logical payment, it finds the
  checkpoint and returns the in-flight intent for the caller to poll, rather than
  re-quoting and signing a second time. The spend is reserved and the signature
  released exactly once across the crash.

  Without a checkpoint store the settlement proceeds unchecked and emits
  `[:raxol, :payments, :xochi, :unchecked_settlement]` telemetry, so a crash
  between signing and confirming would re-quote and sign a second time. A
  fund-moving deployment closes that window by injecting a durable `:checkpoint`
  store (see `Raxol.Payments.Checkpoint.ContextStore`) and setting
  `require_checkpoint: true` in context (or `config :raxol_payments,
  :require_checkpoint, true`), which fails the Action closed with
  `{:error, {:checkpoint_required, _}}` before any signature when no store is
  present.

  ## Context keys

  * `:wallet` -- wallet module signing the EIP-712 intent.
  * `:xochi_config` -- `%{base_url:, auth:}` for `Xochi.Client` (e.g.
    `auth: {:mandate, agent_wallet}`; see `Xochi.Client` for all auth modes).
  * `:policy`, `:ledger`, `:agent_id`, `:on_confirm` -- see `SpendGate`.
  * `:checkpoint` -- optional `{module, handle}` `Raxol.Payments.Checkpoint`
    store for idempotent recovery (nil disables it).
  * `:require_checkpoint` -- when `true`, the Action fails closed with
    `{:error, {:checkpoint_required, _}}` unless a `:checkpoint` store is present
    (default `false`; falls back to `config :raxol_payments, :require_checkpoint`).
  * `:idempotency_key` -- optional explicit key; derived from the payment when
    absent.
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_execute_xochi_intent",
    sensitive: true,
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
        recipient_address: [
          type: :string,
          description:
            "Destination recipient for a plaintext (public) transfer. Required for a cross-VM route (e.g. an EVM wallet paying a Tron base58 address); omit for same-VM, where Xochi defaults it to the sending wallet."
        ],
        slippage_bps: [type: :integer, default: 50, description: "Max slippage (default 50)"],
        trust_score: [type: :integer, description: "Trust score for tier/fee"],
        min_to_amount: [
          type: :string,
          description:
            "Optional minimum acceptable delivery, in destination-chain atomic units. A quote delivering less is rejected before signing. Authoritative for any corridor; same-asset corridors also get an automatic floor."
        ]
      ],
      output: [
        intent_id: [type: :string],
        status: [type: :string],
        from_amount: [type: :string],
        to_amount: [type: :string],
        xochi_fee: [type: :string],
        stealth_address: [type: :string],
        reconciling: [
          type: :boolean,
          description:
            "True when the settlement is in doubt: the worker could not confirm the solver executed, so the intent stays non-terminal. Poll the intent status to resolve; do not re-execute."
        ]
      ]
    ]

  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.{Assets, Checkpoint, Failure, Router}
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse}
  alias Raxol.Payments.Xochi.{Stealth, SwapAnnouncer}

  @spec run(map(), map()) :: {:ok, map()} | {:error, Failure.t()}
  @impl true
  def run(params, context) do
    with {:ok, wallet} <- fetch(context, :wallet),
         {:ok, config} <- fetch(context, :xochi_config),
         {:ok, request, amount} <- build_request(params, wallet),
         {:ok, store} <- resolve_checkpoint(context, request) do
      key = idempotency_key(context, request)

      case Checkpoint.fetch(store, key) do
        # Poll-before-re-sign: this payment is already in flight from an earlier
        # run that crashed before confirming. Return the recorded intent without
        # reserving budget or signing again.
        {:ok, record} -> {:ok, resume_summary(record)}
        :error -> settle(config, wallet, request, amount, params, context, store, key)
      end
    end
    |> normalize_error()
  end

  defp normalize_error({:ok, _result} = ok), do: ok
  defp normalize_error({:error, reason}), do: {:error, Failure.from(reason)}

  defp settle(config, wallet, request, amount, params, context, store, key) do
    with :ok <- assert_xochi_route(params),
         {:ok, quote} <- solvable_quote(config, request),
         :ok <- assert_method(quote, request),
         :ok <- assert_delivery_floor(request, quote, params),
         :ok <- authorize(context, config, amount),
         {:ok, exec, filled_quote} <-
           execute(config, request, quote, wallet, context, amount, store, key),
         :ok <- assert_settlement_privacy(request, exec) do
      summary = summary(request, filled_quote, exec)
      # Best-effort, non-blocking: emit a signed activity row to the user's live
      # feed (and stash the route for the terminal announce). Never affects the
      # swap; a no-op unless a capability topic_id is configured.
      SwapAnnouncer.announce_execute(context, request, filled_quote, exec)
      Checkpoint.put(store, key, settled_record(summary))
      {:ok, summary}
    end
  end

  # An in-doubt (reconciling) settlement has not landed yet: the worker could not
  # confirm the solver executed (typically an upstream Riddler 5xx/timeout wrapped
  # as a 200) and kept the intent non-terminal. No stealth address exists yet --
  # it appears only once the intent resolves to completed via polling -- so the
  # stealth-address guard below must not fire. The in-doubt state is surfaced to
  # the caller via the summary's `reconciling` flag instead.
  defp assert_settlement_privacy(_request, %{reconciling: true}), do: :ok

  # A stealth settlement must come back with the stealth address the worker
  # derived and announced. A nil there means the funds did not land on a stealth
  # address -- a server fallback to public, or a hostile endpoint -- so the
  # privacy the caller asked for was not delivered. Fail closed rather than
  # report success; the intent id rides the error so an operator can verify it.
  #
  # Public and shielded settlements legitimately have no stealth address: shielded
  # is note-based (note_commitment / nullifier_hash), surfaced at terminal status,
  # not an announced stealth address.
  defp assert_settlement_privacy(%QuoteRequest{settlement_preference: "stealth"}, %{
         stealth_address: address,
         intent_id: intent_id
       }) do
    if is_binary(address) and address != "",
      do: :ok,
      else: {:error, {:stealth_address_missing, intent_id}}
  end

  defp assert_settlement_privacy(_request, _exec), do: :ok

  # Resolve the idempotency store that lets a resumed settlement poll the
  # in-flight intent instead of signing a second time. An explicit `:checkpoint`
  # store in context wins. With none, a fund-moving deployment sets
  # `require_checkpoint: true` (context) or `config :raxol_payments,
  # :require_checkpoint, true`, so a missing store fails closed BEFORE any
  # signature. Otherwise the settlement proceeds unchecked and emits telemetry,
  # so the double-settle exposure on a crash-retry is observable, never silent.
  defp resolve_checkpoint(context, request) do
    case Map.get(context, :checkpoint) do
      {module, _handle} = store when is_atom(module) ->
        {:ok, store}

      _ ->
        if require_checkpoint?(context) do
          {:error, {:checkpoint_required, :no_idempotency_store}}
        else
          emit_unchecked_settlement(request)
          {:ok, nil}
        end
    end
  end

  # Fail closed by default in a deployed release: a real settlement with no
  # durable checkpoint risks a double-settle on a crash-retry. An explicit
  # context flag or `config :raxol_payments, :require_checkpoint` overrides;
  # development and tests stay permissive.
  defp require_checkpoint?(context) do
    case Map.get(context, :require_checkpoint) do
      flag when is_boolean(flag) ->
        flag

      _ ->
        Application.get_env(
          :raxol_payments,
          :require_checkpoint,
          Raxol.Payments.Deployment.production?()
        )
    end
  end

  defp emit_unchecked_settlement(%QuoteRequest{} = request) do
    :telemetry.execute(
      [:raxol, :payments, :xochi, :unchecked_settlement],
      %{},
      %{
        wallet: request.wallet,
        from_chain_id: request.from_chain_id,
        to_chain_id: request.to_chain_id
      }
    )
  end

  # An explicit key lets a caller treat two otherwise-identical payments as
  # distinct; otherwise the key is the canonical payment, so a resumed run of the
  # same payment recognizes it.
  defp idempotency_key(context, %QuoteRequest{} = request) do
    case Map.get(context, :idempotency_key) do
      key when is_binary(key) ->
        key

      _ ->
        Checkpoint.derive_key([
          :xochi,
          request.wallet,
          request.from_chain_id,
          request.to_chain_id,
          request.from_token,
          request.to_token,
          request.from_amount,
          # The recipient is part of the payment's identity: a transfer to
          # recipient A must never be treated as a resume of one to recipient B.
          request.recipient_address,
          request.settlement_preference,
          request.stealth_spending_pub_key,
          request.stealth_viewing_pub_key
        ])
    end
  end

  # A resume returns the full summary once execution recorded it. If the crash
  # landed between the pre-submit checkpoint and that record, only the dispatched
  # intent is known; return it so the caller polls the existing intent.
  defp resume_summary(%{summary: summary}) when is_map(summary), do: summary

  defp resume_summary(record) do
    %{intent_id: record.intent_id, status: to_string(Map.get(record, :status, :dispatched))}
  end

  defp dispatched_record(%QuoteResponse{} = quote) do
    %{intent_id: quote.intent_id, quote_id: quote.quote_id, status: :dispatched}
  end

  defp settled_record(summary) do
    %{intent_id: summary.intent_id, status: :in_flight, summary: summary}
  end

  # Guard the server's method choice before signing: ERC-3009 is USDC-only (it
  # signs against the USDC contract as the EIP-712 verifying contract), so an
  # ERC-3009 quote for a non-USDC token would be a silently invalid signature.
  defp assert_method(%QuoteResponse{payment_method: "erc3009"}, %QuoteRequest{
         from_chain_id: chain,
         from_token: token
       }) do
    if Assets.usdc?(chain, token),
      do: :ok,
      else: {:error, {:method_mismatch, :erc3009_requires_usdc}}
  end

  defp assert_method(_quote, _request), do: :ok

  # Reject a quote that delivers far less than the agent sends, before any
  # signature. The spend gate sees only the human `amount` that leaves the wallet,
  # not the served `to_amount` that arrives; the origin-pull value cap bounds the
  # amount out, not the ratio in. So a hostile or compromised quote endpoint could
  # serve a punitive `to_amount` (deliver ~0 while pulling the full origin amount)
  # and the gate would not catch it.
  #
  # An explicit `min_to_amount` (destination atomic units) is authoritative for
  # any corridor. Without one, a same-asset corridor (same token symbol both
  # sides) gets an automatic floor: delivery must be at least `:min_delivery_bps`
  # of par (default 8000 = 80%). This is a theft backstop, not a pricing check --
  # Xochi enforces pricing; legitimate fees and slippage stay well inside 80%. A
  # cross-asset corridor has no on-client price, so it is bound only by an explicit
  # `min_to_amount`.
  defp assert_delivery_floor(%QuoteRequest{} = request, %QuoteResponse{} = quote, params) do
    case delivery_floor(request, params) do
      :none ->
        :ok

      {:floor, min_out} ->
        case parse_uint(quote.to_amount) do
          delivered when is_integer(delivered) and delivered >= min_out ->
            :ok

          _ ->
            {:error,
             {:delivery_below_floor, %{to_amount: quote.to_amount, min_to_amount: min_out}}}
        end
    end
  end

  defp delivery_floor(%QuoteRequest{} = request, params) do
    case parse_uint(Map.get(params, :min_to_amount)) do
      n when is_integer(n) -> {:floor, n}
      nil -> same_asset_floor(request)
    end
  end

  defp same_asset_floor(%QuoteRequest{} = request) do
    from_symbol = Assets.symbol_for(request.from_chain_id, request.from_token)
    to_symbol = Assets.symbol_for(request.to_chain_id, request.to_token)

    if not is_nil(from_symbol) and from_symbol == to_symbol do
      from_decimals = Assets.decimals(request.from_chain_id, request.from_token)
      to_decimals = Assets.decimals(request.to_chain_id, request.to_token)
      par_out = Assets.to_atomic(Assets.to_human(request.from_amount, from_decimals), to_decimals)
      bps = Application.get_env(:raxol_payments, :min_delivery_bps, 8000)
      {:floor, div(par_out * bps, 10_000)}
    else
      :none
    end
  end

  defp parse_uint(v) when is_integer(v) and v >= 0, do: v

  defp parse_uint(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_uint(_), do: nil

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
        recipient_address: Map.get(params, :recipient_address),
        settlement_preference: settlement,
        slippage_bps: Map.get(params, :slippage_bps) || 50,
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
  #
  # The dispatched intent is checkpointed before submit so that a crash during
  # submit leaves a record a resumed run can poll instead of re-signing.
  defp execute(config, request, quote, wallet, context, amount, store, key) do
    Checkpoint.put(store, key, dispatched_record(quote))

    case Xochi.execute(config, quote, wallet, request) do
      {:ok, exec} ->
        tag_dispatch(context, exec, amount)
        {:ok, exec, quote}

      {:error, reason} ->
        if quote_expired?(reason),
          do: retry_execute(config, request, wallet, context, amount, store, key),
          else: release_and_clear(context, amount, reason, store, key)
    end
  end

  defp retry_execute(config, request, wallet, context, amount, store, key) do
    case solvable_quote(config, request) do
      {:ok, quote} ->
        Checkpoint.put(store, key, dispatched_record(quote))

        case Xochi.execute(config, quote, wallet, request) do
          {:ok, exec} ->
            tag_dispatch(context, exec, amount)
            {:ok, exec, quote}

          {:error, reason} ->
            release_and_clear(context, amount, reason, store, key)
        end

      {:error, reason} ->
        release_and_clear(context, amount, reason, store, key)
    end
  end

  # A definite execute failure means nothing dispatched: refund the reservation
  # and drop the checkpoint so a later retry of the same payment starts clean.
  defp release_and_clear(context, amount, reason, store, key) do
    SpendGate.release(context, amount, %{protocol: :xochi, reason: :execute_failed})
    Checkpoint.delete(store, key)
    {:error, {:execute_failed, reason}}
  end

  # The intent dispatched: bind the reserved amount to its id so a later refund
  # (observed by PollXochiStatus) releases exactly this reservation, idempotently.
  defp tag_dispatch(context, %{intent_id: intent_id}, amount) when is_binary(intent_id),
    do: SpendGate.tag_reservation(context, intent_id, amount)

  defp tag_dispatch(_context, _exec, _amount), do: :ok

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
      stealth_address: exec.stealth_address,
      # Surface the in-doubt state rather than reporting a clean success: an
      # execute the worker could not confirm (often a wrapped upstream 5xx) is
      # not a completed payment. Poll the intent status to resolve.
      reconciling: exec.reconciling
    }
  end
end
