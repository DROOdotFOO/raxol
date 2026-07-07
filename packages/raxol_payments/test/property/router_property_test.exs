defmodule Raxol.Payments.RouterPropertyTest do
  @moduledoc """
  Properties for `Raxol.Payments.Router` trust-score -> settlement/protocol
  routing. The example tests cover realistic 0..100 scores; these pin the
  behaviour across the whole integer range -- including the out-of-contract
  inputs (negative, over-100) a caller can supply -- and the ordering
  invariants that keep a low-trust agent out of a high-privacy tier.

  `settlement` privacy is ordered `:public < :stealth < :shielded`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.Router

  @privacy_rank %{public: 0, stealth: 1, shielded: 2}
  @settlements [:public, :stealth, :shielded]
  @protocols [:x402, :mpp, :xochi, :riddler, :relay]
  @tiers [:open, :public, :standard, :stealth, :private, :sovereign]

  # Deliberately spans below 0 and above 100: a caller can pass any integer,
  # and the router must clamp rather than crash or mis-tier.
  defp score, do: integer(-100..200)

  describe "settlement_for/1" do
    property "returns a valid settlement for ANY integer trust score" do
      check all(s <- score()) do
        assert Router.settlement_for(trust_score: s) in @settlements
      end
    end

    property "privacy is non-decreasing in trust score (monotonic)" do
      check all(a <- score(), b <- score()) do
        lo = min(a, b)
        hi = max(a, b)

        assert @privacy_rank[Router.settlement_for(trust_score: lo)] <=
                 @privacy_rank[Router.settlement_for(trust_score: hi)]
      end
    end

    property "a score outside [0,100] behaves exactly like the clamped score" do
      check all(s <- score()) do
        clamped = s |> max(0) |> min(100)

        assert Router.settlement_for(trust_score: s) ==
                 Router.settlement_for(trust_score: clamped)
      end
    end

    property "an explicit :privacy overrides any trust score" do
      check all(
              s <- score(),
              privacy <- member_of(@settlements)
            ) do
        assert Router.settlement_for(trust_score: s, privacy: privacy) == privacy
      end
    end

    property "tier_override never grants more privacy than the score earned" do
      check all(
              s <- integer(0..100),
              override <- member_of(@tiers)
            ) do
        earned = Router.settlement_for(trust_score: s)
        with_override = Router.settlement_for(trust_score: s, tier_override: override)

        # A user may opt DOWN into less privacy, never up past what they earned.
        assert @privacy_rank[with_override] <= @privacy_rank[earned]
      end
    end
  end

  describe "select/1" do
    property "always returns a known protocol atom for any option mix" do
      check all(
              cross_chain <- boolean(),
              privacy <- member_of([:auto | @settlements]),
              s <- score()
            ) do
        assert Router.select(cross_chain: cross_chain, privacy: privacy, trust_score: s) in @protocols
      end
    end

    property "a forced :protocol overrides all routing" do
      check all(
              forced <- member_of(@protocols),
              cross_chain <- boolean(),
              s <- integer(0..100)
            ) do
        assert Router.select(protocol: forced, cross_chain: cross_chain, trust_score: s) ==
                 forced
      end
    end

    property "cross-chain (non-Tron) always routes to xochi" do
      check all(s <- integer(0..100)) do
        assert Router.select(
                 cross_chain: true,
                 from_chain_id: 8453,
                 to_chain_id: 42_161,
                 trust_score: s
               ) ==
                 :xochi
      end
    end
  end

  describe "trust_score_for/1" do
    property "returns a value in [0,100] for any integer score" do
      check all(s <- score()) do
        result = Router.trust_score_for(trust_score: s)
        assert result >= 0 and result <= 100
      end
    end
  end
end
