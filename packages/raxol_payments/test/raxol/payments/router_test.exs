defmodule Raxol.Payments.RouterTest do
  # async: false -- the attestation tests set the :zksar_allowed_issuers app env.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Router
  alias Raxol.Payments.Zksar

  # anvil account 0/1 keys -- real secp256k1 scalars. account 0's address is the
  # trusted attestation issuer; account 1 signs "wrong issuer" proofs.
  @issuer_key Base.decode16!(
                "AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80",
                case: :mixed
              )
  @rogue_key Base.decode16!(
               "59C6995E998F97A5A0044966F0945389DC9E86DAE88C7A8412F4603B6B78690D",
               case: :mixed
             )

  @issuer (
            {:ok, pub} = ExSecp256k1.create_public_key(@issuer_key)
            <<_prefix::8, body::binary-size(64)>> = pub
            <<_first_12::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(body)
            "0x" <> Base.encode16(addr, case: :lower)
          )

  @type_codes %{compliance: 0x01, risk_score: 0x02, non_membership: 0x06}

  setup do
    prior = Application.get_env(:raxol_payments, :zksar_allowed_issuers)
    Application.put_env(:raxol_payments, :zksar_allowed_issuers, [@issuer])

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:raxol_payments, :zksar_allowed_issuers)
        value -> Application.put_env(:raxol_payments, :zksar_allowed_issuers, value)
      end
    end)

    :ok
  end

  # A raw ZKSAR proof of `type` signed by `key`, valid at real system time (the
  # Router verifies with no `now:` override): far-future expiry, past issue.
  defp signed(type, key \\ @issuer_key) do
    proof = %{
      type_code: Map.fetch!(@type_codes, type),
      issuer: address_for(key),
      subject: "0x00000000000000000000000000000000000000ff",
      issued_at: 1_000_000_000,
      expires_at: 4_000_000_000,
      signature: "",
      payload: <<1, 2, 3, 4>>
    }

    digest = Zksar.attestation_digest(proof)
    {:ok, {r, s, v}} = ExSecp256k1.sign(digest, key)

    %{
      proof
      | signature:
          "0x" <> Base.encode16(<<r::binary-size(32), s::binary-size(32), v::8>>, case: :lower)
    }
  end

  defp address_for(key) do
    {:ok, pub} = ExSecp256k1.create_public_key(key)
    <<_prefix::8, body::binary-size(64)>> = pub
    <<_first_12::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(body)
    "0x" <> Base.encode16(addr, case: :lower)
  end

  describe "select/1" do
    test "defaults to x402 for same-chain" do
      assert Router.select() == :x402
      assert Router.select(cross_chain: false) == :x402
    end

    test "routes cross-chain to xochi" do
      assert Router.select(cross_chain: true) == :xochi
    end

    test "routes stealth privacy to xochi" do
      assert Router.select(privacy: :stealth) == :xochi
    end

    test "routes shielded privacy to xochi" do
      assert Router.select(privacy: :shielded) == :xochi
    end

    test "public privacy same-chain stays x402" do
      assert Router.select(privacy: :public, cross_chain: false) == :x402
    end

    test "forced protocol overrides routing" do
      assert Router.select(protocol: :mpp) == :mpp
      assert Router.select(protocol: :riddler, cross_chain: true) == :riddler
    end

    test "routes a Tron destination to the relay rail" do
      assert Router.select(from_chain_id: 8453, to_chain_id: 728_126_428) == :relay
    end

    test "routes a Tron source to the relay rail" do
      assert Router.select(from_chain_id: 728_126_428, to_chain_id: 8453) == :relay
    end

    test "a Tron leg takes the relay rail even when stealth is requested" do
      assert Router.select(to_chain_id: 728_126_428, privacy: :stealth) == :relay
    end

    test "a forced protocol still overrides Tron routing" do
      assert Router.select(to_chain_id: 728_126_428, protocol: :xochi) == :xochi
    end

    test "trust_score >= 25 auto-selects xochi via stealth" do
      assert Router.select(trust_score: 25) == :xochi
    end

    test "trust_score >= 50 auto-selects xochi via shielded" do
      assert Router.select(trust_score: 50) == :xochi
    end

    test "trust_score < 25 stays x402 for same-chain" do
      assert Router.select(trust_score: 10) == :x402
    end

    test "explicit privacy overrides trust_score for protocol selection" do
      assert Router.select(trust_score: 80, privacy: :public) == :x402
    end
  end

  describe "attestation-aware routing (verified, fail closed) (#337)" do
    # A caller-fabricated attestation: the verified shape, but no raw proof to
    # verify (no type_code / signature). It must buy nothing.
    @self_asserted %{type: :non_membership, valid: true}

    test "verified attestations compute a trust score" do
      # signed non_membership (25) + compliance (~18) = ~43 -> stealth -> xochi
      assert Router.select(attestations: [signed(:non_membership), signed(:compliance)]) == :xochi
    end

    test "a single verified attestation of sufficient weight routes to xochi" do
      # signed non_membership = 25 -> stealth -> xochi
      assert Router.select(attestations: [signed(:non_membership)]) == :xochi
    end

    test "trust_score_for aggregates only verified proofs" do
      assert Router.trust_score_for(attestations: [signed(:non_membership)]) == 25
    end

    test "a self-asserted attestation (no signature) buys no trust -- fail closed" do
      # The core #337 vulnerability: valid: true with no proof behind it.
      assert Router.select(attestations: [@self_asserted]) == :x402
      assert Router.trust_score_for(attestations: [@self_asserted]) == 0
      assert Router.settlement_for(attestations: [@self_asserted]) == :public
    end

    test "a proof from a non-allowlisted issuer buys no trust" do
      rogue = signed(:non_membership, @rogue_key)
      assert Router.select(attestations: [rogue]) == :x402
      assert Router.trust_score_for(attestations: [rogue]) == 0
    end

    test "no configured allowlist means no attestation buys trust" do
      Application.put_env(:raxol_payments, :zksar_allowed_issuers, [])
      assert Router.select(attestations: [signed(:non_membership)]) == :x402
      assert Router.trust_score_for(attestations: [signed(:non_membership)]) == 0
    end

    test "an explicit trust_score wins over (would-be) attestation trust" do
      assert Router.select(trust_score: 10, attestations: [signed(:non_membership)]) == :x402
    end

    test "trust_score_for prefers an explicit trust_score" do
      assert Router.trust_score_for(trust_score: 42) == 42
    end

    test "trust_score_for returns 0 with no inputs" do
      assert Router.trust_score_for() == 0
    end
  end

  describe "settlement_for/1" do
    test "defaults to public with no options" do
      assert Router.settlement_for() == :public
    end

    test "explicit privacy takes precedence" do
      assert Router.settlement_for(privacy: :shielded) == :shielded
      assert Router.settlement_for(privacy: :stealth) == :stealth
      assert Router.settlement_for(privacy: :public) == :public
    end

    test "derives settlement from trust_score" do
      assert Router.settlement_for(trust_score: 10) == :public
      assert Router.settlement_for(trust_score: 30) == :stealth
      assert Router.settlement_for(trust_score: 60) == :shielded
      assert Router.settlement_for(trust_score: 80) == :shielded
    end

    test "nil trust_score defaults to public" do
      assert Router.settlement_for(trust_score: nil) == :public
    end

    test "tier_override is forwarded" do
      # Score 80 would be sovereign/shielded, but override to stealth
      assert Router.settlement_for(trust_score: 80, tier_override: :stealth) == :stealth
    end

    test "trust_score 999 gets clamped to 100, still maps to sovereign/shielded" do
      assert Router.settlement_for(trust_score: 999) == :shielded
    end

    test "verified attestations satisfy a high tier's requirement (no downgrade) (#337)" do
      # Sovereign (score 75+) requires compliance + non_membership; both verified
      # and present, so the tier stands -> shielded.
      settlement =
        Router.settlement_for(
          trust_score: 80,
          attestations: [signed(:compliance), signed(:non_membership)]
        )

      assert settlement == :shielded
    end

    test "verified attestations that miss a tier's required types force a downgrade (#337)" do
      # Score 80 is sovereign, but the only verified proof is risk_score, so the
      # compliance/non_membership requirement is unmet -> downgrade to stealth.
      settlement = Router.settlement_for(trust_score: 80, attestations: [signed(:risk_score)])
      assert settlement == :stealth
    end

    test "unverified attestations are dropped, not credited, so they do not downgrade (#337)" do
      # Self-asserted proofs verify to nothing, so an explicit high score resolves
      # by score alone -- as if no attestations were supplied.
      settlement =
        Router.settlement_for(
          trust_score: 80,
          attestations: [%{type: :compliance, valid: true}, %{type: :non_membership, valid: true}]
        )

      assert settlement == :shielded
    end

    test "empty attestation list does not affect routing" do
      assert Router.settlement_for(trust_score: 80, attestations: []) == :shielded
    end
  end
end
