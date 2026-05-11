defmodule Raxol.Payments.Mandate do
  @moduledoc """
  Xochi delegation envelope: an EIP-712-signed authorization from a
  Xochi Member to a specific agent wallet, scoped to particular
  endpoints with a budget.

  Per the Xochi design (locked 2026-04-27 in
  `xochi/docs/planning/agent-auth.md`), a Mandate is a **per-request
  envelope** the agent presents on every protected Xochi call via
  `X-Xochi-Delegation`. Xochi's worker verifies the signature and
  decrements budget counters in KV keyed by `H(envelope)`. The agent
  never authenticates; it just holds and presents the envelope.

  This module's job is to **issue, hold, and present** envelopes from
  the raxol side. It does not enforce budgets locally -- that's
  Xochi's responsibility.

  ## Wire format

      X-Xochi-Delegation: base64url(JSON({
        message: <MandateMessage>,
        signature: "0x" <> <130 hex chars>
      }))

  ## Schema

  Matches `xochi/packages/shared/src/eip712.ts:182-263` exactly --
  the type hash and field ordering must agree, or signatures won't
  verify on the Xochi side.

      Mandate(
        address human_wallet,
        address agent_wallet,
        string[] scopes,
        uint256 max_amount_usd,
        uint256 max_calls,
        uint256 expires_at,
        bytes32 nonce
      )

      EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
        name              = "Xochi Mandate"
        version           = "1"
        chainId           = 1
        verifyingContract = 0x0000000000000000000000000000000000000000

  Chain ID is pinned to mainnet by convention. The envelope is metadata,
  not a transaction; the pin keeps the type hash stable across deployments.
  """

  @type scope :: String.t()
  @type hex_address :: String.t()
  @type hex_signature :: String.t()
  @type hex_bytes32 :: String.t()

  @type t :: %__MODULE__{
          human_wallet: hex_address(),
          agent_wallet: hex_address(),
          scopes: [scope()],
          max_amount_usd: non_neg_integer(),
          max_calls: pos_integer(),
          expires_at: pos_integer(),
          nonce: hex_bytes32(),
          signature: hex_signature() | nil,
          envelope_hash: <<_::256>> | nil,
          created_at: integer()
        }

  defstruct [
    :human_wallet,
    :agent_wallet,
    :scopes,
    :max_amount_usd,
    :max_calls,
    :expires_at,
    :nonce,
    :signature,
    :envelope_hash,
    :created_at
  ]

  @allowed_scopes ~w(quote execute stealth_claim)
  @domain_name "Xochi Mandate"
  @domain_version "1"
  @domain_chain_id 1
  @zero_address "0x0000000000000000000000000000000000000000"

  @mandate_type_string "Mandate(address human_wallet,address agent_wallet,string[] scopes,uint256 max_amount_usd,uint256 max_calls,uint256 expires_at,bytes32 nonce)"
  @domain_type_string "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"

  @doc """
  Build an unsigned Mandate, validating fields against the Xochi Zod
  constraints in `xochi/packages/shared/src/schemas.ts:197-211`.

  Generates a random 32-byte nonce when omitted.
  """
  @spec build(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def build(attrs) when is_list(attrs), do: build(Map.new(attrs))

  def build(%{} = attrs) do
    with {:ok, fields} <- extract_fields(attrs) do
      {:ok, struct(__MODULE__, fields)}
    end
  end

  defp extract_fields(attrs) do
    with {:ok, addresses} <- fetch_addresses(attrs),
         {:ok, scopes} <- fetch_scopes(attrs),
         {:ok, budget} <- fetch_budget(attrs),
         {:ok, nonce} <- fetch_or_generate_nonce(attrs) do
      {human, agent} = addresses

      {:ok,
       [
         human_wallet: String.downcase(human),
         agent_wallet: String.downcase(agent),
         scopes: scopes,
         max_amount_usd: budget.max_amount_usd,
         max_calls: budget.max_calls,
         expires_at: budget.expires_at,
         nonce: nonce,
         signature: nil,
         envelope_hash: nil,
         created_at: System.system_time(:millisecond)
       ]}
    end
  end

  defp fetch_addresses(attrs) do
    with {:ok, human} <- fetch_address(attrs, :human_wallet),
         {:ok, agent} <- fetch_address(attrs, :agent_wallet) do
      {:ok, {human, agent}}
    end
  end

  defp fetch_budget(attrs) do
    with {:ok, max_amount_usd} <- fetch_non_neg_int(attrs, :max_amount_usd),
         {:ok, max_calls} <- fetch_pos_int(attrs, :max_calls),
         {:ok, expires_at} <- fetch_pos_int(attrs, :expires_at) do
      {:ok, %{max_amount_usd: max_amount_usd, max_calls: max_calls, expires_at: expires_at}}
    end
  end

  @doc """
  Return the EIP-712 typed-data tuple `{domain, types, message}` for a
  Mandate. Matches viem's `buildMandateEip712Data` output.

  Intended for inspection or external signing; `sign/2` does not call
  this -- it computes the digest directly because the `string[]` field
  needs array-aware encoding that `Raxol.Payments.EIP712` does not
  provide.
  """
  @spec typed_data(t()) :: {map(), map(), map()}
  def typed_data(%__MODULE__{} = m) do
    domain = %{
      name: @domain_name,
      version: @domain_version,
      chainId: @domain_chain_id,
      verifyingContract: @zero_address
    }

    types = %{
      "Mandate" => [
        {"human_wallet", "address"},
        {"agent_wallet", "address"},
        {"scopes", "string[]"},
        {"max_amount_usd", "uint256"},
        {"max_calls", "uint256"},
        {"expires_at", "uint256"},
        {"nonce", "bytes32"}
      ]
    }

    message = %{
      "human_wallet" => m.human_wallet,
      "agent_wallet" => m.agent_wallet,
      "scopes" => m.scopes,
      "max_amount_usd" => m.max_amount_usd,
      "max_calls" => m.max_calls,
      "expires_at" => m.expires_at,
      "nonce" => m.nonce
    }

    {domain, types, message}
  end

  @doc """
  Compute the EIP-712 digest of a Mandate message.

  Implements the standard EIP-712 sequence:

      keccak256(0x19 || 0x01 || domainSeparator || hashStruct(message))

  where `hashStruct` for `Mandate` encodes the `string[]` scopes field
  as `keccak256(concat(keccak256(s_i) for s_i in scopes))` per EIP-712
  array rules. The existing `Raxol.Payments.EIP712` module only handles
  scalar types, which is why this is computed locally.
  """
  @spec digest(t()) :: {:ok, <<_::256>>} | {:error, term()}
  def digest(%__MODULE__{} = m) do
    with {:ok, human_bytes} <- decode_address(m.human_wallet),
         {:ok, agent_bytes} <- decode_address(m.agent_wallet),
         {:ok, nonce_bytes} <- decode_bytes32(m.nonce) do
      type_hash = ExKeccak.hash_256(@mandate_type_string)
      scopes_hash = hash_string_array(m.scopes)

      struct_data =
        <<type_hash::binary, pad_left(human_bytes, 32)::binary, pad_left(agent_bytes, 32)::binary,
          scopes_hash::binary, m.max_amount_usd::unsigned-big-256, m.max_calls::unsigned-big-256,
          m.expires_at::unsigned-big-256, nonce_bytes::binary>>

      struct_hash = ExKeccak.hash_256(struct_data)
      domain_separator = compute_domain_separator()

      {:ok, ExKeccak.hash_256(<<0x19, 0x01, domain_separator::binary, struct_hash::binary>>)}
    end
  end

  @doc """
  Sign a Mandate with the given wallet module.

  The wallet must implement `Raxol.Payments.Wallet`. Sets
  `:signature` and `:envelope_hash` on the returned struct. The
  `:signature` is the 0x-prefixed 65-byte hex form expected by Xochi's
  Zod schema; `:envelope_hash` is `keccak256(envelope_json)`, the same
  key Xochi uses in KV for budget counters.
  """
  @spec sign(t(), module()) :: {:ok, t()} | {:error, term()}
  def sign(%__MODULE__{} = m, wallet_mod) when is_atom(wallet_mod) do
    with {:ok, digest_bytes} <- digest(m),
         {:ok, sig_bytes} <- wallet_mod.sign_hash(digest_bytes) do
      signed = %{m | signature: encode_hex_sig(sig_bytes)}
      {:ok, %{signed | envelope_hash: compute_envelope_hash(signed)}}
    end
  end

  @doc """
  Verify a signed Mandate.

  Recovers the signer's address from the signature and compares to
  `:human_wallet`. Returns `:ok` on match or `{:error, reason}`. A
  mutated field changes the digest, which changes the recovered
  signer -- so tamper detection falls out of this check.
  """
  @spec verify(t()) ::
          :ok | {:error, :unsigned | :invalid_signature | :unauthorized_signer}
  def verify(%__MODULE__{signature: nil}), do: {:error, :unsigned}

  def verify(%__MODULE__{} = m) do
    case recover_signer(m) do
      {:ok, recovered} -> compare_signer(recovered, m.human_wallet)
      {:error, reason} -> classify_verify_error(reason)
    end
  end

  defp recover_signer(%__MODULE__{} = m) do
    with {:ok, digest_bytes} <- digest(m),
         {:ok, {r, s, v}} <- decode_signature(m.signature),
         {:ok, pubkey} <- ExSecp256k1.recover(digest_bytes, r, s, v) do
      {:ok, derive_address(pubkey)}
    end
  end

  defp compare_signer(recovered, expected) do
    if String.downcase(recovered) == String.downcase(expected),
      do: :ok,
      else: {:error, :unauthorized_signer}
  end

  defp classify_verify_error(:invalid_signature_hex), do: {:error, :invalid_signature}
  defp classify_verify_error(:invalid_signature_format), do: {:error, :invalid_signature}
  defp classify_verify_error(_), do: {:error, :unauthorized_signer}

  @doc """
  Encode a signed Mandate as a base64url envelope suitable for the
  `X-Xochi-Delegation` header.
  """
  @spec to_envelope(t()) :: {:ok, String.t()} | {:error, :unsigned}
  def to_envelope(%__MODULE__{signature: nil}), do: {:error, :unsigned}

  def to_envelope(%__MODULE__{} = m) do
    {:ok, Base.url_encode64(envelope_json(m), padding: false)}
  end

  @doc """
  Decode a base64url envelope back into a Mandate struct. Does not
  verify the signature; call `verify/1` separately if needed.
  """
  @spec from_envelope(String.t()) :: {:ok, t()} | {:error, term()}
  def from_envelope(b64) when is_binary(b64) do
    with {:ok, json} <- Base.url_decode64(b64, padding: false),
         {:ok, %{"message" => msg, "signature" => sig}} <- Jason.decode(json),
         {:ok, m} <- build(message_to_attrs(msg)) do
      signed = %{m | signature: sig}
      {:ok, %{signed | envelope_hash: compute_envelope_hash(signed)}}
    else
      :error -> {:error, :invalid_base64url}
      {:ok, _} -> {:error, :missing_envelope_fields}
      err -> err
    end
  end

  @doc """
  Compute `H(envelope) = keccak256(canonical_envelope_json)`. Matches
  the key Xochi uses in KV for per-envelope budget counters.
  """
  @spec compute_envelope_hash(t()) :: <<_::256>>
  def compute_envelope_hash(%__MODULE__{} = m), do: ExKeccak.hash_256(envelope_json(m))

  @doc "Return true when the Mandate has passed its `expires_at`."
  @spec expired?(t(), integer() | nil) :: boolean()
  def expired?(%__MODULE__{} = m, now \\ nil) do
    now = now || System.system_time(:second)
    now >= m.expires_at
  end

  @doc "Return true when the Mandate's scopes include the given scope."
  @spec covers_scope?(t(), scope()) :: boolean()
  def covers_scope?(%__MODULE__{scopes: scopes}, scope) when is_binary(scope),
    do: scope in scopes

  @doc "List the scopes Xochi recognizes."
  @spec allowed_scopes() :: [scope()]
  def allowed_scopes, do: @allowed_scopes

  # -- Private: validation --

  defp fetch_address(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      nil ->
        {:error, {:missing_field, key}}

      value when is_binary(value) ->
        if Regex.match?(~r/^0x[a-fA-F0-9]{40}$/, value),
          do: {:ok, value},
          else: {:error, {:invalid_address, key}}

      _ ->
        {:error, {:invalid_address, key}}
    end
  end

  defp fetch_scopes(attrs) do
    case Map.get(attrs, :scopes) || Map.get(attrs, "scopes") do
      nil ->
        {:error, {:missing_field, :scopes}}

      [] ->
        {:error, {:invalid_scopes, :empty}}

      scopes when is_list(scopes) ->
        validate_scopes(scopes)

      _ ->
        {:error, {:invalid_scopes, :not_a_list}}
    end
  end

  defp validate_scopes(scopes) do
    all_strings = Enum.all?(scopes, &is_binary/1)
    all_known = Enum.all?(scopes, &(&1 in @allowed_scopes))
    unique = length(scopes) == scopes |> Enum.uniq() |> length()

    cond do
      not all_strings -> {:error, {:invalid_scopes, :non_string_element}}
      not all_known -> {:error, {:invalid_scopes, :unknown_scope}}
      not unique -> {:error, {:invalid_scopes, :duplicate}}
      true -> {:ok, scopes}
    end
  end

  defp fetch_non_neg_int(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      nil -> {:error, {:missing_field, key}}
      _ -> {:error, {:invalid_integer, key}}
    end
  end

  defp fetch_pos_int(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      nil -> {:error, {:missing_field, key}}
      _ -> {:error, {:invalid_integer, key}}
    end
  end

  defp fetch_or_generate_nonce(attrs) do
    case Map.get(attrs, :nonce) || Map.get(attrs, "nonce") do
      nil ->
        {:ok, "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)}

      value when is_binary(value) ->
        if Regex.match?(~r/^0x[a-fA-F0-9]{64}$/, value),
          do: {:ok, String.downcase(value)},
          else: {:error, {:invalid_nonce, :shape}}

      _ ->
        {:error, {:invalid_nonce, :type}}
    end
  end

  defp message_to_attrs(%{} = msg) do
    %{
      human_wallet: Map.get(msg, "human_wallet"),
      agent_wallet: Map.get(msg, "agent_wallet"),
      scopes: Map.get(msg, "scopes"),
      max_amount_usd: Map.get(msg, "max_amount_usd"),
      max_calls: Map.get(msg, "max_calls"),
      expires_at: Map.get(msg, "expires_at"),
      nonce: Map.get(msg, "nonce")
    }
  end

  # -- Private: EIP-712 --

  defp compute_domain_separator do
    domain_type_hash = ExKeccak.hash_256(@domain_type_string)
    name_hash = ExKeccak.hash_256(@domain_name)
    version_hash = ExKeccak.hash_256(@domain_version)
    {:ok, contract_bytes} = decode_address(@zero_address)

    data =
      <<domain_type_hash::binary, name_hash::binary, version_hash::binary,
        @domain_chain_id::unsigned-big-256, pad_left(contract_bytes, 32)::binary>>

    ExKeccak.hash_256(data)
  end

  defp hash_string_array(scopes) do
    inner = Enum.map_join(scopes, "", &ExKeccak.hash_256/1)
    ExKeccak.hash_256(inner)
  end

  defp decode_address("0x" <> hex) when byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_address_hex}
    end
  end

  defp decode_address(_), do: {:error, :invalid_address_format}

  defp decode_bytes32("0x" <> hex) when byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_bytes32_hex}
    end
  end

  defp decode_bytes32(_), do: {:error, :invalid_bytes32_format}

  defp pad_left(bytes, size) when byte_size(bytes) <= size do
    padding = size - byte_size(bytes)
    <<0::size(padding * 8), bytes::binary>>
  end

  defp pad_left(bytes, size), do: binary_part(bytes, byte_size(bytes) - size, size)

  # -- Private: signature --

  defp encode_hex_sig(<<_::binary-size(65)>> = sig) do
    "0x" <> Base.encode16(sig, case: :lower)
  end

  defp decode_signature("0x" <> hex) when byte_size(hex) == 130 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<r::binary-size(32), s::binary-size(32), v::8>>} ->
        # ExSecp256k1.recover expects v in [0, 1] (recovery id), not [27, 28].
        recovery_id = if v >= 27, do: v - 27, else: v
        {:ok, {r, s, recovery_id}}

      _ ->
        {:error, :invalid_signature_hex}
    end
  end

  defp decode_signature(_), do: {:error, :invalid_signature_format}

  defp derive_address(<<0x04, rest::binary>>), do: derive_address(rest)

  defp derive_address(pubkey_bytes) do
    hash = ExKeccak.hash_256(pubkey_bytes)
    <<_::binary-size(12), address::binary-size(20)>> = hash
    "0x" <> Base.encode16(address, case: :lower)
  end

  # -- Private: envelope JSON canonicalization --

  # Canonical JSON: fixed field order matching the viem-side struct so
  # `H(envelope)` agrees across implementations. Jason.encode! preserves
  # insertion order for keyword-list-like inputs; using a list of pairs
  # locks it in.
  defp envelope_json(%__MODULE__{} = m) do
    message =
      Jason.OrderedObject.new([
        {"human_wallet", m.human_wallet},
        {"agent_wallet", m.agent_wallet},
        {"scopes", m.scopes},
        {"max_amount_usd", m.max_amount_usd},
        {"max_calls", m.max_calls},
        {"expires_at", m.expires_at},
        {"nonce", m.nonce}
      ])

    Jason.encode!(
      Jason.OrderedObject.new([
        {"message", message},
        {"signature", m.signature}
      ])
    )
  end
end
