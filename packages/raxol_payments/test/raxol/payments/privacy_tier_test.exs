defmodule Raxol.Payments.PrivacyTierTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.PrivacyTier

  describe "from_trust_score/2" do
    test "nil score defaults to standard" do
      tier = PrivacyTier.from_trust_score(nil)
      assert tier.tier == :standard
      assert tier.settlement == :public
    end

    test "score 0 maps to standard" do
      tier = PrivacyTier.from_trust_score(0)
      assert tier.tier == :standard
      assert tier.settlement == :public
    end

    test "score 24 maps to standard" do
      tier = PrivacyTier.from_trust_score(24)
      assert tier.tier == :standard
      assert tier.settlement == :public
    end

    test "score 25 maps to stealth" do
      tier = PrivacyTier.from_trust_score(25)
      assert tier.tier == :stealth
      assert tier.settlement == :stealth
    end

    test "score 49 maps to stealth" do
      tier = PrivacyTier.from_trust_score(49)
      assert tier.tier == :stealth
    end

    test "score 50 maps to private" do
      tier = PrivacyTier.from_trust_score(50)
      assert tier.tier == :private
      assert tier.settlement == :shielded
    end

    test "score 74 maps to private" do
      tier = PrivacyTier.from_trust_score(74)
      assert tier.tier == :private
    end

    test "score 75 maps to sovereign" do
      tier = PrivacyTier.from_trust_score(75)
      assert tier.tier == :sovereign
      assert tier.settlement == :shielded
    end

    test "score 120 maps to sovereign" do
      tier = PrivacyTier.from_trust_score(120)
      assert tier.tier == :sovereign
    end

    test "tier_override can request less privacy" do
      tier = PrivacyTier.from_trust_score(80, tier_override: :stealth)
      assert tier.tier == :stealth
      assert tier.settlement == :stealth
    end

    test "tier_override cannot exceed trust score" do
      tier = PrivacyTier.from_trust_score(10, tier_override: :sovereign)
      assert tier.tier == :standard
    end

    test "data retention decreases with higher tiers" do
      standard = PrivacyTier.from_trust_score(10)
      sovereign = PrivacyTier.from_trust_score(80)
      assert standard.data_retention == :amounts
      assert sovereign.data_retention == :nothing
    end
  end

  describe "info/1" do
    test "returns tier info for named tier" do
      info = PrivacyTier.info(:open)
      assert info.tier == :open
      assert info.settlement == :public
      assert info.data_retention == :full_analytics
    end
  end

  describe "all/0" do
    test "returns six tiers in ascending order" do
      tiers = PrivacyTier.all()
      assert length(tiers) == 6

      assert Enum.map(tiers, & &1.tier) == [
               :open,
               :public,
               :standard,
               :stealth,
               :private,
               :sovereign
             ]
    end
  end

  describe "attestation requirements" do
    test "sovereign with required attestations stays sovereign" do
      attestations = [
        %{
          type: :compliance,
          subject: "0x",
          issuer: "0x",
          issued_at: 0,
          expires_at: 0,
          valid: true
        },
        %{
          type: :non_membership,
          subject: "0x",
          issuer: "0x",
          issued_at: 0,
          expires_at: 0,
          valid: true
        }
      ]

      tier = PrivacyTier.from_trust_score(80, attestations: attestations)
      assert tier.tier == :sovereign
    end

    test "sovereign without non_membership downgrades to private" do
      attestations = [
        %{
          type: :compliance,
          subject: "0x",
          issuer: "0x",
          issued_at: 0,
          expires_at: 0,
          valid: true
        }
      ]

      tier = PrivacyTier.from_trust_score(80, attestations: attestations)
      assert tier.tier == :private
    end

    test "private without compliance downgrades to stealth" do
      attestations = [
        %{
          type: :non_membership,
          subject: "0x",
          issuer: "0x",
          issued_at: 0,
          expires_at: 0,
          valid: true
        }
      ]

      tier = PrivacyTier.from_trust_score(60, attestations: attestations)
      assert tier.tier == :stealth
    end

    test "no attestations provided does not downgrade (backward compat)" do
      tier = PrivacyTier.from_trust_score(80)
      assert tier.tier == :sovereign
    end

    test "empty attestations list does not downgrade" do
      tier = PrivacyTier.from_trust_score(80, attestations: [])
      assert tier.tier == :sovereign
    end

    test "attestation_requirements/1 returns expected lists" do
      assert PrivacyTier.attestation_requirements(:standard) == []
      assert PrivacyTier.attestation_requirements(:stealth) == []
      assert PrivacyTier.attestation_requirements(:private) == [:compliance]
      assert :compliance in PrivacyTier.attestation_requirements(:sovereign)
      assert :non_membership in PrivacyTier.attestation_requirements(:sovereign)
    end
  end

  describe "attestation validity filtering" do
    test "attestations with valid: false are filtered out" do
      invalid_attestations = [
        %{
          type: :compliance,
          subject: "0x",
          issuer: "0x",
          issued_at: 0,
          expires_at: 0,
          valid: false
        },
        %{
          type: :non_membership,
          subject: "0x",
          issuer: "0x",
          issued_at: 0,
          expires_at: 0,
          valid: false
        }
      ]

      # Score 80 -> sovereign, but sovereign requires compliance + non_membership
      # with valid: true. All attestations are invalid, so downgrade walks down
      # to stealth (first tier with no attestation requirements).
      tier = PrivacyTier.from_trust_score(80, attestations: invalid_attestations)
      assert tier.tier == :stealth
    end

    test "mixed valid/invalid attestations -- only valid ones count" do
      attestations = [
        %{
          type: :compliance,
          subject: "0x",
          issuer: "0x",
          issued_at: 0,
          expires_at: 0,
          valid: true
        },
        %{
          type: :non_membership,
          subject: "0x",
          issuer: "0x",
          issued_at: 0,
          expires_at: 0,
          valid: false
        }
      ]

      # Only compliance is valid, so private (requires compliance) is met,
      # but sovereign (requires compliance + non_membership) is not.
      tier = PrivacyTier.from_trust_score(80, attestations: attestations)
      assert tier.tier == :private
    end

    test "sovereign tier requires both compliance and non_membership with valid: true" do
      valid_attestations = [
        %{
          type: :compliance,
          subject: "0x",
          issuer: "0x",
          issued_at: 0,
          expires_at: 0,
          valid: true
        },
        %{
          type: :non_membership,
          subject: "0x",
          issuer: "0x",
          issued_at: 0,
          expires_at: 0,
          valid: true
        }
      ]

      tier = PrivacyTier.from_trust_score(80, attestations: valid_attestations)
      assert tier.tier == :sovereign
    end
  end

  describe "shielded?/1" do
    test "true for shielded settlement" do
      tier = PrivacyTier.from_trust_score(60)
      assert PrivacyTier.shielded?(tier)
    end

    test "false for public settlement" do
      tier = PrivacyTier.from_trust_score(10)
      refute PrivacyTier.shielded?(tier)
    end

    test "false for stealth settlement" do
      tier = PrivacyTier.from_trust_score(30)
      refute PrivacyTier.shielded?(tier)
    end
  end
end
