defmodule Raxol.AgentClientProtocol.Ext.TokenTest do
  @moduledoc """
  The `RXC1` capability token (`acp-attachpolicy-design.md` §4) + the Token
  attach policy (§3.4).

  Covers: the Ed25519 known-answer vector (RFC 8032 Test 1, proving `:crypto` on
  this build), forgery (`INV-AP6`), expiry/iat boundaries (`INV-AP9`),
  malleability + strict base64url (`INV-AP6`), algorithm pinning /
  alg-confusion (`INV-AP7`), session binding (`INV-AP8`), key rotation, the
  keyring-provenance hard rule (`INV-AP11`), verify totality + no-atom fuzz
  (`INV-AP5`), offline purity (`INV-AP4`), and the policy-level actor / surface /
  restrictive-claim bindings (`INV-AP17`).
  """
  use ExUnit.Case, async: false

  import Bitwise

  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Grant
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Runner
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Token, as: TokenPolicy
  alias Raxol.AgentClientProtocol.Ext.Capability.Issuer
  alias Raxol.AgentClientProtocol.Ext.Capability.Keyring
  alias Raxol.AgentClientProtocol.Ext.Capability.Token, as: CapToken

  @sid "sess-07af"
  # A fixed injected clock so verify/4 stays a pure function (INV-AP4).
  @now 1_784_290_000
  @skew CapToken.clock_skew_s()

  setup do
    {pub, priv} = Issuer.generate_keypair()
    keyring = %{"k1" => pub}
    {:ok, pub: pub, priv: priv, keyring: keyring}
  end

  # -- low-level minting (exact-bytes control for malleability tests) ----------

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp raw_token(claims_json, priv) when is_binary(claims_json) do
    cb = b64(claims_json)
    signing_input = "RXC1." <> cb
    sig = :crypto.sign(:eddsa, :none, signing_input, [priv, :ed25519])
    signing_input <> "." <> b64(sig)
  end

  defp mint(claims, priv), do: raw_token(Jason.encode!(claims), priv)

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        "sid" => @sid,
        "act" => %{"id" => "v@local", "kind" => "user"},
        "iat" => @now - 100,
        "exp" => @now + 100,
        "kid" => "k1"
      },
      overrides
    )
  end

  # ==========================================================================
  # 1. Ed25519 known-answer vector — RFC 8032 §7.1 Test 1 (proves the primitive)
  # ==========================================================================

  test "Ed25519 KAT: RFC 8032 Test 1 verifies, tamper + wrong-msg reject" do
    pub =
      Base.decode16!(
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        case: :lower
      )

    sig =
      Base.decode16!(
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
        case: :lower
      )

    # Test 1 message is the empty string.
    assert :crypto.verify(:eddsa, :none, "", sig, [pub, :ed25519])
    # Wrong message rejects.
    refute :crypto.verify(:eddsa, :none, "x", sig, [pub, :ed25519])
    # Single-bit tamper of the signature rejects.
    tampered =
      :binary.part(sig, 0, 63) <> <<bxor(:binary.at(sig, 63), 1)>>

    refute :crypto.verify(:eddsa, :none, "", tampered, [pub, :ed25519])
  end

  # ==========================================================================
  # 2. Happy path + forgery / unknown-kid
  # ==========================================================================

  test "a valid token verifies to its claims", %{priv: priv, keyring: keyring} do
    token = mint(claims(), priv)
    assert {:ok, c} = CapToken.verify(token, keyring, @now, @sid)
    assert c["sid"] == @sid
    assert c["act"]["id"] == "v@local"
  end

  test "a signature from another key denies (T-9, INV-AP6)", %{keyring: keyring} do
    {_atk_pub, atk_priv} = Issuer.generate_keypair()
    # kid names OUR key, but the sig is the attacker's ⇒ V8 :sig_invalid.
    token = mint(claims(), atk_priv)
    assert {:error, :sig_invalid} = CapToken.verify(token, keyring, @now, @sid)
  end

  test "an unknown kid denies (T-10, INV-AP11)", %{priv: priv, keyring: keyring} do
    token = mint(claims(%{"kid" => "kEvil"}), priv)
    assert {:error, :unknown_kid} = CapToken.verify(token, keyring, @now, @sid)
  end

  test "keyring shipped inside the artifact is NOT trusted (T-16, INV-AP11)" do
    # The attacker self-issues: their own keypair, their own kid, and ships a
    # keyring next to the tar. The verifier uses ITS OWN keyring only — which
    # lacks the attacker's kid ⇒ deny.
    {atk_pub, atk_priv} = Issuer.generate_keypair()
    hostile_keyring = %{"kEvil" => atk_pub}
    token = mint(claims(%{"kid" => "kEvil"}), atk_priv)

    # If we (wrongly) loaded the artifact's keyring it would verify…
    assert {:ok, _} = CapToken.verify(token, hostile_keyring, @now, @sid)
    # …but against the verifier's own (empty) keyring it denies.
    assert {:error, :unknown_kid} = CapToken.verify(token, %{}, @now, @sid)
  end

  # ==========================================================================
  # 3. Temporal validity — exact boundaries (T-11, T-12, INV-AP9)
  # ==========================================================================

  test "expiry is strict: now == exp denies, now == exp-1 admits", %{
    priv: priv,
    keyring: keyring
  } do
    token = mint(claims(%{"iat" => @now - 10, "exp" => @now + 10}), priv)
    # now == exp
    assert {:error, :expired} = CapToken.verify(token, keyring, @now + 10, @sid)
    # now == exp - 1
    assert {:ok, _} = CapToken.verify(token, keyring, @now + 9, @sid)
  end

  test "issued-in-future beyond skew denies; at skew admits (T-12)", %{
    priv: priv,
    keyring: keyring
  } do
    # iat == now + skew  ⇒ admit; iat == now + skew + 1 ⇒ deny.
    ok = mint(claims(%{"iat" => @now + @skew, "exp" => @now + @skew + 100}), priv)
    assert {:ok, _} = CapToken.verify(ok, keyring, @now, @sid)

    bad =
      mint(claims(%{"iat" => @now + @skew + 1, "exp" => @now + @skew + 100}), priv)

    assert {:error, :issued_in_future} = CapToken.verify(bad, keyring, @now, @sid)
  end

  test "degenerate lifetime exp <= iat denies (:claims_invalid)", %{
    priv: priv,
    keyring: keyring
  } do
    token = mint(claims(%{"iat" => @now, "exp" => @now}), priv)
    assert {:error, :claims_invalid} = CapToken.verify(token, keyring, @now, @sid)
  end

  test "numeric range: bignum / out-of-range / non-positive iat|exp deny", %{
    priv: priv,
    keyring: keyring
  } do
    big = mint(claims(%{"exp" => 999_999_999_999_999_999}), priv)
    assert {:error, :claims_invalid} = CapToken.verify(big, keyring, @now, @sid)

    nonpos = mint(claims(%{"iat" => 0, "exp" => 100}), priv)
    assert {:error, :claims_invalid} = CapToken.verify(nonpos, keyring, @now, @sid)
  end

  test "wrong claim JSON types deny (:claims_invalid)", %{
    priv: priv,
    keyring: keyring
  } do
    for bad <- [
          %{"iat" => "soon"},
          %{"exp" => "later"},
          %{"act" => "not-a-map"},
          %{"sid" => 42}
        ] do
      token = mint(claims(bad), priv)
      assert {:error, _} = CapToken.verify(token, keyring, @now, @sid)
    end
  end

  # ==========================================================================
  # 4. Malleability + strict base64url (T-13, INV-AP6)
  # ==========================================================================

  test "any single-bit flip anywhere in a valid token denies (INV-AP6)", %{
    priv: priv,
    keyring: keyring
  } do
    token = mint(claims(), priv)
    assert {:ok, _} = CapToken.verify(token, keyring, @now, @sid)

    bits = byte_size(token) * 8

    Enum.each(0..(bits - 1), fn i ->
      flipped = flip_bit(token, i)

      case CapToken.verify(flipped, keyring, @now, @sid) do
        {:error, _} -> :ok
        {:ok, _} -> flunk("bit flip at #{i} did NOT deny: #{inspect(flipped)}")
      end
    end)
  end

  test "segment swap between two valid tokens denies", %{priv: priv, keyring: keyring} do
    t1 = mint(claims(), priv)
    t2 = mint(claims(%{"act" => %{"id" => "other@x"}}), priv)
    [_p, c1, _s1] = String.split(t1, ".")
    [_p2, _c2, s2] = String.split(t2, ".")
    frankenstein = "RXC1." <> c1 <> "." <> s2
    assert {:error, :sig_invalid} = CapToken.verify(frankenstein, keyring, @now, @sid)
  end

  test "strict base64url: padding / alphabet / segment-count all deny", %{
    priv: priv,
    keyring: keyring
  } do
    token = mint(claims(), priv)
    [_p, c, s] = String.split(token, ".")

    malformed = [
      # padding added
      "RXC1." <> c <> "=." <> s,
      # non-alphabet chars
      "RXC1." <> c <> ".++//",
      # 2 segments
      "RXC1." <> c,
      # 4 segments
      "RXC1." <> c <> "." <> s <> "." <> s,
      # empty middle segment
      "RXC1.." <> s,
      # empty sig segment
      "RXC1." <> c <> ".",
      # not even a string
      :not_a_binary,
      # oversized
      "RXC1." <> String.duplicate("a", 5000) <> "." <> s
    ]

    for t <- malformed do
      assert {:error, _} = CapToken.verify(t, keyring, @now, @sid)
    end
  end

  test "duplicate JSON keys are bound by the signed bytes (no canonicalization)", %{
    priv: priv,
    keyring: keyring
  } do
    # A correctly-signed blob with a duplicate key verifies (the decoder's
    # reading IS the signed reading); an attacker cannot inject duplicates
    # post-signing without breaking the signature.
    dup_json =
      ~s({"sid":"#{@sid}","sid":"#{@sid}","act":{"id":"v@local"},) <>
        ~s("iat":#{@now - 10},"exp":#{@now + 10},"kid":"k1"})

    token = raw_token(dup_json, priv)
    assert {:ok, _} = CapToken.verify(token, keyring, @now, @sid)
  end

  # ==========================================================================
  # 5. Algorithm pinning / alg-confusion (T-14, INV-AP7)
  # ==========================================================================

  test "non-RXC1 prefixes (RXC2, JWT, none) all fail at V2 (:malformed)", %{
    priv: priv,
    keyring: keyring
  } do
    token = mint(claims(), priv)
    [_p, c, s] = String.split(token, ".")

    confusions = [
      # version downgrade/upgrade prefix swap
      "RXC2." <> c <> "." <> s,
      # a JWT with alg:none header ({"alg":"none"} == eyJhbGciOiJub25lIn0)
      "eyJhbGciOiJub25lIn0." <> c <> "." <> s,
      # bare "none"
      "none." <> c <> "." <> s,
      # empty prefix
      "." <> c <> "." <> s
    ]

    for t <- confusions do
      assert {:error, :malformed} = CapToken.verify(t, keyring, @now, @sid)
    end
  end

  test "an 'alg' claim is authenticated data, never an algorithm selector", %{
    priv: priv,
    keyring: keyring
  } do
    # Structural impossibility: even a token whose claims literally say
    # alg:none verifies fine — nothing reads it as a selector.
    token = mint(claims(%{"alg" => "none"}), priv)
    assert {:ok, c} = CapToken.verify(token, keyring, @now, @sid)
    assert c["alg"] == "none"
  end

  # ==========================================================================
  # 6. Session binding (T-15, INV-AP8) incl. prefix pairs
  # ==========================================================================

  test "a token for session A denies against B, including prefix pairs", %{
    priv: priv,
    keyring: keyring
  } do
    token = mint(claims(%{"sid" => "s1"}), priv)
    assert {:ok, _} = CapToken.verify(token, keyring, @now, "s1")

    for other <- ["s2", "s1 ", "s10", "s", ""] do
      assert {:error, :session_mismatch} =
               CapToken.verify(token, keyring, @now, other)
    end
  end

  # ==========================================================================
  # 7. Key rotation (grow-only key set)
  # ==========================================================================

  test "rotation: old + new keys each verify only their own tokens" do
    {pub1, priv1} = Issuer.generate_keypair()
    {pub2, priv2} = Issuer.generate_keypair()
    keyring = %{"k1" => pub1, "k2" => pub2}

    t1 = mint(claims(%{"kid" => "k1"}), priv1)
    t2 = mint(claims(%{"kid" => "k2"}), priv2)

    assert {:ok, _} = CapToken.verify(t1, keyring, @now, @sid)
    assert {:ok, _} = CapToken.verify(t2, keyring, @now, @sid)

    # k1 token signed by k1 but presented with kid k2 ⇒ wrong key ⇒ deny.
    cross = mint(claims(%{"kid" => "k2"}), priv1)
    assert {:error, :sig_invalid} = CapToken.verify(cross, keyring, @now, @sid)

    # Revocation = drop the kid; every token under it dies.
    assert {:error, :unknown_kid} =
             CapToken.verify(t1, Map.delete(keyring, "k1"), @now, @sid)
  end

  # ==========================================================================
  # 8. Restrictive claims at the verify layer (T-27, INV-AP17)
  # ==========================================================================

  test "an unimplemented restrictive claim denies, never admitted-by-ignoring", %{
    priv: priv,
    keyring: keyring
  } do
    token = mint(claims(%{"min_offset" => 500}), priv)

    assert {:error, :unsupported_restrictive_claim} =
             CapToken.verify(token, keyring, @now, @sid)
  end

  test "surf must be a string array (shape) at verify; jti is ignored", %{
    priv: priv,
    keyring: keyring
  } do
    good = mint(claims(%{"surf" => ["web", "tui"]}), priv)
    assert {:ok, _} = CapToken.verify(good, keyring, @now, @sid)

    bad = mint(claims(%{"surf" => "web"}), priv)
    assert {:error, :claims_invalid} = CapToken.verify(bad, keyring, @now, @sid)

    # jti is non-restrictive: ignored in v1.
    jti = mint(claims(%{"jti" => "abc"}), priv)
    assert {:ok, _} = CapToken.verify(jti, keyring, @now, @sid)
  end

  # ==========================================================================
  # 9. Totality + no atoms (T-20, INV-AP5) and offline purity (T-23, INV-AP4)
  # ==========================================================================

  test "verify is total over garbage and creates no atoms", %{keyring: keyring} do
    # Warm up (module/code loading may intern atoms once).
    _ = CapToken.verify("warmup", keyring, @now, @sid)
    before = :erlang.system_info(:atom_count)

    Enum.each(1..5_000, fn _ ->
      t = random_token()
      res = CapToken.verify(t, keyring, @now, @sid)
      assert elem(res, 0) in [:ok, :error]
    end)

    assert :erlang.system_info(:atom_count) == before
  end

  test "verify is pure: identical inputs ⇒ identical output, no clock read", %{
    priv: priv,
    keyring: keyring
  } do
    token = mint(claims(), priv)
    r1 = CapToken.verify(token, keyring, @now, @sid)
    r2 = CapToken.verify(token, keyring, @now, @sid)
    assert r1 == r2

    # The only time source is the injected `now`: a frozen-past now denies,
    # a valid now admits — the wall clock is never consulted.
    assert {:error, :expired} = CapToken.verify(token, keyring, @now + 10_000, @sid)
    assert {:ok, _} = CapToken.verify(token, keyring, @now, @sid)
  end

  # ==========================================================================
  # 10. Issuer TTL enforcement (§5.1, G5:S6)
  # ==========================================================================

  test "Issuer enforces the interactive TTL cap; archival opt-in extends it", %{
    priv: priv
  } do
    base = %{
      "sid" => @sid,
      "act" => %{"id" => "v@local"},
      "iat" => @now
    }

    # 1h ok, > 1h denied without archival.
    assert {:ok, _} = Issuer.sign(Map.put(base, "exp", @now + 3_600), "k1", priv)

    assert {:error, :ttl_too_long} =
             Issuer.sign(Map.put(base, "exp", @now + 3_601), "k1", priv)

    # archival: true lifts the cap to 30 days.
    assert {:ok, _} =
             Issuer.sign(Map.put(base, "exp", @now + 2_592_000), "k1", priv, archival: true)

    assert {:error, :ttl_too_long} =
             Issuer.sign(Map.put(base, "exp", @now + 2_592_001), "k1", priv, archival: true)
  end

  test "an Issuer-minted token round-trips through verify", %{pub: pub, priv: priv} do
    keyring = %{"k1" => pub}

    {:ok, token} =
      Issuer.sign(
        %{"sid" => @sid, "act" => %{"id" => "v@local"}, "iat" => @now, "exp" => @now + 60},
        "k1",
        priv
      )

    assert {:ok, c} = CapToken.verify(token, keyring, @now, @sid)
    assert c["kid"] == "k1"
  end

  # ==========================================================================
  # 11. The Token attach policy (§3.4) — actor / surface / downgrade, via Runner
  # ==========================================================================

  describe "Token policy (with a configured keyring + real clock)" do
    setup %{pub: pub} do
      prev = Application.get_env(:raxol_agent_client_protocol, :attach_keyring)
      Application.put_env(:raxol_agent_client_protocol, :attach_keyring, %{"k1" => {:raw, pub}})

      on_exit(fn ->
        if prev,
          do: Application.put_env(:raxol_agent_client_protocol, :attach_keyring, prev),
          else: Application.delete_env(:raxol_agent_client_protocol, :attach_keyring)
      end)

      sup = start_supervised!({Task.Supervisor, []})
      {:ok, sup: sup}
    end

    defp live_claims(overrides) do
      now = System.os_time(:second)

      Map.merge(
        %{
          "sid" => @sid,
          "act" => %{"id" => "v@local", "kind" => "user"},
          "iat" => now - 60,
          "exp" => now + 600,
          "kid" => "k1"
        },
        overrides
      )
    end

    defp pctx(cap, overrides) do
      Map.merge(
        %{
          session_id: @sid,
          actor: nil,
          surface: :tui,
          capability: cap,
          from_offset: 0,
          transport: %{kind: :tcp, peer: {1, 2}}
        },
        overrides
      )
    end

    test "tokenless attach under Token policy denies (T-17, A4 downgrade)" do
      assert {:error, :token_required} =
               TokenPolicy.authorize_attach(pctx(nil, %{}))
    end

    test "a non-string capability denies (T-18, narrows never widens)", %{priv: priv} do
      _ = priv
      assert {:error, :malformed} = TokenPolicy.authorize_attach(pctx(42, %{}))
    end

    test "a valid token yields a token grant carrying act/exp/via (INV-AP14)", %{
      priv: priv
    } do
      token = mint(live_claims(%{}), priv)

      assert {:ok, %Grant{scope: :attach, session_id: @sid, via: {:token, "k1"}} = g} =
               TokenPolicy.authorize_attach(pctx(token, %{}))

      assert g.actor["id"] == "v@local"
      assert is_integer(g.expires_at)
      assert g.lens == nil
    end

    test "actor mismatch (ctx.actor id ≠ token act id) denies (T-22, OQ-4)", %{
      priv: priv
    } do
      token = mint(live_claims(%{}), priv)

      # ctx asserts a different identity than the signed token ⇒ deny.
      ctx = pctx(token, %{actor: %{"id" => "bob"}})
      assert {:error, :actor_mismatch} = TokenPolicy.authorize_attach(ctx)

      # matching id, or nil ctx.actor (token is sole identity), both admit.
      assert {:ok, _} =
               TokenPolicy.authorize_attach(pctx(token, %{actor: %{"id" => "v@local"}}))

      assert {:ok, _} = TokenPolicy.authorize_attach(pctx(token, %{actor: nil}))
    end

    test "surf claim is enforced against ctx.surface (T-27, INV-AP17)", %{priv: priv} do
      token = mint(live_claims(%{"surf" => ["web"]}), priv)

      # bound to web ⇒ a :tui attach denies…
      assert {:error, :surface_not_allowed} =
               TokenPolicy.authorize_attach(pctx(token, %{surface: :tui}))

      # …a :web attach admits.
      assert {:ok, _} =
               TokenPolicy.authorize_attach(pctx(token, %{surface: :web}))
    end

    test "surf claim fails CLOSED on a type-mismatched ctx.surface — a restrictive " <>
           "claim must never fall through to the unrestricted catch-all (G6 S5, security)",
         %{priv: priv} do
      # Token is restricted to the "tui" surface only.
      token = mint(live_claims(%{"surf" => ["tui"]}), priv)

      # A STRING surface ("editor") is neither a member of surf NOR the atom
      # form of a member — a security gate must deny on this type mismatch,
      # never fall through to an unrestricted :ok via the catch-all clause.
      assert {:error, :surface_not_allowed} =
               TokenPolicy.authorize_attach(pctx(token, %{surface: "editor"}))

      # Also: a string that WOULD match textually if compared loosely still
      # denies — the gate must not coerce/compare across types at all.
      assert {:error, :surface_not_allowed} =
               TokenPolicy.authorize_attach(pctx(token, %{surface: "tui"}))

      # nil surface with a restrictive claim present also denies (no type ⇒
      # no membership, still a mismatch).
      assert {:error, :surface_not_allowed} =
               TokenPolicy.authorize_attach(pctx(token, %{surface: nil}))
    end

    test "surf claim: matching atom passes, non-member atom denies, absent claim " <>
           "passes unrestricted (G6 S5 regression matrix)",
         %{priv: priv} do
      restricted = mint(live_claims(%{"surf" => ["tui"]}), priv)
      unrestricted = mint(live_claims(%{}), priv)

      # matching atom ⇒ pass
      assert {:ok, _} =
               TokenPolicy.authorize_attach(pctx(restricted, %{surface: :tui}))

      # non-member atom ⇒ deny
      assert {:error, :surface_not_allowed} =
               TokenPolicy.authorize_attach(pctx(restricted, %{surface: :editor}))

      # no surf claim at all ⇒ unrestricted, any surface passes
      assert {:ok, _} =
               TokenPolicy.authorize_attach(pctx(unrestricted, %{surface: :editor}))

      assert {:ok, _} =
               TokenPolicy.authorize_attach(pctx(unrestricted, %{surface: "editor"}))
    end

    test "the full Runner funnel admits a valid token and denies an expired one", %{
      priv: priv,
      sup: sup
    } do
      good = mint(live_claims(%{}), priv)

      assert {:ok, %Grant{via: {:token, "k1"}}} =
               Runner.authorize(TokenPolicy, pctx(good, %{}), task_supervisor: sup)

      now = System.os_time(:second)
      expired = mint(live_claims(%{"iat" => now - 120, "exp" => now - 60}), priv)

      # Every policy {:error, _} collapses to the funnel's :policy_error deny.
      assert {:denied, :policy_error} =
               Runner.authorize(TokenPolicy, pctx(expired, %{}), task_supervisor: sup)
    end
  end

  # -- Keyring load/validate ---------------------------------------------------

  test "Keyring normalizes hex/raw/file and rejects non-32-byte keys", %{pub: pub} do
    hex = Base.encode16(pub, case: :lower)
    assert %{"k1" => ^pub} = Keyring.normalize(%{"k1" => {:hex, hex}})
    assert %{"k1" => ^pub} = Keyring.normalize(%{"k1" => {:raw, pub}})
    assert %{"k1" => ^pub} = Keyring.normalize(%{"k1" => pub})

    assert_raise ArgumentError, fn ->
      Keyring.normalize(%{"bad" => {:raw, <<0, 1, 2>>}})
    end

    assert_raise ArgumentError, fn ->
      Keyring.normalize(%{"bad" => {:hex, "zznothex"}})
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp flip_bit(bin, i) do
    byte_index = div(i, 8)
    bit = 7 - rem(i, 8)
    <<pre::binary-size(byte_index), b, rest::binary>> = bin
    <<pre::binary, bxor(b, bsl(1, bit)), rest::binary>>
  end

  defp random_token do
    case :rand.uniform(3) do
      1 ->
        :crypto.strong_rand_bytes(:rand.uniform(64))

      2 ->
        "RXC1." <> Base.url_encode64(:crypto.strong_rand_bytes(40), padding: false)

      3 ->
        "RXC1." <> b64(:crypto.strong_rand_bytes(20)) <> "." <> b64(:crypto.strong_rand_bytes(64))
    end
  end
end
