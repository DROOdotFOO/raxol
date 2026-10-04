defmodule Raxol.Payments.Protocols.Xochi do
  @moduledoc """
  Xochi private execution protocol.

  Xochi is the default agent-facing protocol for cross-chain transfers.
  It routes intents through the Xochi dark pool where Riddler (and other
  solvers) compete to fill them. This is the cash-positive path with
  tier-based fees.

  Unlike x402/MPP, Xochi is not a 402-triggered protocol. It uses an
  explicit quote -> sign -> execute -> poll flow.

  ## Usage

      config = %{base_url: "https://api.xochi.fi", auth: {:member, "..."}}
      wallet = MyWallet

      {:ok, quote} = Xochi.get_quote(config, request)
      {:ok, exec} = Xochi.execute(config, quote, wallet, request)
      {:ok, status} = Xochi.poll_status(config, exec.intent_id)

  ## Fee Tiers

  The fee is layered: a solver spread plus gas floor (never discounted), a venue
  fee, and a routing fee. Trust discounts carve the venue and routing layers only,
  so the solver floor is identical at every tier. Headline totals by tier and asset:

  | Tier           | Score | Stable | Volatile |
  |----------------|-------|--------|----------|
  | Standard       | 0-24  | 0.22%  | 0.40%    |
  | Trusted        | 25-49 | 0.19%  | 0.35%    |
  | Verified       | 50-74 | 0.15%  | 0.29%    |
  | Premium        | 75-99 | 0.12%  | 0.25%    |
  | Institutional  | 100+  | 0.10%  | 0.22%    |

  A quote will carry an optional `fee_breakdown` with the per-layer split (solver,
  venue, routing) once the worker emits it; `QuoteResponse` does not parse it yet.

  ## Origin-pull solver allowlist

  The origin pull authorizes the solver to collect funds from the agent wallet.
  The pull recipient/spender is the solver's collection address; by default it is
  not pinned (solver addresses rotate and there is no client-facing manifest). An
  operator who knows their solver set can pin it:

      config :raxol_payments, :pull_solver_allowlist, ["0xsolver...", "0xsolver2..."]

  When set, a pull whose `to` (ERC-3009) or `spender` (Permit2) is not in the list
  is rejected before any signature. When unset (the default), the address is not
  bound. See GitHub #333.
  """

  @behaviour Raxol.Payments.Protocol

  alias Raxol.Payments.Poll
  alias Raxol.Payments.Protocols.Permit2
  alias Raxol.Payments.Xochi.{Capabilities, Client, DepositAttestation}

  alias Raxol.Payments.Xochi.Schemas.{
    DepositRouteRequest,
    ExecuteRequest,
    Intent,
    IntentStatus,
    QuoteRequest,
    QuoteResponse
  }

  # -- Protocol behaviour (stubs -- Xochi is not a 402 protocol) --

  @impl true
  @spec name() :: String.t()
  def name, do: "Xochi"

  @impl true
  @spec detect?(integer(), [{String.t(), String.t()}]) :: boolean()
  def detect?(_status, _headers), do: false

  @impl true
  @spec parse_challenge([{String.t(), String.t()}]) ::
          {:error, :not_a_402_protocol}
  def parse_challenge(_headers), do: {:error, :not_a_402_protocol}

  @impl true
  @spec build_payment(map(), module()) :: {:error, :not_a_402_protocol}
  def build_payment(_challenge, _wallet), do: {:error, :not_a_402_protocol}

  @impl true
  @spec parse_receipt([{String.t(), String.t()}]) ::
          {:error, :not_a_402_protocol}
  def parse_receipt(_headers), do: {:error, :not_a_402_protocol}

  @impl true
  @spec amount(map()) :: Decimal.t()
  def amount(%{to_amount: amt}) when is_binary(amt), do: Decimal.new(amt)
  def amount(%{xochi_fee: fee}) when is_binary(fee), do: Decimal.new(fee)
  def amount(_challenge), do: Decimal.new(0)

  # -- Direct API --

  @doc """
  Request a cross-chain intent quote from Xochi.
  """
  @spec get_quote(Client.config(), QuoteRequest.t()) ::
          {:ok, QuoteResponse.t()} | {:error, term()}
  def get_quote(config, %QuoteRequest{} = request) do
    Client.get_quote(config, request)
  end

  @doc """
  Fetch a persisted intent by id (`GET /api/intent/:id`).

  Returns the authoritative corridor + amounts written at quote time, so a
  storefront can read what the buyer signed before settlement rather than trust
  a relayed, buyer-declared amount.
  """
  @spec get_intent(Client.config(), String.t()) :: {:ok, Intent.t()} | {:error, term()}
  def get_intent(config, intent_id) when is_binary(intent_id) do
    Client.get_intent(config, intent_id)
  end

  @doc """
  Fetch a deposit-route quote and verify its `deposit_attestation` before
  returning the deposit instructions -- the authenticated form of a Tron-origin
  quote.

  A non-EVM origin has no gasless pull, so the quote returns a bare
  `deposit_address` the payer must fund directly. A MITM or compromised endpoint
  could swap that address, so raxol verifies the attestation recovers to the
  pinned signer BEFORE surfacing the address, failing closed when no signer is
  pinned or the attestation does not verify. raxol never sends the funds; the
  returned instructions are for the caller's own Tron wallet to fund, then poll
  with `poll_status/3`.

  Signer resolution, in precedence order: `opts[:deposit_attestation_signer]`
  (an operator's out-of-band pin), else `config :raxol_payments,
  :xochi_deposit_attestation_signer`, else the live capability matrix's
  `deposit_attestation_signer`.

  ## Options

    * `:deposit_attestation_signer` -- pin the expected signer explicitly.
    * `:capabilities` -- a pre-fetched `Capabilities.t()` (skips the network).
  """
  @spec deposit_route_quote(Client.config(), DepositRouteRequest.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def deposit_route_quote(config, %DepositRouteRequest{} = request, opts \\ []) do
    with {:ok, quote} <- Client.get_deposit_route_quote(config, request),
         :ok <- ensure_solvable(quote) do
      verify_deposit_route(config, request, quote, opts)
    end
  end

  @doc """
  Verify a deposit-route quote's attestation against the pinned signer and return
  the deposit instructions, or a fail-closed error. See `deposit_route_quote/3`
  for signer resolution.
  """
  @spec verify_deposit_route(
          Client.config(),
          DepositRouteRequest.t(),
          QuoteResponse.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def verify_deposit_route(
        config,
        %DepositRouteRequest{} = request,
        %QuoteResponse{} = quote,
        opts \\ []
      ) do
    with :ok <- ensure_deposit_route(quote),
         {:ok, signer} <- resolve_deposit_signer(config, opts),
         :ok <-
           DepositAttestation.verify(
             deposit_binding_fields(request, quote),
             quote.deposit_attestation,
             signer
           ) do
      {:ok, deposit_instructions(request, quote)}
    end
  end

  defp ensure_solvable(%QuoteResponse{can_solve: true}), do: :ok

  defp ensure_solvable(%QuoteResponse{error: reason}),
    do: {:error, {:not_solvable, reason}}

  defp ensure_deposit_route(%QuoteResponse{} = quote) do
    if QuoteResponse.deposit_route?(quote),
      do: :ok,
      else: {:error, :not_a_deposit_route}
  end

  # Pin the expected signer, failing closed when none is available -- a bare
  # deposit address with nothing to authenticate it against must not be trusted.
  defp resolve_deposit_signer(config, opts) do
    signer =
      opts[:deposit_attestation_signer] ||
        Application.get_env(:raxol_payments, :xochi_deposit_attestation_signer) ||
        Capabilities.deposit_attestation_signer(deposit_capabilities(config, opts))

    case signer do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, :deposit_signer_unavailable}
    end
  end

  defp deposit_capabilities(config, opts) do
    case Keyword.get(opts, :capabilities) do
      %{} = caps -> caps
      _ -> Capabilities.get(config)
    end
  end

  # The attestation binds fields split across the request (origin) and the quote
  # response (ids + deposit address); reassemble them for recovery.
  defp deposit_binding_fields(
         %DepositRouteRequest{} = request,
         %QuoteResponse{} = quote
       ) do
    %{
      intent_id: quote.intent_id,
      quote_id: quote.quote_id,
      from_chain_id: request.from_chain_id,
      from_token: request.from_token,
      from_amount: request.from_amount,
      deposit_address: quote.deposit_address
    }
  end

  defp deposit_instructions(
         %DepositRouteRequest{} = request,
         %QuoteResponse{} = quote
       ) do
    %{
      intent_id: quote.intent_id,
      quote_id: quote.quote_id,
      deposit_address: quote.deposit_address,
      deposit_deadline: quote.deposit_deadline,
      from_chain_id: request.from_chain_id,
      from_token: request.from_token,
      from_amount: request.from_amount,
      to_chain_id: request.to_chain_id,
      to_token: request.to_token,
      recipient_address: request.recipient_address,
      to_amount: quote.to_amount,
      min_to_amount: quote.min_to_amount,
      expires_at: quote.expiry
    }
  end

  @doc """
  Sign and execute an intent from a quote.

  Binds the served EIP-712 intent (`validate_intent/2`) and any origin-pull
  authorization (`validate_pull/3`) to the caller's intended transfer
  (`request`) before signing either, then submits the signed intent.

  The agent signs typed data the quote endpoint serves; a hostile or
  compromised endpoint could otherwise serve an intent that pays a different
  recipient, token, or chain, or a pull that drains the wallet. Nothing is
  signed unless both match the request.
  """
  @spec execute(Client.config(), QuoteResponse.t(), module(), QuoteRequest.t()) ::
          {:ok, Raxol.Payments.Xochi.Schemas.ExecuteResponse.t()}
          | {:error, term()}
  def execute(config, %QuoteResponse{} = quote_resp, wallet, %QuoteRequest{} = request) do
    with {:ok, bundle} <- sign_intent(quote_resp, wallet, request) do
      execute_signed(config, bundle)
    end
  end

  @doc """
  Sign a quoted intent into a relayable bundle WITHOUT executing it.

  The buyer-side counterpart to `execute_signed/2`: validates the quote, binds
  the served intent and origin pull to `request` (see `execute/4`), signs the
  EIP-712 intent with `wallet`, and returns the opaque bundle
  `%{intent_id, quote_id, signature, nonce}` (plus `pull_signature` when the
  quote carried an origin-pull authorization) to hand to a storefront/relay or
  to `execute_signed/2` directly. Does not talk to the worker.
  """
  @spec sign_intent(QuoteResponse.t(), module(), QuoteRequest.t()) ::
          {:ok, signed_intent()} | {:error, term()}
  def sign_intent(%QuoteResponse{} = quote_resp, wallet, %QuoteRequest{} = request) do
    with :ok <- validate_quote(quote_resp),
         :ok <- validate_intent(quote_resp, request),
         :ok <- validate_pull_authorization(quote_resp, request, wallet),
         {:ok, signature} <- sign_quote(quote_resp, wallet),
         {:ok, pull_signature} <- sign_pull_authorization(quote_resp, wallet) do
      {:ok, build_signed_intent(quote_resp, signature, pull_signature)}
    end
  end

  @doc """
  Buyer-side one-shot: `get_quote/2` then `sign_intent/3`.

  Fetches a quote for `request` and signs it into a relayable bundle. The buyer
  hands the bundle to a storefront (e.g. as an ACP requirement's `signed_intent`)
  which relays it via `execute_signed/2`; the storefront never re-signs.
  """
  @spec quote_and_sign(Client.config(), QuoteRequest.t(), module()) ::
          {:ok, signed_intent()} | {:error, term()}
  def quote_and_sign(config, %QuoteRequest{} = request, wallet) do
    with {:ok, quote_resp} <- get_quote(config, request) do
      sign_intent(quote_resp, wallet, request)
    end
  end

  @typedoc """
  A buyer's pre-signed Xochi intent bundle, as handed to the storefront relay.

  Keys may be atoms (internal callers) or strings (decoded from an ACP
  requirement). Required: `intent_id`, `quote_id`, `signature`, `nonce`.
  Optional: `pull_signature` (nil for non-pulling methods), `aztec_proof`
  (shielded claims).
  """
  @type signed_intent :: %{optional(atom() | String.t()) => term()}

  @doc """
  Relay a buyer's pre-signed intent to Xochi WITHOUT re-signing.

  The storefront (pure-relay) primitive. The buyer quoted and signed the EIP-712
  intent (and any origin-pull authorization) against Xochi itself, then handed
  raxol the opaque bundle `{intent_id, quote_id, signature, nonce,
  pull_signature}`. raxol posts it verbatim; Riddler verifies the signature
  against its own server-persisted quote, so neither raxol nor the buyer can
  forge the amount or route.

  Unlike `execute/3,4`, this takes no wallet and releases no signature -- raxol
  is never on the fund-signing path. Fails closed with
  `{:error, {:invalid_signed_intent, field}}` on a missing or malformed field,
  before any network call.
  """
  @spec execute_signed(Client.config(), signed_intent()) ::
          {:ok, Raxol.Payments.Xochi.Schemas.ExecuteResponse.t()}
          | {:error, term()}
  def execute_signed(config, signed_intent) when is_map(signed_intent) do
    with {:ok, exec_request} <- build_signed_execute_request(signed_intent) do
      Client.execute(config, exec_request)
    end
  end

  @doc """
  Poll intent status until terminal (completed/failed/expired) or timeout.

  Fast-polls inside the settlement budget window, then backs off. See
  `Raxol.Payments.Poll` for the timing options (`:budget_ms`,
  `:fast_interval_ms`, `:slow_interval_ms`, `:timeout_ms`).
  """
  @spec poll_status(Client.config(), String.t(), keyword()) ::
          {:ok, IntentStatus.t()} | {:error, term()}
  def poll_status(config, intent_id, opts \\ []) do
    case poll_status_timed(config, intent_id, opts) do
      {:ok, status, _elapsed_ms} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `poll_status/3` but also returns the elapsed milliseconds to the terminal
  status, so the caller can report whether settlement landed within budget.
  """
  @spec poll_status_timed(Client.config(), String.t(), keyword()) ::
          {:ok, IntentStatus.t(), non_neg_integer()} | {:error, term()}
  def poll_status_timed(config, intent_id, opts \\ []) do
    Poll.run(
      fn -> Client.get_status(config, intent_id) end,
      &IntentStatus.terminal?/1,
      opts
    )
  end

  @doc """
  Full transfer flow: quote -> sign -> execute -> poll.

  Convenience function that runs the complete Xochi intent lifecycle.
  Returns the final terminal status.
  """
  @spec transfer(Client.config(), QuoteRequest.t(), module(), keyword()) ::
          {:ok, IntentStatus.t()} | {:error, term()}
  def transfer(config, %QuoteRequest{} = request, wallet, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with {:ok, quote_resp} <- get_quote(config, request),
         {:ok, exec_resp} <- execute(config, quote_resp, wallet, request),
         {:ok, status} <- poll_status(config, exec_resp.intent_id, opts) do
      emit_settled(
        request,
        quote_resp,
        status,
        System.monotonic_time(:millisecond) - started
      )

      {:ok, status}
    end
  end

  # Emit a settlement-completion event carrying the quote fee + delivered amount +
  # destination tx, so accounting can book the fill's P&L without threading a ledger
  # through the protocol. Only on a completed terminal status. See
  # `Raxol.Payments.Telemetry` and `Raxol.Payments.SettlementAccountant`.
  defp emit_settled(
         request,
         quote_resp,
         %IntentStatus{status: :completed} = status,
         elapsed_ms
       ) do
    :telemetry.execute(
      [:raxol, :payments, :xochi, :settled],
      %{elapsed_ms: elapsed_ms},
      %{
        intent_id: status.intent_id,
        from_chain_id: request.from_chain_id,
        to_chain_id: request.to_chain_id,
        from_token: request.from_token,
        to_token: request.to_token,
        from_amount: intent_from_amount(quote_resp),
        to_amount: quote_resp.to_amount,
        xochi_fee: quote_resp.xochi_fee,
        tx_hash: status.tx_hash,
        settlement_type: status.settlement_type
      }
    )
  end

  defp emit_settled(_request, _quote_resp, _status, _elapsed_ms), do: :ok

  @intent_primary_type "XochiIntent"
  @intent_bound_fields MapSet.new(
                         ~w(wallet recipient fromChainId toChainId fromToken toToken fromAmount toAmount settlementPreference deadline)
                       )
  # Riddler issues quotes valid for ~300s; an hour of headroom tolerates a slow
  # local clock. A fast clock fails open -- the wall clock is the one value on
  # this path the server does not supply. Matches riddler-sdk's
  # MAX_INTENT_DEADLINE_AHEAD_OF_NOW_SECONDS.
  @intent_max_deadline_ahead_seconds 3600

  @doc """
  Bind the served EIP-712 intent to the caller's request WITHOUT signing -- the
  check `sign_intent/3` runs before it signs.

  The intent is what Riddler settles, so its signed values -- not the quote's
  top-level fields -- are compared: `wallet`, `fromChainId`/`toChainId`,
  `fromToken`/`toToken`, `recipient` (the request's `recipient_address`, else
  `wallet`, as Riddler defaults it), `settlementPreference`, a `deadline` no
  more than an hour ahead of the wall clock, and the signed `toAmount` against
  the quote's own `to_amount`. On `exact_input` the signed `fromAmount` must
  equal the request's `from_amount`; on `exact_output` the signed `toAmount`
  must equal `output_amount` and `fromAmount` must not exceed `max_from_amount`,
  which is required. The primary type must be `XochiIntent` and declare each of
  those fields, so every compared value is one the signature covers.

  Returns `:ok` or `{:error, {:intent_mismatch, field}}` naming the first field
  that does not match. Mirrors riddler-sdk's `assertIntentMatchesRequest`.
  """
  @spec validate_intent(QuoteResponse.t(), QuoteRequest.t()) :: :ok | {:error, term()}
  def validate_intent(%QuoteResponse{eip712_data: nil}, %QuoteRequest{}),
    do: {:error, :no_eip712_data}

  def validate_intent(%QuoteResponse{eip712_data: eip712}, %QuoteRequest{})
      when not is_map(eip712),
      do: {:error, {:intent_mismatch, :intent_type}}

  def validate_intent(%QuoteResponse{eip712_data: eip712} = quote_resp, %QuoteRequest{} = request) do
    message = intent_message(eip712)

    intent_mismatch(
      Enum.concat([
        [{:intent_type, intent_envelope?(eip712)}],
        route_checks(message, request),
        [
          {:deadline, deadline_bounded?(message["deadline"])},
          {:quoted_to_amount, int_match?(message["toAmount"], quote_resp.to_amount)}
        ],
        amount_checks(message, request)
      ])
    )
  end

  @doc """
  The origin amount the served intent signs (`fromAmount`), as a string, or nil
  when the quote carries none. After `validate_intent/2` it equals the request's
  `from_amount` on `exact_input` and is the solver-chosen amount, at most
  `max_from_amount`, on `exact_output`.
  """
  @spec intent_from_amount(QuoteResponse.t()) :: String.t() | nil
  def intent_from_amount(%QuoteResponse{eip712_data: %{"message" => %{} = message}}) do
    case to_uint(message["fromAmount"]) do
      n when is_integer(n) -> Integer.to_string(n)
      nil -> nil
    end
  end

  def intent_from_amount(%QuoteResponse{}), do: nil

  defp intent_message(eip712) do
    case eip712["message"] do
      %{} = message -> message
      _ -> %{}
    end
  end

  # Who pays whom, on which chains and tokens, settled how.
  defp route_checks(message, %QuoteRequest{} = request) do
    [
      {:wallet, addressish_match?(message["wallet"], request.wallet)},
      {:from_chain_id, int_match?(message["fromChainId"], request.from_chain_id)},
      {:to_chain_id, int_match?(message["toChainId"], request.to_chain_id)},
      {:from_token, addressish_match?(message["fromToken"], request.from_token)},
      {:to_token, addressish_match?(message["toToken"], request.to_token)},
      {:recipient,
       addressish_match?(message["recipient"], request.recipient_address || request.wallet)},
      {:settlement_preference,
       message["settlementPreference"] == (request.settlement_preference || "public")}
    ]
  end

  # `swap_kind` decides which amount the caller chose. Comparing the
  # server-derived one for equality would reject every honest quote; on
  # `exact_output` it is what leaves the wallet, so it gets the ceiling instead.
  defp amount_checks(message, %QuoteRequest{swap_kind: "exact_output"} = request) do
    [
      {:to_amount, int_match?(message["toAmount"], request.output_amount)},
      {:max_from_amount, is_integer(to_uint(request.max_from_amount))},
      {:from_amount, int_within?(message["fromAmount"], request.max_from_amount)}
    ]
  end

  defp amount_checks(message, %QuoteRequest{swap_kind: "exact_input"} = request),
    do: [{:from_amount, int_match?(message["fromAmount"], request.from_amount)}]

  defp amount_checks(_message, %QuoteRequest{}), do: [{:swap_kind, false}]

  defp intent_envelope?(eip712) do
    eip712["primaryType"] == @intent_primary_type and
      MapSet.subset?(@intent_bound_fields, type_field_names(eip712, @intent_primary_type))
  end

  # No lower bound: a lapsed deadline is the server's to reject.
  defp deadline_bounded?(value) do
    case to_uint(value) do
      t when is_integer(t) ->
        t <= System.system_time(:second) + @intent_max_deadline_ahead_seconds

      nil ->
        false
    end
  end

  defp intent_mismatch(checks) do
    case Enum.find(checks, fn {_field, ok?} -> not ok? end) do
      nil -> :ok
      {field, _} -> {:error, {:intent_mismatch, field}}
    end
  end

  # Riddler signs an EVM (0x-hex) wallet, token, or recipient lowercased and a
  # base58 (TVM/SVM) one verbatim, since base58 is case-sensitive.
  defp addressish_match?(a, b) when is_binary(a) and is_binary(b) and a != "",
    do: addressish(a) == addressish(b)

  defp addressish_match?(_, _), do: false

  defp addressish(<<prefix::binary-size(2), _::binary>> = value) when prefix in ["0x", "0X"],
    do: String.downcase(value)

  defp addressish(value), do: value

  @doc """
  Validate the served origin-pull authorization against the intended transfer
  WITHOUT signing or executing -- the read-only counterpart of the check
  `execute/4` runs before it signs.

  Returns `:ok` when the quote's `pull_authorization` binds to `request` (signer,
  token, chain, value, envelope type, expiry) and its `to`/`spender` satisfies the
  configured solver pin, or `{:error, {:authorization_mismatch, field}}` otherwise.
  A quote with no pull authorization is `:ok` -- there is nothing to pull. Lets a
  preflight reject a forged or rotated-solver quote across every corridor before
  any funded run, with no funds moved.
  """
  @spec validate_pull(QuoteResponse.t(), QuoteRequest.t(), module()) ::
          :ok | {:error, term()}
  def validate_pull(
        %QuoteResponse{} = quote_resp,
        %QuoteRequest{} = request,
        wallet
      ) do
    validate_pull_authorization(quote_resp, request, wallet)
  end

  @doc """
  True when the origin-pull solver pin would let an unverified recipient through:
  an empty allowlist with the pin not required. In that state `validate_pull`
  accepts any ERC-3009 `to` (Permit2 stays fail-closed regardless). The boot-time
  `assert_origin_pull_pinned!/2` uses this to refuse a fail-open prod start.
  """
  @spec origin_pull_fail_open?([String.t()] | nil, boolean()) :: boolean()
  def origin_pull_fail_open?(allowlist, require_pin?) do
    normalize_solver_list(allowlist) == [] and require_pin? != true
  end

  @doc """
  Raise when the origin-pull solver pin is fail-open for the given allowlist and
  requirement flag, otherwise return `:ok`. Call at boot in a fund-moving
  deployment so a missing solver pin halts startup instead of silently signing
  ERC-3009 pulls to an unverified recipient. See GitHub #333.
  """
  @spec assert_origin_pull_pinned!([String.t()] | nil, boolean()) :: :ok
  def assert_origin_pull_pinned!(allowlist, require_pin?) do
    if origin_pull_fail_open?(allowlist, require_pin?) do
      raise ArgumentError,
            "Xochi origin-pull solver pin is not configured (fail-open): the agent " <>
              "would sign ERC-3009 origin-pull authorizations to an unverified recipient. " <>
              "Set XOCHI_SOLVER_BASE / XOCHI_SOLVER_ARBITRUM / XOCHI_SOLVER_OPTIMISM / " <>
              "XOCHI_SOLVER_ETH / XOCHI_SOLVER_POLYGON / XOCHI_SOLVER_ROBINHOOD to the " <>
              "canonical solver address(es), or set XOCHI_PULL_REQUIRE_SOLVER_PIN=true. " <>
              "See GitHub #333."
    end

    :ok
  end

  # -- Private --

  # Assemble the relayable bundle from a signed quote. `nonce` is the worker's
  # replay-dedup key derived from the quote (see `signed_nonce/1`); the pull
  # signature key is present only when the quote carried an origin pull, so a
  # non-pulling bundle serializes without a null `pull_signature`.
  defp build_signed_intent(quote_resp, signature, pull_signature) do
    %{
      intent_id: quote_resp.intent_id,
      quote_id: quote_resp.quote_id,
      signature: signature,
      nonce: signed_nonce(quote_resp)
    }
    |> put_pull_signature(pull_signature)
  end

  defp put_pull_signature(bundle, nil), do: bundle

  defp put_pull_signature(bundle, sig),
    do: Map.put(bundle, :pull_signature, sig)

  # Build an ExecuteRequest from a buyer-supplied bundle without signing. Fails
  # closed on a missing/malformed field so a bad relay never reaches the worker
  # (and never crashes on ExecuteRequest's enforced keys). Keys may be atoms or
  # strings; `nonce` must be a non-negative integer (the worker's replay-dedup
  # key), not a coerced string.
  defp build_signed_execute_request(signed) do
    with {:ok, intent_id} <- require_binary(signed, :intent_id),
         {:ok, quote_id} <- require_binary(signed, :quote_id),
         {:ok, signature} <- require_binary(signed, :signature),
         {:ok, nonce} <- require_nonce(signed),
         {:ok, pull_signature} <- optional_binary(signed, :pull_signature),
         {:ok, aztec_proof} <- optional_binary(signed, :aztec_proof) do
      {:ok,
       %ExecuteRequest{
         intent_id: intent_id,
         quote_id: quote_id,
         signature: signature,
         nonce: nonce,
         pull_signature: pull_signature,
         aztec_proof: aztec_proof
       }}
    end
  end

  # A field present under either its atom or its string key.
  defp fetch_field(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(field))
    end
  end

  defp require_binary(map, field) do
    case fetch_field(map, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_signed_intent, field}}
    end
  end

  defp require_nonce(map) do
    case fetch_field(map, :nonce) do
      {:ok, nonce} when is_integer(nonce) and nonce >= 0 -> {:ok, nonce}
      _ -> {:error, {:invalid_signed_intent, :nonce}}
    end
  end

  defp optional_binary(map, field) do
    case fetch_field(map, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_signed_intent, field}}
    end
  end

  defp validate_quote(%QuoteResponse{can_solve: false, error: err}) do
    {:error, {:cannot_solve, err || "no solver available"}}
  end

  defp validate_quote(%QuoteResponse{can_solve: true}), do: :ok

  # `validate_intent/2` has already refused a quote with no `eip712_data`.
  defp sign_quote(%QuoteResponse{eip712_data: eip712}, wallet) do
    domain = eip712_domain(eip712)
    types = eip712_types(eip712)
    message = eip712_message(eip712)

    case wallet.sign_typed_data(domain, types, message) do
      {:ok, sig_bytes} ->
        {:ok, "0x" <> Base.encode16(sig_bytes, case: :lower)}

      {:error, reason} ->
        {:error, {:sign_failed, reason}}
    end
  end

  # Origin pull: when the solver served a `pull_authorization`, the agent signs
  # it (a second EIP-712) so Riddler can collect origin funds before settling.
  # `erc3009` is ReceiveWithAuthorization (USDC domain, no approval); `permit2`
  # is PermitWitnessTransferFrom (needs a one-time on-chain Permit2 approval the
  # agent must already hold). Absent for non-pulling methods, in which case there
  # is no pull signature to send.
  defp sign_pull_authorization(
         %QuoteResponse{pull_authorization: nil},
         _wallet
       ),
       do: {:ok, nil}

  defp sign_pull_authorization(%QuoteResponse{pull_authorization: pull}, wallet) do
    domain = eip712_domain(pull)
    types = eip712_types(pull)
    message = eip712_message(pull)

    case wallet.sign_typed_data(domain, types, message) do
      {:ok, sig_bytes} ->
        {:ok, "0x" <> Base.encode16(sig_bytes, case: :lower)}

      {:error, reason} ->
        {:error, {:pull_sign_failed, reason}}
    end
  end

  # Bind the served origin-pull authorization to the caller's intended transfer
  # before signing. The pull is an ERC-3009/Permit2 authorization to move funds
  # out of the agent's wallet on the origin chain; a hostile or compromised quote
  # could otherwise name an attacker recipient for the full balance, which the
  # agent would sign blind (the SpendGate only sees the intended human amount, not
  # the signed message). Check signer, token, chain, and that the authorized value
  # does not exceed the intended origin amount. Fail closed on anything unexpected.
  defp validate_pull_authorization(
         %QuoteResponse{pull_authorization: nil},
         _request,
         _wallet
       ),
       do: :ok

  defp validate_pull_authorization(
         %QuoteResponse{pull_authorization: pull, payment_method: method},
         %QuoteRequest{} = request,
         wallet
       ) do
    case method do
      "erc3009" ->
        validate_erc3009_pull(pull, request, wallet.address())

      "permit2" ->
        validate_permit2_pull(pull, request)

      other ->
        {:error, {:authorization_mismatch, {:unsupported_pull_method, other}}}
    end
  end

  # The wallet signs whatever typed data the quote serves, so the validator must
  # check the served `primaryType` + `types` -- not just the `message` fields by
  # name. Without this a hostile quote could claim `payment_method: "erc3009"`,
  # pass the field checks, yet serve a `TransferWithAuthorization` (no on-chain
  # `msg.sender == to` guard) or a struct carrying extra signable fields. These
  # canonical shapes are what the agent is willing to sign.
  @erc3009_primary_type "ReceiveWithAuthorization"
  @erc3009_fields MapSet.new(~w(from to value validAfter validBefore nonce))
  @permit2_primary_type "PermitWitnessTransferFrom"
  @permit2_fields MapSet.new(~w(permitted spender nonce deadline witness))

  # ERC-3009 ReceiveWithAuthorization: token is the EIP-712 verifyingContract,
  # `from` is the signer, `value` the pulled amount, `validBefore` the expiry.
  # The recipient (`to`) is the solver collection address; it is enforced against
  # the pinned allowlist when one is configured, and against a hard pin when
  # `:pull_require_solver_pin` is set. With neither, an unpinned `to` is left
  # bounded by ERC-3009's `msg.sender == to` plus the value cap. See GitHub #333.
  defp validate_erc3009_pull(pull, request, signer) do
    domain = pull["domain"] || %{}
    message = pull["message"] || %{}

    first_mismatch([
      {:pull_type, valid_envelope?(pull, @erc3009_primary_type, @erc3009_fields)},
      {:pull_from, addr_match?(message["from"], signer)},
      {:pull_token, addr_match?(domain["verifyingContract"], request.from_token)},
      {:pull_chain, int_match?(domain["chainId"], request.from_chain_id)},
      {:pull_value, int_within?(message["value"], pull_ceiling(request))},
      {:pull_to, solver_allowed?(message["to"], :erc3009)},
      {:pull_expiry, valid_window?(message["validBefore"])}
    ])
  end

  # Permit2 PermitWitnessTransferFrom: token + amount live under `permitted`,
  # the owner is recovered from the signature (the agent's own wallet), and
  # `deadline` bounds validity. The `spender` is the solver. Unlike ERC-3009 there
  # is no on-chain recipient guard -- the spender chooses where funds go -- so the
  # spender pin is ALWAYS required (fail-closed): with no allowlist configured a
  # permit2 pull is rejected before signing. The `OriginPullWitness` ties the
  # permit to one intent on-chain. See GitHub #333.
  #
  # `verifyingContract` is pinned to the canonical Permit2 for the same reason
  # the ERC-3009 rail pins its own to the request's token: it decides WHO checks
  # this signature. Leaving it to the quote lets the served payload nominate its
  # own verifier -- a contract whose `DOMAIN_SEPARATOR()` agrees with whatever it
  # served -- while the allowance being spent was granted to Permit2 and the pull
  # runs there. A constant rather than a per-corridor lookup because Permit2 is
  # at one address on every chain raxol settles on; see
  # `Permit2.verifying_contract/0` for the exception that would end that.
  defp validate_permit2_pull(pull, request) do
    domain = pull["domain"] || %{}
    message = pull["message"] || %{}
    permitted = message["permitted"] || %{}

    first_mismatch([
      {:pull_type, valid_envelope?(pull, @permit2_primary_type, @permit2_fields)},
      {:pull_token, addr_match?(permitted["token"], request.from_token)},
      {:pull_verifier, addr_match?(domain["verifyingContract"], Permit2.verifying_contract())},
      {:pull_chain, int_match?(domain["chainId"], request.from_chain_id)},
      {:pull_value, int_within?(permitted["amount"], pull_ceiling(request))},
      {:pull_spender, solver_allowed?(message["spender"], :permit2)},
      {:pull_expiry, valid_window?(message["deadline"])}
    ])
  end

  # The most the pull may authorize: the exact origin amount on `exact_input`,
  # the caller's ceiling on `exact_output` (the solver picks the amount).
  defp pull_ceiling(%QuoteRequest{swap_kind: "exact_output", max_from_amount: max}), do: max
  defp pull_ceiling(%QuoteRequest{from_amount: from_amount}), do: from_amount

  # The served envelope must be exactly the canonical struct for the method: the
  # right `primaryType` and precisely its field set (no missing, no extra signable
  # fields). This binds the object validated to the object signed.
  defp valid_envelope?(pull, primary_type, fields) do
    pull["primaryType"] == primary_type and
      type_field_names(pull, primary_type) == fields
  end

  defp type_field_names(pull, type_name) do
    pull
    |> get_in(["types", type_name])
    |> List.wrap()
    |> Enum.map(fn f -> f["name"] || f[:name] end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # The authorization expiry must be a real future timestamp within a bounded
  # window, so a hostile quote cannot get a long-lived / standing pull signed.
  # Configurable via `:pull_max_validity_seconds` (default 1 hour).
  defp valid_window?(value) do
    now = System.system_time(:second)

    max_ahead =
      Application.get_env(:raxol_payments, :pull_max_validity_seconds, 3600)

    case to_uint(value) do
      t when is_integer(t) -> t > now and t <= now + max_ahead
      _ -> false
    end
  end

  # The origin-pull recipient/spender is the solver's collection address.
  # Configure the pin with
  # `config :raxol_payments, :pull_solver_allowlist, ["0x..."]`; when set, the
  # pull `to`/`spender` must be in it for both methods.
  #
  # Defaults when no allowlist is configured differ by method, because their
  # on-chain guarantees differ: ERC-3009 binds `to` in the signed digest and the
  # token enforces `msg.sender == to`, so an unpinned `to` stays bounded (funds can
  # only reach the signed address) -- accepted unless `:pull_require_solver_pin` is
  # set. Permit2 has NO on-chain recipient guard (the spender picks the recipient
  # at call time), so the pin is the only destination control and is always
  # required -- an unpinned permit2 pull is rejected (fail-closed).
  #
  # When Xochi serves a verifiable/attested solver set in the quote, this resolver
  # is the seam to prefer it over static config. See GitHub #333.
  defp solver_allowed?(addr, method) do
    case solver_allowlist() do
      [] ->
        method == :erc3009 and not require_solver_pin?()

      list ->
        is_binary(addr) and
          Raxol.Payments.EIP712.normalize_address(addr) in list
    end
  end

  defp require_solver_pin?,
    do: Application.get_env(:raxol_payments, :pull_require_solver_pin, false)

  defp solver_allowlist do
    normalize_solver_list(Application.get_env(:raxol_payments, :pull_solver_allowlist, []))
  end

  defp normalize_solver_list(list) do
    list
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Raxol.Payments.EIP712.normalize_address/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp first_mismatch(checks) do
    case Enum.find(checks, fn {_field, ok?} -> not ok? end) do
      nil -> :ok
      {field, _} -> {:error, {:authorization_mismatch, field}}
    end
  end

  defp addr_match?(a, b) when is_binary(a) and is_binary(b) do
    na = Raxol.Payments.EIP712.normalize_address(a)
    valid_address?(na) and na == Raxol.Payments.EIP712.normalize_address(b)
  end

  defp addr_match?(_, _), do: false

  # A canonical 20-byte hex address (after `normalize_address` strips `0x`), so a
  # bound comparison rejects a malformed value rather than matching loosely.
  defp valid_address?(<<hex::binary-size(40)>>),
    do: String.match?(hex, ~r/\A[0-9a-f]{40}\z/)

  defp valid_address?(_), do: false

  defp int_match?(a, b) do
    case {to_uint(a), to_uint(b)} do
      {n, n} when is_integer(n) -> true
      _ -> false
    end
  end

  # The authorized pull value must not exceed the intended origin amount.
  defp int_within?(value, limit) do
    case {to_uint(value), to_uint(limit)} do
      {v, l} when is_integer(v) and is_integer(l) -> v <= l
      _ -> false
    end
  end

  defp to_uint(v) when is_integer(v) and v >= 0, do: v

  defp to_uint(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp to_uint(_), do: nil

  # The execute `nonce` is the worker's replay-dedup key (wallet, nonce); it is
  # NOT part of the intent signature -- the served XochiIntent type carries no
  # nonce field, so the wallet never signs over it. When the signed message does
  # embed an integer nonce, echo it. Otherwise derive a unique, deterministic
  # value from the pull authorization's server-issued bytes32 nonce: echoing a
  # constant 0 for every intent makes the worker reject the second non-terminal
  # intent from a wallet ("Nonce already used"). Fall back to 0 only when neither
  # a signed nonce nor a pull nonce is present.
  defp signed_nonce(%QuoteResponse{
         eip712_data: %{"message" => %{"nonce" => nonce}}
       })
       when is_integer(nonce),
       do: nonce

  defp signed_nonce(%QuoteResponse{
         pull_authorization: %{"message" => %{"nonce" => nonce}}
       })
       when is_binary(nonce),
       do: replay_nonce_from(nonce)

  defp signed_nonce(_quote_resp), do: 0

  # The pull nonce is a 32-byte hex string; take its low 48 bits as an unsigned
  # integer -- unique per intent (server-issued) and within the worker's JS Number
  # range (< 2^53). A malformed value falls back to 0.
  defp replay_nonce_from("0x" <> hex), do: replay_nonce_from(hex)

  defp replay_nonce_from(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) >= 6 ->
        <<low::unsigned-big-48>> = binary_part(bytes, byte_size(bytes) - 6, 6)
        low

      _ ->
        0
    end
  end

  defp replay_nonce_from(_), do: 0

  @domain_fields [
    {:name, "name"},
    {:version, "version"},
    {:chainId, "chainId"},
    {:verifyingContract, "verifyingContract"},
    {:salt, "salt"}
  ]

  @doc """
  Project a served EIP-712 payload's `"domain"` onto the domain map the wallet
  signs, carrying over exactly the keys the worker sent.

  EVERY field is conditional. `Raxol.Payments.EIP712` derives the EIP712Domain
  field list from the keys present, so a key carrying `nil` still declares that
  field and hashes a domain the verifier never built. No served domain uses all
  five: the canonical XochiIntent domain omits `verifyingContract` and carries a
  `salt`, and Permit2's omits `version` (see GitHub #772 -- signing a 4-field
  domain against Permit2's 3-field one reverts InvalidContractSignature on the
  pull).

  Public because the served-to-signed projection is what the conformance oracle
  has to exercise. A test that rebuilds this mapping proves only that the test
  agrees with itself, which is how #772 reached production with a green suite.
  """
  @spec eip712_domain(map()) :: map()
  def eip712_domain(eip712) do
    served = eip712["domain"] || %{}

    Enum.reduce(@domain_fields, %{}, fn {key, served_key}, domain ->
      case served[served_key] do
        nil -> domain
        value -> Map.put(domain, key, value)
      end
    end)
  end

  @doc """
  The served `types` map, projected into the shape `Raxol.Payments.EIP712` encodes.

  `EIP712Domain` is dropped: the domain is hashed from `eip712_domain/1` (or, for
  a checker, read from the verifying contract), and leaving it here would make it
  a second root type and the primary type ambiguous.

  Public for the same reason `eip712_domain/1` is, and it is the same reason
  twice: a second copy of this mapping agrees with itself. `EIP712.hash_struct/3`
  is pinned against ethers-generated vectors, but the projection FEEDING it is
  not, so a checker that re-derived this would rebuild a different struct hash
  the moment either copy changed -- and would report that as the signature being
  bad. `Raxol.Earn.Xochi.PullPreflight` calls this rather than mirroring it.
  """
  @spec eip712_types(map()) :: map()
  def eip712_types(eip712) do
    (eip712["types"] || %{})
    |> Map.drop(["EIP712Domain"])
    |> Enum.into(%{}, fn {name, fields} ->
      {name, Enum.map(fields, fn f -> {f["name"], f["type"]} end)}
    end)
  end

  defp eip712_message(eip712) do
    eip712["message"] || %{}
  end
end
