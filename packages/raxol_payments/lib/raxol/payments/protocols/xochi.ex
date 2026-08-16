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

      {:ok, quote} = Xochi.quote(config, %QuoteRequest{...})
      {:ok, exec} = Xochi.execute(config, quote, wallet)
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
         :ok <- ensure_solvable(quote),
         {:ok, instructions} <-
           verify_deposit_route(config, request, quote, opts) do
      {:ok, instructions}
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
      expires_at: quote.expiry
    }
  end

  @doc """
  Sign and execute an intent from a quote.

  Signs the EIP-712 typed data from the quote response using the wallet,
  then submits the signed intent for execution.
  """
  @spec execute(Client.config(), QuoteResponse.t(), module()) ::
          {:ok, Raxol.Payments.Xochi.Schemas.ExecuteResponse.t()}
          | {:error, term()}
  def execute(config, %QuoteResponse{} = quote_resp, wallet) do
    execute(config, quote_resp, wallet, nil)
  end

  @doc """
  Like `execute/3`, but binds the served `pull_authorization` to the caller's
  intended transfer (`request`) before signing it.

  The agent signs an ERC-3009/Permit2 authorization the solver serves; a hostile
  or compromised quote endpoint could otherwise serve one that pulls the wallet's
  full balance to an attacker. With the `request`, the origin pull is checked
  against the intended signer, token, chain, and amount before any signature is
  released. Pass `nil` only when there is no pull authorization to validate; a
  pull authorization presented with a `nil` request fails closed.
  """
  @spec execute(
          Client.config(),
          QuoteResponse.t(),
          module(),
          QuoteRequest.t() | nil
        ) ::
          {:ok, Raxol.Payments.Xochi.Schemas.ExecuteResponse.t()}
          | {:error, term()}
  def execute(config, %QuoteResponse{} = quote_resp, wallet, request) do
    with {:ok, bundle} <- sign_intent(quote_resp, wallet, request) do
      execute_signed(config, bundle)
    end
  end

  @doc """
  Sign a quoted intent into a relayable bundle WITHOUT executing it.

  The buyer-side counterpart to `execute_signed/2`: validates the quote, signs
  the EIP-712 intent with `wallet`, and returns the opaque bundle
  `%{intent_id, quote_id, signature, nonce}` (plus `pull_signature` when the
  quote carried an origin-pull authorization) to hand to a storefront/relay or
  to `execute_signed/2` directly. Does not talk to the worker.
  """
  @spec sign_intent(QuoteResponse.t(), module()) ::
          {:ok, signed_intent()} | {:error, term()}
  def sign_intent(quote_resp, wallet), do: sign_intent(quote_resp, wallet, nil)

  @doc """
  Like `sign_intent/2`, but binds the served `pull_authorization` to the caller's
  intended transfer (`request`) before signing it -- see `execute/4` for why this
  matters. Pass `nil` only when there is no pull authorization to validate; a
  pull presented with a `nil` request fails closed.
  """
  @spec sign_intent(QuoteResponse.t(), module(), QuoteRequest.t() | nil) ::
          {:ok, signed_intent()} | {:error, term()}
  def sign_intent(%QuoteResponse{} = quote_resp, wallet, request) do
    with :ok <- validate_quote(quote_resp),
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
        from_amount: request.from_amount,
        to_amount: quote_resp.to_amount,
        xochi_fee: quote_resp.xochi_fee,
        tx_hash: status.tx_hash,
        settlement_type: status.settlement_type
      }
    )
  end

  defp emit_settled(_request, _quote_resp, _status, _elapsed_ms), do: :ok

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

  defp sign_quote(%QuoteResponse{eip712_data: nil}, _wallet) do
    {:error, :no_eip712_data}
  end

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
         %QuoteResponse{pull_authorization: _pull},
         nil,
         _wallet
       ),
       do: {:error, {:authorization_mismatch, :no_request_context}}

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
      {:pull_value, int_within?(message["value"], request.from_amount)},
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
  defp validate_permit2_pull(pull, request) do
    domain = pull["domain"] || %{}
    message = pull["message"] || %{}
    permitted = message["permitted"] || %{}

    first_mismatch([
      {:pull_type, valid_envelope?(pull, @permit2_primary_type, @permit2_fields)},
      {:pull_token, addr_match?(permitted["token"], request.from_token)},
      {:pull_chain, int_match?(domain["chainId"], request.from_chain_id)},
      {:pull_value, int_within?(permitted["amount"], request.from_amount)},
      {:pull_spender, solver_allowed?(message["spender"], :permit2)},
      {:pull_expiry, valid_window?(message["deadline"])}
    ])
  end

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

  # Build the domain from exactly the keys the worker served. `verifyingContract`
  # and `salt` are only included when present: the canonical XochiIntent domain
  # omits `verifyingContract` and carries a `salt`, so the included key set must
  # mirror the served domain exactly -- dropping `salt` (or adding a nil
  # verifyingContract) hashes a different EIP712Domain than the worker's and the
  # signature does not recover.
  defp eip712_domain(eip712) do
    d = eip712["domain"] || %{}

    %{name: d["name"], version: d["version"], chainId: d["chainId"]}
    |> maybe_put_verifying_contract(d["verifyingContract"])
    |> maybe_put_salt(d["salt"])
  end

  defp maybe_put_verifying_contract(domain, nil), do: domain

  defp maybe_put_verifying_contract(domain, vc),
    do: Map.put(domain, :verifyingContract, vc)

  defp maybe_put_salt(domain, nil), do: domain
  defp maybe_put_salt(domain, salt), do: Map.put(domain, :salt, salt)

  defp eip712_types(eip712) do
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
