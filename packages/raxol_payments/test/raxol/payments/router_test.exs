defmodule Raxol.Payments.RouterTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Router

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

  describe "attestation-aware routing" do
    @verified_non_membership %{
      type: :non_membership,
      subject: "0x",
      issuer: "0x",
      issued_at: 0,
      expires_at: 0,
      valid: true
    }
    @verified_compliance %{
      type: :compliance,
      subject: "0x",
      issuer: "0x",
      issued_at: 0,
      expires_at: 0,
      valid: true
    }

    test "attestations compute trust score when trust_score absent" do
      # non_membership (25) + compliance (20/ln(3) ~= 18) = ~43 -> stealth tier -> xochi
      assert Router.select(attestations: [@verified_non_membership, @verified_compliance]) ==
               :xochi
    end

    test "trust_score takes precedence over attestations" do
      # Explicit score 10 -> standard -> x402, even though attestations would yield higher
      assert Router.select(
               trust_score: 10,
               attestations: [@verified_non_membership, @verified_compliance]
             ) == :x402
    end

    test "attestations with high aggregate score route to xochi" do
      # non_membership alone = 25 -> stealth -> xochi
      assert Router.select(attestations: [@verified_non_membership]) == :xochi
    end

    test "trust_score_for/1 with attestations" do
      score = Router.trust_score_for(attestations: [@verified_non_membership])
      assert score == 25
    end

    test "trust_score_for/1 prefers explicit trust_score" do
      assert Router.trust_score_for(trust_score: 42) == 42
    end

    test "trust_score_for/1 returns 0 with no inputs" do
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

    test "attestations with valid: false do not count for tier requirements" do
      invalid_compliance = %{
        type: :compliance,
        subject: "0x",
        issuer: "0x",
        issued_at: 0,
        expires_at: 0,
        valid: false
      }

      invalid_non_membership = %{
        type: :non_membership,
        subject: "0x",
        issuer: "0x",
        issued_at: 0,
        expires_at: 0,
        valid: false
      }

      # Score 80 qualifies for sovereign, but invalid attestations should
      # cause downgrade since they don't satisfy requirements.
      # Downgrades to stealth (first tier with no attestation requirements).
      settlement =
        Router.settlement_for(
          trust_score: 80,
          attestations: [invalid_compliance, invalid_non_membership]
        )

      assert settlement == :stealth
    end

    test "empty attestation list does not affect routing" do
      assert Router.settlement_for(trust_score: 80, attestations: []) == :shielded
    end
  end
end
