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
  alias Raxol.Payments.Xochi.Client
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse, ExecuteRequest, IntentStatus}

  # -- Protocol behaviour (stubs -- Xochi is not a 402 protocol) --

  @impl true
  @spec name() :: String.t()
  def name, do: "Xochi"

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
  Sign and execute an intent from a quote.

  Signs the EIP-712 typed data from the quote response using the wallet,
  then submits the signed intent for execution.
  """
  @spec execute(Client.config(), QuoteResponse.t(), module()) ::
          {:ok, Raxol.Payments.Xochi.Schemas.ExecuteResponse.t()} | {:error, term()}
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
  @spec execute(Client.config(), QuoteResponse.t(), module(), QuoteRequest.t() | nil) ::
          {:ok, Raxol.Payments.Xochi.Schemas.ExecuteResponse.t()} | {:error, term()}
  def execute(config, %QuoteResponse{} = quote_resp, wallet, request) do
    with :ok <- validate_quote(quote_resp),
         :ok <- validate_pull_authorization(quote_resp, request, wallet),
         {:ok, signature} <- sign_quote(quote_resp, wallet),
         {:ok, pull_signature} <- sign_pull_authorization(quote_resp, wallet) do
      exec_request = %ExecuteRequest{
        intent_id: quote_resp.intent_id,
        quote_id: quote_resp.quote_id,
        signature: signature,
        nonce: signed_nonce(quote_resp),
        pull_signature: pull_signature
      }

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
    with {:ok, quote_resp} <- get_quote(config, request),
         {:ok, exec_resp} <- execute(config, quote_resp, wallet, request) do
      poll_status(config, exec_resp.intent_id, opts)
    end
  end

  # -- Private --

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
  defp sign_pull_authorization(%QuoteResponse{pull_authorization: nil}, _wallet), do: {:ok, nil}

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
  defp validate_pull_authorization(%QuoteResponse{pull_authorization: nil}, _request, _wallet),
    do: :ok

  defp validate_pull_authorization(%QuoteResponse{pull_authorization: _pull}, nil, _wallet),
    do: {:error, {:authorization_mismatch, :no_request_context}}

  defp validate_pull_authorization(
         %QuoteResponse{pull_authorization: pull, payment_method: method},
         %QuoteRequest{} = request,
         wallet
       ) do
    case method do
      "erc3009" -> validate_erc3009_pull(pull, request, wallet.address())
      "permit2" -> validate_permit2_pull(pull, request)
      other -> {:error, {:authorization_mismatch, {:unsupported_pull_method, other}}}
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
  # The recipient (`to`) is the solver collection address; it is only bound when
  # the operator has pinned a solver allowlist (`solver_allowed?/1` is fail-open
  # by default). ERC-3009's `msg.sender == to` plus the value cap keep the
  # unbound `to` bounded. See GitHub #333.
  defp validate_erc3009_pull(pull, request, signer) do
    domain = pull["domain"] || %{}
    message = pull["message"] || %{}

    first_mismatch([
      {:pull_type, valid_envelope?(pull, @erc3009_primary_type, @erc3009_fields)},
      {:pull_from, addr_match?(message["from"], signer)},
      {:pull_token, addr_match?(domain["verifyingContract"], request.from_token)},
      {:pull_chain, int_match?(domain["chainId"], request.from_chain_id)},
      {:pull_value, int_within?(message["value"], request.from_amount)},
      {:pull_to, solver_allowed?(message["to"])},
      {:pull_expiry, valid_window?(message["validBefore"])}
    ])
  end

  # Permit2 PermitWitnessTransferFrom: token + amount live under `permitted`,
  # the owner is recovered from the signature (the agent's own wallet), and
  # `deadline` bounds validity. The `spender` is the solver; bound only when the
  # operator pins a solver allowlist (fail-open by default). The `OriginPullWitness`
  # ties the permit to one intent on-chain. See GitHub #333.
  defp validate_permit2_pull(pull, request) do
    domain = pull["domain"] || %{}
    message = pull["message"] || %{}
    permitted = message["permitted"] || %{}

    first_mismatch([
      {:pull_type, valid_envelope?(pull, @permit2_primary_type, @permit2_fields)},
      {:pull_token, addr_match?(permitted["token"], request.from_token)},
      {:pull_chain, int_match?(domain["chainId"], request.from_chain_id)},
      {:pull_value, int_within?(permitted["amount"], request.from_amount)},
      {:pull_spender, solver_allowed?(message["spender"])},
      {:pull_expiry, valid_window?(message["deadline"])}
    ])
  end

  # The served envelope must be exactly the canonical struct for the method: the
  # right `primaryType` and precisely its field set (no missing, no extra signable
  # fields). This binds the object validated to the object signed.
  defp valid_envelope?(pull, primary_type, fields) do
    pull["primaryType"] == primary_type and type_field_names(pull, primary_type) == fields
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
    max_ahead = Application.get_env(:raxol_payments, :pull_max_validity_seconds, 3600)

    case to_uint(value) do
      t when is_integer(t) -> t > now and t <= now + max_ahead
      _ -> false
    end
  end

  # The origin-pull recipient/spender is the solver's collection address. There
  # is no client-facing solver manifest, and solver addresses rotate, so a pinned
  # allowlist is opt-in: when the operator configures
  # `config :raxol_payments, :pull_solver_allowlist, ["0x..."]`, the pull `to`/
  # `spender` must be in it; when unset (the default), the address is not bound
  # and any solver is accepted. When Xochi serves a verifiable/attested solver
  # set in the quote, this resolver is the seam to prefer it over static config.
  defp solver_allowed?(addr) do
    case solver_allowlist() do
      [] -> true
      list -> is_binary(addr) and normalize_address(addr) in list
    end
  end

  defp solver_allowlist do
    :raxol_payments
    |> Application.get_env(:pull_solver_allowlist, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_address/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp first_mismatch(checks) do
    case Enum.find(checks, fn {_field, ok?} -> not ok? end) do
      nil -> :ok
      {field, _} -> {:error, {:authorization_mismatch, field}}
    end
  end

  defp addr_match?(a, b) when is_binary(a) and is_binary(b) do
    na = normalize_address(a)
    valid_address?(na) and na == normalize_address(b)
  end

  defp addr_match?(_, _), do: false

  defp normalize_address(addr) do
    addr |> String.trim() |> String.downcase() |> String.replace_prefix("0x", "")
  end

  # A canonical 20-byte hex address (after `normalize_address` strips `0x`), so a
  # bound comparison rejects a malformed value rather than matching loosely.
  defp valid_address?(<<hex::binary-size(40)>>), do: String.match?(hex, ~r/\A[0-9a-f]{40}\z/)
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
  defp signed_nonce(%QuoteResponse{eip712_data: %{"message" => %{"nonce" => nonce}}})
       when is_integer(nonce),
       do: nonce

  defp signed_nonce(%QuoteResponse{pull_authorization: %{"message" => %{"nonce" => nonce}}})
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
  defp maybe_put_verifying_contract(domain, vc), do: Map.put(domain, :verifyingContract, vc)

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
