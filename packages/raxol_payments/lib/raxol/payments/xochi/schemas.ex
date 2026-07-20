defmodule Raxol.Payments.Xochi.Schemas do
  @moduledoc """
  Request/response schemas for the Xochi intent API.

  Typed structs matching the Xochi API wire format (camelCase JSON).
  Xochi is the cash-positive agent-facing protocol -- Riddler solves
  intents behind the scenes.
  """

  @eth_address_re ~r/\A0x[0-9a-fA-F]{40}\z/

  @doc false
  @spec validate_eth_address(String.t()) :: :ok | {:error, :invalid_address}
  def validate_eth_address(addr) when is_binary(addr) do
    if Regex.match?(@eth_address_re, addr), do: :ok, else: {:error, :invalid_address}
  end

  def validate_eth_address(_), do: {:error, :invalid_address}

  @doc false
  @spec put_non_nil(map(), String.t(), term()) :: map()
  def put_non_nil(map, _key, nil), do: map
  def put_non_nil(map, key, val), do: Map.put(map, key, val)

  defmodule QuoteRequest do
    @moduledoc false
    @enforce_keys [
      :wallet,
      :from_chain_id,
      :to_chain_id,
      :from_token,
      :to_token,
      :from_amount,
      :settlement_preference
    ]
    defstruct [
      :wallet,
      :from_chain_id,
      :to_chain_id,
      :from_token,
      :to_token,
      :from_amount,
      :recipient_address,
      :trust_score,
      :stealth_spending_pub_key,
      :stealth_viewing_pub_key,
      settlement_preference: "public",
      deadline: nil,
      slippage_bps: 50,
      gasless: false,
      attestations: []
    ]

    @type settlement :: String.t()

    @type t :: %__MODULE__{
            wallet: String.t(),
            from_chain_id: pos_integer(),
            to_chain_id: pos_integer(),
            from_token: String.t(),
            to_token: String.t(),
            from_amount: String.t(),
            recipient_address: String.t() | nil,
            settlement_preference: settlement(),
            deadline: integer() | nil,
            slippage_bps: non_neg_integer(),
            trust_score: non_neg_integer() | nil,
            stealth_spending_pub_key: String.t() | nil,
            stealth_viewing_pub_key: String.t() | nil,
            gasless: boolean(),
            attestations: [map()]
          }

    # Compressed secp256k1 public key: 0x + 02/03 prefix + 32 bytes (66 hex chars).
    @compressed_pubkey ~r/^0x0[23][a-fA-F0-9]{64}$/

    @spec validate(t()) :: :ok | {:error, term()}
    def validate(%__MODULE__{} = req) do
      alias Raxol.Payments.Xochi.Schemas

      cond do
        Schemas.validate_eth_address(req.wallet) != :ok ->
          {:error, {:invalid_wallet, "must be 0x + 40 hex chars"}}

        Schemas.validate_eth_address(req.from_token) != :ok ->
          {:error, {:invalid_from_token, "must be 0x + 40 hex chars"}}

        Schemas.validate_eth_address(req.to_token) != :ok ->
          {:error, {:invalid_to_token, "must be 0x + 40 hex chars"}}

        req.from_chain_id < 1 ->
          {:error, {:invalid_chain_id, "from_chain_id must be positive"}}

        req.to_chain_id < 1 ->
          {:error, {:invalid_chain_id, "to_chain_id must be positive"}}

        req.settlement_preference == "stealth" and not stealth_keys_present?(req) ->
          {:error,
           {:stealth_keys_required,
            "stealth settlement requires compressed spending and viewing public keys"}}

        not recipient_address_valid?(req.recipient_address) ->
          {:error, {:invalid_recipient_address, "must be a non-empty string when set"}}

        true ->
          :ok
      end
    end

    # `recipient_address` is optional: nil lets Riddler default it to `wallet`
    # (same-VM). When set (required for a cross-VM route, e.g. an EVM wallet
    # paying a Tron address), it must be a non-empty string. The chain-specific
    # format (EVM `0x`-hex vs TVM/SVM base58) is validated by Riddler against
    # `to_chain_id`, which owns the chain->VM mapping.
    defp recipient_address_valid?(nil), do: true
    defp recipient_address_valid?(addr) when is_binary(addr), do: addr != ""
    defp recipient_address_valid?(_), do: false

    defp stealth_keys_present?(%__MODULE__{
           stealth_spending_pub_key: spend,
           stealth_viewing_pub_key: view
         }) do
      compressed_pubkey?(spend) and compressed_pubkey?(view)
    end

    defp compressed_pubkey?(key) when is_binary(key),
      do: Regex.match?(@compressed_pubkey, key)

    defp compressed_pubkey?(_), do: false

    @spec to_json(t()) :: map()
    def to_json(%__MODULE__{} = req) do
      base = %{
        "wallet" => req.wallet,
        "from_chain_id" => req.from_chain_id,
        "to_chain_id" => req.to_chain_id,
        "from_token" => req.from_token,
        "to_token" => req.to_token,
        "from_amount" => req.from_amount,
        "settlement_preference" => req.settlement_preference,
        "deadline" => req.deadline || :os.system_time(:second) + 300,
        "slippage_bps" => req.slippage_bps,
        "gasless" => req.gasless
      }

      base
      |> Raxol.Payments.Xochi.Schemas.put_non_nil("recipient_address", req.recipient_address)
      |> Raxol.Payments.Xochi.Schemas.put_non_nil("trust_score", req.trust_score)
      |> Raxol.Payments.Xochi.Schemas.put_non_nil(
        "stealth_spending_pub_key",
        req.stealth_spending_pub_key
      )
      |> Raxol.Payments.Xochi.Schemas.put_non_nil(
        "stealth_viewing_pub_key",
        req.stealth_viewing_pub_key
      )
      |> maybe_put_attestations(req.attestations)
    end

    defp maybe_put_attestations(map, []), do: map

    defp maybe_put_attestations(map, attestations) when is_list(attestations) do
      Map.put(map, "attestations", Enum.map(attestations, &attestation_to_json/1))
    end

    defp attestation_to_json(
           %{
             type_code: code,
             issuer: issuer,
             subject: subject,
             issued_at: issued,
             expires_at: expires,
             signature: sig
           } = proof
         ) do
      base = %{
        "typeCode" => code,
        "issuer" => issuer,
        "subject" => subject,
        "issuedAt" => issued,
        "expiresAt" => expires,
        "signature" => sig
      }

      case Map.get(proof, :payload) do
        nil ->
          base

        payload when is_binary(payload) ->
          Map.put(base, "payload", Base.encode16(payload, case: :lower))
      end
    end
  end

  defmodule DepositRouteRequest do
    @moduledoc """
    A cross-VM deposit-route quote request: a non-EVM origin (Tron) settling to
    an EVM destination. The origin has no gasless pull, so the quote returns a
    `deposit_address` (+ `deposit_attestation` to verify) instead of EIP-712
    typed data to sign.

    Serializes to the same `/api/intent/quote` wire keys as `QuoteRequest`, but
    validates the origin fields as Tron base58 and the destination fields as EVM
    `0x`-hex. Only a Tron origin is supported today; other non-EVM origins reject
    at `validate/1`.
    """

    @tron_chain_id 728_126_428

    @enforce_keys [:wallet, :from_chain_id, :to_chain_id, :from_token, :to_token, :from_amount]
    defstruct [
      :wallet,
      :from_chain_id,
      :to_chain_id,
      :from_token,
      :to_token,
      :from_amount,
      :recipient_address,
      :trust_score,
      settlement_preference: "public",
      slippage_bps: 50
    ]

    @type t :: %__MODULE__{
            wallet: String.t(),
            from_chain_id: pos_integer(),
            to_chain_id: pos_integer(),
            from_token: String.t(),
            to_token: String.t(),
            from_amount: String.t(),
            recipient_address: String.t() | nil,
            trust_score: non_neg_integer() | nil,
            settlement_preference: String.t(),
            slippage_bps: non_neg_integer()
          }

    @spec validate(t()) :: :ok | {:error, term()}
    def validate(%__MODULE__{} = req) do
      alias Raxol.Payments.Tron
      alias Raxol.Payments.Xochi.Schemas

      cond do
        req.from_chain_id != @tron_chain_id ->
          {:error, {:unsupported_origin_vm, "deposit routes support a Tron origin only"}}

        not Tron.Address.valid?(req.wallet) ->
          {:error, {:invalid_wallet, "origin wallet must be a Tron base58 address"}}

        not Tron.Address.valid?(req.from_token) ->
          {:error, {:invalid_from_token, "origin token must be a Tron base58 address"}}

        req.to_chain_id < 1 ->
          {:error, {:invalid_chain_id, "to_chain_id must be positive"}}

        Schemas.validate_eth_address(req.to_token) != :ok ->
          {:error, {:invalid_to_token, "destination token must be 0x + 40 hex chars"}}

        # A cross-VM route pays an EVM destination distinct from the Tron wallet,
        # so a valid EVM recipient is required -- the wallet cannot receive on EVM.
        Schemas.validate_eth_address(req.recipient_address) != :ok ->
          {:error,
           {:invalid_recipient_address, "destination recipient must be 0x + 40 hex chars"}}

        not positive_int_string?(req.from_amount) ->
          {:error, {:invalid_from_amount, "must be a positive base-unit integer string"}}

        true ->
          :ok
      end
    end

    @spec to_json(t()) :: map()
    def to_json(%__MODULE__{} = req) do
      %{
        "wallet" => req.wallet,
        "from_chain_id" => req.from_chain_id,
        "to_chain_id" => req.to_chain_id,
        "from_token" => req.from_token,
        "to_token" => req.to_token,
        "from_amount" => req.from_amount,
        "recipient_address" => req.recipient_address,
        "settlement_preference" => req.settlement_preference,
        "slippage_bps" => req.slippage_bps
      }
      |> Raxol.Payments.Xochi.Schemas.put_non_nil("trust_score", req.trust_score)
    end

    defp positive_int_string?(amount) when is_binary(amount) do
      match?({n, ""} when n > 0, Integer.parse(amount))
    end

    defp positive_int_string?(_), do: false
  end

  defmodule QuoteResponse do
    @moduledoc false
    @enforce_keys [:intent_id, :quote_id]
    defstruct [
      :intent_id,
      :quote_id,
      :to_amount,
      :min_to_amount,
      :xochi_fee,
      :xochi_fee_rate,
      :estimated_gas_cost,
      :expiry,
      :eip712_data,
      :pull_authorization,
      :deposit_address,
      :deposit_attestation,
      :deposit_deadline,
      :payment_method,
      :error,
      can_solve: false,
      gasless: false,
      gasless_fee: nil,
      settlement_options: []
    ]

    @type t :: %__MODULE__{
            intent_id: String.t(),
            quote_id: String.t(),
            can_solve: boolean(),
            to_amount: String.t() | nil,
            min_to_amount: String.t() | nil,
            xochi_fee: String.t() | nil,
            xochi_fee_rate: String.t() | nil,
            estimated_gas_cost: String.t() | nil,
            expiry: term() | nil,
            gasless: boolean(),
            gasless_fee: String.t() | nil,
            eip712_data: map() | nil,
            pull_authorization: map() | nil,
            deposit_address: String.t() | nil,
            deposit_attestation: String.t() | nil,
            deposit_deadline: integer() | nil,
            payment_method: String.t() | nil,
            settlement_options: [map()],
            error: String.t() | nil
          }

    @doc """
    A deposit-route quote: a non-EVM (Tron/Solana) origin with no gasless pull,
    so the quote carries a `deposit_address` the payer sends funds to (verify the
    `deposit_attestation` first) instead of EIP-712 typed data to sign.
    """
    @spec deposit_route?(t()) :: boolean()
    def deposit_route?(%__MODULE__{deposit_address: a}) when is_binary(a) and a != "", do: true
    def deposit_route?(_), do: false

    # The Xochi worker response is snake_case with `eip712`; older/sim responses
    # are camelCase with `eip712Data`. Accept both so the client does not break
    # on the canonical (snake_case) shape. See xochi/docs/contracts/xochi-intent-api.md.
    @spec from_json(map()) :: t()
    def from_json(json) do
      %__MODULE__{
        intent_id: pick(json, ["intent_id", "intentId"]),
        quote_id: pick(json, ["quote_id", "quoteId"]),
        can_solve: pick(json, ["can_solve", "canSolve"]) || false,
        to_amount: pick(json, ["to_amount", "toAmount"]),
        min_to_amount: pick(json, ["min_to_amount", "minToAmount"]),
        xochi_fee: pick(json, ["xochi_fee", "xochiFee"]) || get_in(json, ["fee", "fee_amount"]),
        xochi_fee_rate: pick(json, ["xochi_fee_rate", "xochiFeeRate"]),
        estimated_gas_cost:
          pick(json, ["estimated_gas_cost", "estimatedGasCost", "estimated_gas_cost_usd"]),
        expiry: pick(json, ["expiry", "expires_at"]),
        gasless: pick(json, ["gasless"]) || false,
        gasless_fee: pick(json, ["gasless_fee", "gaslessFee"]),
        eip712_data: pick(json, ["eip712", "eip712Data"]),
        pull_authorization: pick(json, ["pull_authorization", "pullAuthorization"]),
        deposit_address: pick(json, ["deposit_address", "depositAddress"]),
        deposit_attestation: pick(json, ["deposit_attestation", "depositAttestation"]),
        deposit_deadline: pick(json, ["deposit_deadline", "depositDeadline"]),
        payment_method: pick(json, ["payment_method", "paymentMethod"]),
        settlement_options: pick(json, ["settlement_options", "settlementOptions"]) || [],
        error: pick(json, ["error", "reason"])
      }
    end

    defp pick(json, keys), do: Enum.find_value(keys, fn key -> json[key] end)
  end

  defmodule ExecuteRequest do
    @moduledoc false
    @enforce_keys [:intent_id, :quote_id, :signature, :nonce]
    defstruct [:intent_id, :quote_id, :signature, :nonce, :pull_signature, :aztec_proof]

    @type t :: %__MODULE__{
            intent_id: String.t(),
            quote_id: String.t(),
            signature: String.t(),
            nonce: non_neg_integer(),
            pull_signature: String.t() | nil,
            aztec_proof: String.t() | nil
          }

    @spec to_json(t()) :: map()
    def to_json(%__MODULE__{} = req) do
      base = %{
        "intent_id" => req.intent_id,
        "quote_id" => req.quote_id,
        "signature" => req.signature,
        "nonce" => req.nonce
      }

      base
      |> Raxol.Payments.Xochi.Schemas.put_non_nil("pull_signature", req.pull_signature)
      |> Raxol.Payments.Xochi.Schemas.put_non_nil("aztec_proof", req.aztec_proof)
    end
  end

  defmodule ExecuteResponse do
    @moduledoc false
    @enforce_keys [:intent_id, :status]
    defstruct [
      :intent_id,
      :status,
      :tx_hash,
      :note_commitment,
      :stealth_address,
      :ephemeral_pub_key,
      :view_tag,
      :error,
      success: false,
      reconciling: false
    ]

    @type t :: %__MODULE__{
            success: boolean(),
            intent_id: String.t(),
            status: atom(),
            tx_hash: String.t() | nil,
            note_commitment: String.t() | nil,
            stealth_address: String.t() | nil,
            ephemeral_pub_key: String.t() | nil,
            view_tag: integer() | nil,
            error: String.t() | nil,
            reconciling: boolean()
          }

    # The Xochi worker's execute response is snake_case (`intent_id`, `tx_hash`,
    # `stealth_address`, ...); older/sim responses are camelCase. Accept both, as
    # QuoteResponse does, so the client reads the canonical worker shape -- reading
    # only camelCase left `intent_id` nil and tripped the Action output contract.
    # See xochi/packages/worker-lib/src/handlers/intents.ts (handleExecuteIntent).
    @spec from_json(map()) :: t()
    def from_json(json) do
      %__MODULE__{
        success: json["success"] || false,
        intent_id: pick(json, ["intent_id", "intentId"]),
        status: parse_status(json["status"]),
        tx_hash: pick(json, ["tx_hash", "txHash"]),
        note_commitment: pick(json, ["note_commitment", "noteCommitment"]),
        stealth_address: pick(json, ["stealth_address", "stealthAddress"]),
        ephemeral_pub_key: pick(json, ["ephemeral_pub_key", "ephemeralPubKey"]),
        view_tag: pick(json, ["view_tag", "viewTag"]),
        error: json["error"],
        # In-doubt: the worker could not confirm the solver executed (a Riddler
        # 5xx/timeout wrapped as a 200) and kept the intent non-terminal. Funds
        # may be in flight; the caller must poll to resolve, never re-execute.
        reconciling: pick(json, ["reconciling"]) || false
      }
    end

    defp pick(json, keys), do: Enum.find_value(keys, fn key -> json[key] end)

    defp parse_status(nil), do: :unknown
    defp parse_status("pending"), do: :pending
    defp parse_status("executing"), do: :executing
    defp parse_status("settling"), do: :settling
    defp parse_status("completed"), do: :completed
    defp parse_status("failed"), do: :failed
    defp parse_status(_s), do: :unknown
  end

  defmodule IntentStatus do
    @moduledoc false
    @enforce_keys [:intent_id, :status]
    defstruct [
      :intent_id,
      :status,
      :tx_hash,
      :receiving_tx_hash,
      :error,
      # Solver-supplied reason a refunded intent was refunded (worker
      # `refundReason`); present only on the terminal `:refunded` status.
      :refund_reason,
      :updated_at,
      :substatus,
      :substatus_message,
      # PXE shielded settlement fields (present when settlement = :shielded)
      :note_commitment,
      :nullifier_hash,
      :l2_tx_hash,
      :settlement_type,
      :attestation_status,
      terminal: false
    ]

    @type status ::
            :idle
            | :pending
            | :quoting
            | :quoted
            | :signing
            | :executing
            | :bridging
            | :settling
            | :completed
            | :failed
            | :expired
            | :refunded

    @type settlement_type :: :public | :stealth | :shielded | nil
    @type attestation_status :: :verified | :rejected | :not_required | nil

    @type t :: %__MODULE__{
            intent_id: String.t(),
            status: status(),
            tx_hash: String.t() | nil,
            receiving_tx_hash: String.t() | nil,
            error: String.t() | nil,
            refund_reason: String.t() | nil,
            updated_at: String.t() | nil,
            substatus: String.t() | nil,
            substatus_message: String.t() | nil,
            note_commitment: String.t() | nil,
            nullifier_hash: String.t() | nil,
            l2_tx_hash: String.t() | nil,
            settlement_type: settlement_type(),
            attestation_status: attestation_status(),
            terminal: boolean()
          }

    @terminal_statuses [:completed, :failed, :expired, :refunded]

    # The Xochi worker's status response is snake_case (`intent_id`, `tx_hash`,
    # `terminal`, ...); older/sim responses are camelCase. Accept both so the poll
    # reads the canonical worker shape -- reading only camelCase dropped
    # `intent_id`/`tx_hash` (status/terminal happened to match either way). See
    # xochi/packages/worker-lib/src/handlers/intents.ts (handlePollIntentStatus).
    @spec from_json(map()) :: t()
    def from_json(json) do
      status = parse_status(json["status"])

      %__MODULE__{
        intent_id: pick(json, ["intent_id", "intentId"]),
        status: status,
        tx_hash: pick(json, ["tx_hash", "txHash"]),
        receiving_tx_hash: pick(json, ["receiving_tx_hash", "receivingTxHash"]),
        error: json["error"],
        refund_reason: pick(json, ["refund_reason", "refundReason"]),
        updated_at: pick(json, ["updated_at", "updatedAt"]),
        substatus: json["substatus"],
        substatus_message: pick(json, ["substatus_message", "substatusMessage"]),
        note_commitment: pick(json, ["note_commitment", "noteCommitment"]),
        nullifier_hash: pick(json, ["nullifier_hash", "nullifierHash"]),
        l2_tx_hash: pick(json, ["l2_tx_hash", "l2TxHash"]),
        settlement_type: parse_settlement_type(pick(json, ["settlement_type", "settlementType"])),
        attestation_status:
          parse_attestation_status(pick(json, ["attestation_status", "attestationStatus"])),
        terminal: json["terminal"] || status in @terminal_statuses
      }
    end

    defp pick(json, keys), do: Enum.find_value(keys, fn key -> json[key] end)

    @spec terminal?(t()) :: boolean()
    def terminal?(%__MODULE__{terminal: t}), do: t

    @spec shielded?(t()) :: boolean()
    def shielded?(%__MODULE__{settlement_type: :shielded}), do: true
    def shielded?(%__MODULE__{note_commitment: c}) when is_binary(c), do: true
    def shielded?(_), do: false

    defp parse_status(nil), do: :unknown
    defp parse_status("idle"), do: :idle
    defp parse_status("pending"), do: :pending
    defp parse_status("quoting"), do: :quoting
    defp parse_status("quoted"), do: :quoted
    defp parse_status("signing"), do: :signing
    defp parse_status("executing"), do: :executing
    defp parse_status("bridging"), do: :bridging
    defp parse_status("settling"), do: :settling
    defp parse_status("completed"), do: :completed
    defp parse_status("failed"), do: :failed
    defp parse_status("expired"), do: :expired
    defp parse_status("refunded"), do: :refunded
    defp parse_status(_s), do: :unknown

    defp parse_settlement_type(nil), do: nil
    defp parse_settlement_type("public"), do: :public
    defp parse_settlement_type("stealth"), do: :stealth
    defp parse_settlement_type("shielded"), do: :shielded
    defp parse_settlement_type(_s), do: nil

    defp parse_attestation_status(nil), do: nil
    defp parse_attestation_status("verified"), do: :verified
    defp parse_attestation_status("rejected"), do: :rejected
    defp parse_attestation_status("not_required"), do: :not_required
    defp parse_attestation_status(_s), do: nil
  end

  defmodule Intent do
    @moduledoc """
    A persisted Xochi intent as returned by `GET /api/intent/:id`.

    Unlike `IntentStatus` (settlement/tx state only), this carries the
    authoritative corridor and amounts written at quote time (`status: :quoted`),
    so a relayer can read what the buyer signed before settlement -- see the
    worker's `handleGetIntent`
    (`xochi/packages/worker-lib/src/handlers/intents/read.ts`). Amounts are token
    base-unit strings; `fee_rate` is the tier fraction (e.g. `0.003`).
    """

    @enforce_keys [:intent_id, :status]
    defstruct [
      :intent_id,
      :status,
      :from_chain_id,
      :to_chain_id,
      :from_token,
      :to_token,
      :from_amount,
      :to_amount,
      :quote_id,
      :tier,
      :fee_rate,
      :settlement_type
    ]

    @type t :: %__MODULE__{
            intent_id: String.t(),
            status: atom(),
            from_chain_id: pos_integer() | nil,
            to_chain_id: pos_integer() | nil,
            from_token: String.t() | nil,
            to_token: String.t() | nil,
            from_amount: String.t() | nil,
            to_amount: String.t() | nil,
            quote_id: String.t() | nil,
            tier: String.t() | nil,
            fee_rate: number() | nil,
            settlement_type: String.t() | nil
          }

    @spec from_json(map()) :: t()
    def from_json(json) do
      %__MODULE__{
        intent_id: pick(json, ["intent_id", "intentId", "id"]),
        status: parse_status(json["status"]),
        from_chain_id: pick(json, ["from_chain_id", "fromChainId"]),
        to_chain_id: pick(json, ["to_chain_id", "toChainId"]),
        from_token: pick(json, ["from_token", "fromToken"]),
        to_token: pick(json, ["to_token", "toToken"]),
        from_amount: pick(json, ["from_amount", "fromAmount"]),
        to_amount: pick(json, ["to_amount", "toAmount"]),
        quote_id: pick(json, ["quote_id", "quoteId"]),
        tier: json["tier"],
        fee_rate: pick(json, ["fee_rate", "feeRate"]),
        settlement_type: pick(json, ["settlement_type", "settlementType"])
      }
    end

    defp pick(json, keys), do: Enum.find_value(keys, fn key -> json[key] end)

    # A fixed status whitelist. The `~w(...)a` sigil makes the atoms literals in
    # THIS module (so they always exist -- `String.to_existing_atom/1` would trip
    # when `IntentStatus` is not loaded), and the compile-time map keeps wire
    # input from minting a new atom; anything unknown degrades to `:unknown`.
    @status_atoms ~w(idle pending quoting quoted signing executing bridging settling
                     completed failed expired refunded unknown)a
    @status_by_name Map.new(@status_atoms, &{Atom.to_string(&1), &1})
    defp parse_status(status), do: Map.get(@status_by_name, status, :unknown)
  end
end
