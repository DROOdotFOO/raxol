defmodule Raxol.AgentClientProtocol.Ext.Capability.Token do
  @moduledoc """
  The `RXC1` capability token — offline-verifiable detached Ed25519 signature
  (`acp-attachpolicy-design.md` §4).

  The headline capability: an attach to a **writerless** session (a tar'd journal
  directory, no live authority, no network, no issuer reachable) is authorized
  cryptographically from the token bytes + a shipped public key ALONE.

  ## Encoding (§4.2) — version-pinned, no `alg` field anywhere

  ```
  token         := "RXC1." <> b64url_nopad(claims_json) <> "." <> b64url_nopad(sig)
  signing_input := "RXC1." <> b64url_nopad(claims_json)      # prefix INCLUDED in signed bytes
  sig           := Ed25519-sign(issuer_priv, signing_input)  # 64 bytes, detached
  ```

  Design rulings, each load-bearing:

    * **No header, no `alg`.** The literal prefix `RXC1` *is* the algorithm
      binding (`RXC1 ⟺ Ed25519`). The JWT `alg:none` / RS256→HS256 confusion is
      structurally UNEXPRESSIBLE — no code path reads an algorithm name (`INV-AP7`).
    * **The prefix is inside the signed bytes**, so a signature minted for a
      hypothetical `RXC2` can never be replayed under `RXC1` (downgrade, A4).
    * **The signature covers the encoded blob, not re-canonicalized JSON.** The
      verifier base64url-decodes and JSON-*decodes* but NEVER re-encodes — there
      is no canonicalization step, hence no malleability class (key ordering,
      unicode escaping, duplicate keys are all bound by the signed bytes).
    * **Strict base64url, `padding: false`.** Any `=`/`+`/`/`/whitespace/
      non-alphabet byte ⇒ decode failure ⇒ deny. Exactly three dot-separated
      non-empty segments — one token has exactly one valid byte form.

  ## Verification is TOTAL (§4.4)

  `verify/4` is a **pure function**: same inputs ⇒ same output; no network, no
  process dictionary, no clock read (`now` is a parameter), no filesystem
  (`INV-AP4`). For ALL binaries it returns `{:ok, claims} | {:error, atom}` —
  never raises, never creates an atom (`INV-AP5`). Reason atoms are internal
  (telemetry only); the wire sees a single bare deny (anti-oracle).
  """

  # Ed25519 in :crypto requires OTP >= 24 built against a capable OpenSSL. Fail
  # LOUDLY at compile time rather than at verify time (design §8).
  unless :ed25519 in :crypto.supports(:curves) do
    raise "Ed25519 unavailable in :crypto (OTP>=24 w/ capable OpenSSL required); " <>
            "RXC1 capability tokens cannot be verified on this build"
  end

  @max_token_bytes 4_096
  # year-2100 ceiling — reject out-of-range / bignum iat|exp before any arithmetic.
  @max_unix_s 4_102_444_800
  # skew applied to `iat` ONLY (§5.3); `exp` is strict (§5.1). Deliberate asymmetry.
  @clock_skew_s 60

  # Restrictive claims NARROW access; they are enforce-if-present [G5:S23].
  # A restrictive claim the verifier does not implement DENIES (never
  # admitted-by-ignoring — the JWT `crit`-ignored footgun). Informational claims
  # (e.g. `jti`) are safely ignored in v1.
  @restrictive_implemented ["surf"]
  @restrictive_reserved ["min_offset"]

  @typedoc "Verifier keyring: kid (binary) → 32-byte Ed25519 public key."
  @type keyring :: %{optional(String.t()) => binary()}

  @doc "The `iat` clock-skew tolerance (seconds). `exp` has none."
  @spec clock_skew_s() :: non_neg_integer()
  def clock_skew_s, do: @clock_skew_s

  @doc """
  Verify a token against a keyring, wall-clock `now` (unix seconds), and the
  expected session id. Total: every failure is `{:error, atom}`, never a raise.
  """
  @spec verify(term(), keyring(), integer(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def verify(token, keyring, now_unix, expected_session_id)
      when is_map(keyring) and is_integer(now_unix) and
             is_binary(expected_session_id) do
    with :ok <- v1_size(token),
         {:ok, claims_b64, sig_b64} <- v2_split(token),
         {:ok, sig} <- v3_sig(sig_b64),
         {:ok, claims_json} <- v4_claims_bytes(claims_b64),
         signing_input = "RXC1." <> claims_b64,
         {:ok, claims, kid} <- v6_json(claims_json),
         {:ok, pub} <- v7_key(keyring, kid),
         :ok <- v8_verify(signing_input, sig, pub),
         :ok <- v9_structure(claims),
         :ok <- v10_session(claims, expected_session_id),
         :ok <- v11_expiry(claims, now_unix),
         :ok <- v12_iat(claims, now_unix),
         :ok <- v12a_restrictive(claims) do
      {:ok, claims}
    end
  end

  def verify(_token, _keyring, _now, _sid), do: {:error, :malformed}

  # V1: size cap BEFORE any parsing — no parse amplification on garbage input.
  @spec v1_size(term()) :: :ok | {:error, :malformed}
  defp v1_size(t) when is_binary(t) and byte_size(t) <= @max_token_bytes, do: :ok
  defp v1_size(_), do: {:error, :malformed}

  # V2: exactly ["RXC1", claims_b64, sig_b64], all non-empty. Any other prefix
  # ("RXC2", a JWT "eyJ…", "none", "") lands here — the alg-pin arm.
  @spec v2_split(binary()) :: {:ok, binary(), binary()} | {:error, :malformed}
  defp v2_split(token) do
    case String.split(token, ".") do
      ["RXC1", c, s] when c != "" and s != "" -> {:ok, c, s}
      _ -> {:error, :malformed}
    end
  end

  # V3: strict b64url decode; signature is exactly 64 bytes.
  @spec v3_sig(binary()) :: {:ok, binary()} | {:error, :malformed}
  defp v3_sig(sig_b64) do
    case strict_b64(sig_b64) do
      {:ok, sig} when byte_size(sig) == 64 -> {:ok, sig}
      _ -> {:error, :malformed}
    end
  end

  # V4: strict b64url decode of the claims blob.
  @spec v4_claims_bytes(binary()) :: {:ok, binary()} | {:error, :malformed}
  defp v4_claims_bytes(claims_b64) do
    case strict_b64(claims_b64) do
      {:ok, json} -> {:ok, json}
      :error -> {:error, :malformed}
    end
  end

  # CANONICAL base64url decode — enforces ONE byte form (INV-AP6, §4.2 ruling 4).
  # `Base.url_decode64(padding: false)` accepts non-zero unused bits in the final
  # character (e.g. a 64-byte value's last char carries 4 unused bits ⇒ 16
  # accepted encodings of one signature). Re-encoding the decoded bytes and
  # demanding byte-equality with the input rejects every non-canonical form, so a
  # single-bit flip anywhere — including those unused bits — is a decode failure.
  @spec strict_b64(term()) :: {:ok, binary()} | :error
  defp strict_b64(seg) when is_binary(seg) do
    case Base.url_decode64(seg, padding: false) do
      {:ok, bin} ->
        if Base.url_encode64(bin, padding: false) == seg, do: {:ok, bin}, else: :error

      :error ->
        :error
    end
  end

  defp strict_b64(_), do: :error

  # V6: decode JSON (the ONLY rescue in the module, scoped to the decoder), peek
  # kid. NOTHING is trusted until V8 passes; a lying kid merely selects a key the
  # signature then fails against. No atom is ever created from token input.
  @spec v6_json(binary()) :: {:ok, map(), binary()} | {:error, :malformed}
  defp v6_json(json) do
    case safe_decode(json) do
      {:ok, claims} when is_map(claims) ->
        case Map.get(claims, "kid") do
          kid when is_binary(kid) and kid != "" -> {:ok, claims, kid}
          _ -> {:error, :malformed}
        end

      _ ->
        {:error, :malformed}
    end
  end

  @spec safe_decode(binary()) :: {:ok, term()} | {:error, term()}
  defp safe_decode(json) do
    Jason.decode(json)
  rescue
    _ -> {:error, :malformed}
  end

  # V7: select the verifying key by kid; unknown kid denies.
  @spec v7_key(keyring(), binary()) :: {:ok, binary()} | {:error, :unknown_kid}
  defp v7_key(keyring, kid) do
    case Map.fetch(keyring, kid) do
      {:ok, pub} when is_binary(pub) and byte_size(pub) == 32 -> {:ok, pub}
      _ -> {:error, :unknown_kid}
    end
  end

  # V8: the signature gate. Everything below operates on AUTHENTICATED claims.
  @spec v8_verify(binary(), binary(), binary()) :: :ok | {:error, :sig_invalid}
  defp v8_verify(signing_input, sig, pub) do
    if crypto_verify(signing_input, sig, pub),
      do: :ok,
      else: {:error, :sig_invalid}
  end

  @spec crypto_verify(binary(), binary(), binary()) :: boolean()
  defp crypto_verify(signing_input, sig, pub) do
    :crypto.verify(:eddsa, :none, signing_input, sig, [pub, :ed25519])
  rescue
    _ -> false
  end

  # V9: structural + numeric-range check on authenticated claims.
  @spec v9_structure(map()) :: :ok | {:error, :claims_invalid}
  defp v9_structure(claims) do
    sid = Map.get(claims, "sid")
    act = Map.get(claims, "act")
    iat = Map.get(claims, "iat")
    exp = Map.get(claims, "exp")

    if is_binary(sid) and is_map(act) and is_integer(iat) and is_integer(exp) and
         iat > 0 and exp > iat and exp <= @max_unix_s do
      :ok
    else
      {:error, :claims_invalid}
    end
  end

  # V10: session binding, plain binary == (byte-exact, both sides attacker-known).
  @spec v10_session(map(), String.t()) :: :ok | {:error, :session_mismatch}
  defp v10_session(claims, expected) do
    if Map.get(claims, "sid") == expected,
      do: :ok,
      else: {:error, :session_mismatch}
  end

  # V11: expiry, STRICT `now < exp`, zero verifier-side grace (issuer owns margin).
  @spec v11_expiry(map(), integer()) :: :ok | {:error, :expired}
  defp v11_expiry(claims, now) do
    if now < Map.get(claims, "exp"), do: :ok, else: {:error, :expired}
  end

  # V12: issued-at, `iat <= now + skew` (skew on iat only).
  @spec v12_iat(map(), integer()) :: :ok | {:error, :issued_in_future}
  defp v12_iat(claims, now) do
    if Map.get(claims, "iat") <= now + @clock_skew_s,
      do: :ok,
      else: {:error, :issued_in_future}
  end

  # V12a: restrictive-claim gate [G5:S23]. A present-but-unimplemented restrictive
  # claim denies; a present `surf` must be a JSON array of strings (shape only —
  # membership vs ctx.surface is enforced by the Token policy which holds surface).
  @spec v12a_restrictive(map()) ::
          :ok | {:error, :unsupported_restrictive_claim | :claims_invalid}
  defp v12a_restrictive(claims) do
    cond do
      Enum.any?(@restrictive_reserved, &Map.has_key?(claims, &1)) ->
        {:error, :unsupported_restrictive_claim}

      Map.has_key?(claims, "surf") and not valid_surf?(Map.get(claims, "surf")) ->
        {:error, :claims_invalid}

      true ->
        :ok
    end
  end

  @spec valid_surf?(term()) :: boolean()
  defp valid_surf?(surf) when is_list(surf), do: Enum.all?(surf, &is_binary/1)
  defp valid_surf?(_), do: false

  @doc "The restrictive claim keys this verifier IMPLEMENTS (enforce-if-present)."
  @spec restrictive_implemented() :: [String.t()]
  def restrictive_implemented, do: @restrictive_implemented
end

defmodule Raxol.AgentClientProtocol.Ext.Capability.Keyring do
  @moduledoc """
  Verifier-side keyring load + validation (`acp-attachpolicy-design.md` §6.1).

  ```
  config :raxol_agent_client_protocol,
    attach_keyring: %{
      "k1" => {:hex, "<64 hex chars>"},        # 32-byte Ed25519 public key
      "k2" => {:file, "/etc/raxol/k2.pub"},    # raw-32-bytes or hex file
      "k3" => {:raw, <<...32 bytes...>>}
    }
  ```

  **Validates at load**: every value must normalize to exactly 32 bytes or the
  keyring REFUSES to load (fail at boot, loudly — never a half-usable ring at
  verify time).

  **HARD RULE (A6, `INV-AP11`):** the keyring comes from the VERIFIER's own
  configuration ONLY. It is NEVER read from inside an attached artifact — a
  `keyring.json` shipped in a tar'd session dir is untrusted data; loading it
  would let whoever produced the tar mint their own admission. Rotation is
  grow-only: ADD a kid to rotate; REMOVE a kid to revoke every token under it.
  """

  @doc "Load + normalize the configured keyring to `%{kid => 32-byte pubkey}`."
  @spec load() :: %{optional(String.t()) => binary()}
  def load do
    :raxol_agent_client_protocol
    |> Application.get_env(:attach_keyring, %{})
    |> normalize()
  end

  @doc "Normalize a raw keyring map, raising on any non-32-byte key."
  @spec normalize(map()) :: %{optional(String.t()) => binary()}
  def normalize(raw) when is_map(raw) do
    Map.new(raw, fn {kid, spec} -> {kid, normalize_key!(kid, spec)} end)
  end

  @spec normalize_key!(String.t(), term()) :: binary()
  defp normalize_key!(kid, spec) do
    key =
      case spec do
        {:hex, hex} -> from_hex!(kid, hex)
        {:raw, bin} when is_binary(bin) -> bin
        {:file, path} -> from_file!(kid, path)
        bin when is_binary(bin) and byte_size(bin) == 32 -> bin
        other -> bad!(kid, "unrecognized key spec #{inspect(other)}")
      end

    if byte_size(key) == 32,
      do: key,
      else: bad!(kid, "key must be 32 bytes, got #{byte_size(key)}")
  end

  @spec from_hex!(String.t(), binary()) :: binary()
  defp from_hex!(kid, hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> bin
      :error -> bad!(kid, "invalid hex key material")
    end
  end

  defp from_hex!(kid, _), do: bad!(kid, "hex key material must be a string")

  # A key file holds either a raw 32-byte key or a hex string of it.
  @spec from_file!(String.t(), binary()) :: binary()
  defp from_file!(kid, path) do
    case File.read(path) do
      {:ok, <<bin::binary-size(32)>>} ->
        bin

      {:ok, contents} ->
        from_hex!(kid, String.trim(contents))

      {:error, reason} ->
        bad!(kid, "cannot read key file #{inspect(path)}: #{inspect(reason)}")
    end
  end

  @spec bad!(String.t(), String.t()) :: no_return()
  defp bad!(kid, msg) do
    raise ArgumentError, "attach_keyring[#{inspect(kid)}]: #{msg}"
  end
end

defmodule Raxol.AgentClientProtocol.Ext.Capability.Issuer do
  @moduledoc """
  The signing side (`acp-attachpolicy-design.md` §6.3). Mints `RXC1` tokens.

  **NEVER invoked on any verify path** — `Capability.Token`, `AttachPolicy.Token`
  and `Runner` have zero reference to this module or to any private-key source
  (`INV-AP12`, grep/xref-verifiable). The private key never lives in the verifier.

  Issuance defaults are ENFORCED, not merely recommended `[G5:S6]`: an interactive
  attach token is capped at TTL **1 hour**; a longer TTL (up to **30 days**)
  requires an explicit `archival: true` opt-in. A 30-day token is a deliberate
  operator choice (the expiry bounds an archive's protocol-readability window),
  never an accidental default.
  """

  @interactive_ttl_s 3_600
  @archival_ttl_s 2_592_000

  @typedoc "A private-key source. Raw binary is a 32-byte Ed25519 seed."
  @type privkey_source ::
          binary()
          | {:env, String.t()}
          | {:file, String.t()}
          | {:fun, (-> binary())}
          | {:raw, binary()}

  @doc "Generate a fresh `{public_key, private_seed}` Ed25519 keypair."
  @spec generate_keypair() :: {binary(), binary()}
  def generate_keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  @doc """
  Sign `claims` under `kid`. `claims` MUST carry integer `iat`/`exp`
  (`exp > iat`). Enforces the TTL cap (`archival: true` opt-in for up to 30 days).

  Returns `{:ok, token}` — the `RXC1` string — or `{:error, reason}`.
  """
  @spec sign(map(), String.t(), privkey_source(), keyword()) ::
          {:ok, binary()} | {:error, atom()}
  def sign(claims, kid, privkey_source, opts \\ [])
      when is_map(claims) and is_binary(kid) do
    with {:ok, priv} <- resolve_priv(privkey_source),
         {:ok, claims} <- put_kid(claims, kid),
         :ok <- check_ttl(claims, opts) do
      encode(claims, priv)
    end
  end

  @spec put_kid(map(), String.t()) :: {:ok, map()}
  defp put_kid(claims, kid), do: {:ok, Map.put(claims, "kid", kid)}

  @spec check_ttl(map(), keyword()) :: :ok | {:error, atom()}
  defp check_ttl(claims, opts) do
    iat = Map.get(claims, "iat")
    exp = Map.get(claims, "exp")

    cond do
      not (is_integer(iat) and is_integer(exp) and exp > iat) ->
        {:error, :missing_or_invalid_lifetime}

      exp - iat > max_ttl(opts) ->
        {:error, :ttl_too_long}

      true ->
        :ok
    end
  end

  @spec max_ttl(keyword()) :: pos_integer()
  defp max_ttl(opts) do
    base = if Keyword.get(opts, :archival, false), do: @archival_ttl_s, else: @interactive_ttl_s
    Keyword.get(opts, :max_ttl, base)
  end

  @spec encode(map(), binary()) :: {:ok, binary()} | {:error, atom()}
  defp encode(claims, priv) do
    with {:ok, json} <- safe_json(claims) do
      claims_b64 = Base.url_encode64(json, padding: false)
      signing_input = "RXC1." <> claims_b64
      sig = :crypto.sign(:eddsa, :none, signing_input, [priv, :ed25519])
      sig_b64 = Base.url_encode64(sig, padding: false)
      {:ok, signing_input <> "." <> sig_b64}
    end
  rescue
    _ -> {:error, :sign_failed}
  end

  @spec safe_json(map()) :: {:ok, binary()} | {:error, :encode_failed}
  defp safe_json(claims) do
    case Jason.encode(claims) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :encode_failed}
    end
  end

  # `{:hex_or_raw, binary()}` is an internal-only dispatch tag (not part of
  # the public `privkey_source()` union) that every other clause recurses
  # into once it has resolved its source down to a raw/hex binary.
  @spec resolve_priv(privkey_source() | {:hex_or_raw, binary()}) ::
          {:ok, binary()} | {:error, atom()}
  defp resolve_priv({:env, var}) when is_binary(var) do
    case System.get_env(var) do
      nil -> {:error, :privkey_env_missing}
      val -> resolve_priv({:hex_or_raw, val})
    end
  end

  defp resolve_priv({:file, path}) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> resolve_priv({:hex_or_raw, String.trim(contents)})
      {:error, _} -> {:error, :privkey_file_missing}
    end
  end

  defp resolve_priv({:fun, fun}) when is_function(fun, 0),
    do: resolve_priv({:hex_or_raw, fun.()})

  defp resolve_priv({:raw, bin}) when is_binary(bin), do: ok_seed(bin)
  defp resolve_priv(bin) when is_binary(bin), do: ok_seed(bin)

  defp resolve_priv({:hex_or_raw, <<seed::binary-size(32)>>}), do: {:ok, seed}

  defp resolve_priv({:hex_or_raw, val}) when is_binary(val) do
    case Base.decode16(val, case: :mixed) do
      {:ok, <<seed::binary-size(32)>>} -> {:ok, seed}
      _ -> {:error, :privkey_invalid}
    end
  end

  defp resolve_priv(_), do: {:error, :privkey_invalid}

  @spec ok_seed(binary()) :: {:ok, binary()} | {:error, :privkey_invalid}
  defp ok_seed(<<seed::binary-size(32)>>), do: {:ok, seed}
  defp ok_seed(bin) when is_binary(bin), do: resolve_priv({:hex_or_raw, bin})
end

defmodule Raxol.AgentClientProtocol.Ext.AttachPolicy.Token do
  @moduledoc """
  The capability-token attach policy (`acp-attachpolicy-design.md` §3.4).

  Deny-by-default for anonymous attach: a tokenless attach denies
  (`:token_required`, the A4 downgrade arm) BEFORE any verify runs. A present
  token is verified offline (one `Capability.Token.verify/4`), then the actor and
  surface bindings are checked:

    * **actor** — the signed `act` claim is the grant identity. If `ctx.actor` is
      asserted and its `"id"` differs from the token's, deny `:actor_mismatch`
      (OQ-4 ruling: keep the deny — fail-closed).
    * **surface** `[G5:S23]` — if the token carries `surf` (a list of surface
      strings), `ctx.surface` (an atom, Connection-sourced) MUST be a member,
      else `:surface_not_allowed`. Absent `surf` ⇒ broad (v1 back-compat).

  `now` is **server-sourced** (`System.os_time(:second)` read here), never peer
  input (`INV-AP20 [G5:S8]`). `ctx.transport` is ignored (a token gates the
  protocol path regardless of transport). The policy consults NO live state, so
  its decision is identical with and without a live Writer (`INV-AP13`).
  """

  @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy

  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Grant
  alias Raxol.AgentClientProtocol.Ext.Capability.Keyring
  alias Raxol.AgentClientProtocol.Ext.Capability.Token, as: CapToken

  @impl true
  @spec authorize_attach(map()) :: {:ok, Grant.t()} | {:error, atom()}
  def authorize_attach(%{capability: nil}), do: {:error, :token_required}

  def authorize_attach(%{capability: capability, session_id: session_id} = ctx) do
    case CapToken.verify(capability, Keyring.load(), now(), session_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, claims} ->
        with :ok <- actor_check(Map.get(claims, "act"), Map.get(ctx, :actor)),
             :ok <- surf_check(Map.get(claims, "surf"), Map.get(ctx, :surface)) do
          {:ok,
           %Grant{
             actor: Map.get(claims, "act"),
             scope: :attach,
             session_id: session_id,
             via: {:token, Map.get(claims, "kid")},
             expires_at: Map.get(claims, "exp"),
             lens: nil
           }}
        end
    end
  end

  def authorize_attach(_ctx), do: {:error, :token_required}

  # Server-sourced wall clock (unix seconds). NEVER derived from peer input.
  @spec now() :: integer()
  defp now, do: System.os_time(:second)

  # A nil ctx.actor ⇒ token is sole identity. Both present with differing "id" ⇒
  # deny (a client claiming Alice while bearing Bob's token is suspicious).
  @spec actor_check(term(), term()) :: :ok | {:error, :actor_mismatch}
  defp actor_check(_token_act, nil), do: :ok

  defp actor_check(token_act, ctx_actor)
       when is_map(token_act) and is_map(ctx_actor) do
    case {Map.get(token_act, "id"), Map.get(ctx_actor, "id")} do
      {a, b} when is_binary(a) and is_binary(b) and a != b ->
        {:error, :actor_mismatch}

      _ ->
        :ok
    end
  end

  defp actor_check(_token_act, _ctx_actor), do: :ok

  # Enforce-if-present [G5:S23]: a surf-bearing token is bound to its surfaces.
  @spec surf_check(term(), term()) :: :ok | {:error, :surface_not_allowed}
  defp surf_check(nil, _surface), do: :ok

  defp surf_check(surf, surface) when is_list(surf) and is_atom(surface) do
    if Atom.to_string(surface) in surf,
      do: :ok,
      else: {:error, :surface_not_allowed}
  end

  defp surf_check(_surf, _surface), do: :ok
end
