defmodule Raxol.Payments.FeeScheduleTest do
  @moduledoc """
  Parity against the canonical schedule, plus the arithmetic on top of it.

  The oracle in `priv/fee-oracle/schedule.json` is the generated projection of
  `Riddler.Integrations.Xochi.FeePolicy` -- the same artifact `@riddler/sdk-taker`
  checks its TypeScript mirror against. Pinning to it is what makes this module
  a mirror rather than a second opinion: if Riddler reprices, these fail instead
  of raxol.io quietly advertising a rate nobody charges.
  """
  use ExUnit.Case, async: true

  alias Raxol.Payments.FeeSchedule

  @oracle "fee-oracle/schedule.json"
          |> then(&Path.join(:code.priv_dir(:raxol_payments), &1))
          |> File.read!()
          |> Jason.decode!()

  defp tier_atom(name), do: String.to_existing_atom(name)

  describe "parity with the canonical schedule" do
    test "solver base, the layer no tier discounts" do
      assert FeeSchedule.solver_base_bps() == %{
               stable: @oracle["solver_base_bps"]["stable"],
               volatile: @oracle["solver_base_bps"]["volatile"]
             }
    end

    test "venue and routing layers, every tier and asset class" do
      for {name, expected} <- @oracle["venue_bps"] do
        tier = tier_atom(name)

        for class <- [:stable, :volatile] do
          layers = FeeSchedule.layers(tier, class)

          assert layers.venue_bps == expected[Atom.to_string(class)],
                 "venue #{tier}/#{class}"

          assert layers.routing_bps ==
                   @oracle["routing_bps"][name][Atom.to_string(class)],
                 "routing #{tier}/#{class}"
        end
      end
    end

    test "tier boundaries resolve the same scores to the same tiers" do
      for %{"min_trust_score" => min, "tier" => name} <- @oracle["tier_boundaries"] do
        assert FeeSchedule.tier_for_score(min) == tier_atom(name)
        assert FeeSchedule.min_score(tier_atom(name)) == min
      end
    end

    test "attestation requirements" do
      for {name, required} <- @oracle["tier_attestation_requirements"] do
        assert FeeSchedule.tier_attestation_requirements()[tier_atom(name)] ==
                 Enum.map(required, &tier_atom/1)
      end
    end

    test "surplus share" do
      assert FeeSchedule.surplus_share_pct() == @oracle["surplus_share_pct"]
    end

    test "the oracle covers every tier this module claims" do
      # Guards the direction parity tests miss: a tier added upstream that was
      # never mirrored here would otherwise pass, because every tier this
      # module has would still match.
      assert MapSet.new(FeeSchedule.tiers()) ==
               @oracle["venue_bps"] |> Map.keys() |> Enum.map(&tier_atom/1) |> MapSet.new()
    end
  end

  describe "headline rates" do
    test "are the sum of the three layers" do
      # The published totals: stable 22/19/15/12/10, volatile 40/35/29/25/22.
      assert Enum.map(FeeSchedule.tiers(), &FeeSchedule.headline_bps(&1, :stable)) ==
               [22, 19, 15, 12, 10]

      assert Enum.map(FeeSchedule.tiers(), &FeeSchedule.headline_bps(&1, :volatile)) ==
               [40, 35, 29, 25, 22]
    end

    test "never fall below the solver floor, at any tier" do
      # The property that keeps every tier cash-positive: discounts carve the
      # venue and routing layers only.
      for tier <- FeeSchedule.tiers(), class <- [:stable, :volatile] do
        floor = FeeSchedule.solver_base_bps()[class]

        assert FeeSchedule.headline_bps(tier, class) >= floor
        assert FeeSchedule.headline_bps(tier, class, acp: true) >= floor
        assert FeeSchedule.layers(tier, class).solver_bps == floor
      end
    end

    test "an ACP intent pays no routing layer" do
      # It is already paid through the job budget; charging it again is a
      # double charge.
      for tier <- FeeSchedule.tiers(), class <- [:stable, :volatile] do
        layers = FeeSchedule.layers(tier, class)

        assert FeeSchedule.headline_bps(tier, class, acp: true) ==
                 FeeSchedule.headline_bps(tier, class) - layers.routing_bps
      end
    end

    test "there is no zero-fee tier" do
      # raxol.io advertised `public: 0 bps -- no fee`, which no tier has ever
      # charged: the solver floor is never discounted.
      refute Enum.any?(FeeSchedule.tiers(), fn tier ->
               FeeSchedule.headline_bps(tier, :stable, acp: true) <= 0
             end)
    end
  end

  describe "tier_for_score/1" do
    test "maps each band to its tier" do
      assert FeeSchedule.tier_for_score(0) == :standard
      assert FeeSchedule.tier_for_score(24) == :standard
      assert FeeSchedule.tier_for_score(25) == :trusted
      assert FeeSchedule.tier_for_score(49) == :trusted
      assert FeeSchedule.tier_for_score(50) == :verified
      assert FeeSchedule.tier_for_score(74) == :verified
      assert FeeSchedule.tier_for_score(75) == :premium
      assert FeeSchedule.tier_for_score(99) == :premium
      assert FeeSchedule.tier_for_score(100) == :institutional
      assert FeeSchedule.tier_for_score(10_000) == :institutional
    end

    test "a malformed score prices at the highest rate rather than raising" do
      # Failing the quote on a bad score would be worse than charging full
      # freight for it.
      for bad <- [-1, -100, 3.5, nil, "50", :standard] do
        assert FeeSchedule.tier_for_score(bad) == :standard
      end
    end
  end

  describe "all/1" do
    test "gives contiguous score bands with an open-ended top tier" do
      rows = FeeSchedule.all()

      assert Enum.map(rows, & &1.tier) == FeeSchedule.tiers()
      assert List.first(rows).min_score == 0
      assert List.last(rows).max_score == nil

      rows
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert a.max_score + 1 == b.min_score,
               "gap or overlap between #{a.tier} and #{b.tier}"
      end)
    end

    test "carries both asset classes, which differ" do
      for row <- FeeSchedule.all() do
        assert row.volatile_bps > row.stable_bps
      end
    end
  end
end
