defmodule Raxol.Payments.FeeSchedule do
  @moduledoc """
  The canonical Xochi fee schedule, mirrored in Elixir.

  Authoritative source is `Riddler.Integrations.Xochi.FeePolicy`. This module
  is its in-code mirror on the raxol side, exactly as
  `@riddler/sdk-taker`'s `fee.ts` is on the TypeScript side, and it is pinned
  against the same generated projection both of those are checked against
  (`priv/fee-oracle/schedule.json`). `fee_schedule_test.exs` fails when the two
  drift, so a fee rate cannot quietly go stale here while the solver charges
  something else.

  ## What a quote costs

  A quote is three additive layers, in basis points:

    * **solver** -- Riddler's spread. NEVER discounted at any tier: it is the
      cash-positivity floor that keeps a fill from running at a loss.
    * **venue** -- the Xochi protocol cut. Discounted by trust tier.
    * **routing** -- the raxol routing cut. Discounted by trust tier, and
      waived entirely when the intent originates from an ACP job, because the
      routing cut is already paid through the job budget.

  A tier's headline rate is the sum of its three layers for the asset class
  being moved, and the two classes differ substantially -- 22 bps to move a
  stablecoin at `:standard`, 40 bps to move a volatile asset. Quoting one
  number without naming the asset class states a price that is right half the
  time.

  ## Tiers are earned by trust score, not chosen

  | Score  | Tier          | Stable | Volatile |
  | ------ | ------------- | ------ | -------- |
  | 0-24   | standard      | 22     | 40       |
  | 25-49  | trusted       | 19     | 35       |
  | 50-74  | verified      | 15     | 29       |
  | 75-99  | premium       | 12     | 25       |
  | 100    | institutional | 10     | 22       |

  Privacy is a SETTLEMENT MODE (public / stealth / shielded), not a fee input;
  see `Raxol.Payments.PrivacyTier`. The two were once conflated here, which put
  a fee table on raxol.io that no tier ever charged.

  The upper tiers additionally gate on attestation proofs
  (`tier_attestation_requirements/0`): a score alone does not buy `:verified`
  or above without the matching verified attestations, and a tier is gated down
  to the best one whose proofs are satisfied.

  Price impact is a solver cost rather than a fee layer and is not part of any
  headline here. Positive fill slippage is shared: `surplus_share_pct/0` is
  kept by the protocol and the rest returns to the taker.
  """

  @type tier :: :standard | :trusted | :verified | :premium | :institutional
  @type asset_class :: :stable | :volatile
  @type attestation :: :compliance | :non_membership

  @type layers :: %{solver_bps: integer(), venue_bps: integer(), routing_bps: integer()}

  # Highest boundary first: a score matches the first boundary it meets or
  # exceeds, which is the server's own resolution order.
  @tier_boundaries [
    {100, :institutional},
    {75, :premium},
    {50, :verified},
    {25, :trusted},
    {0, :standard}
  ]

  @solver_base_bps %{stable: 8, volatile: 18}

  @venue_bps %{
    standard: %{stable: 6, volatile: 10},
    trusted: %{stable: 5, volatile: 8},
    verified: %{stable: 3, volatile: 5},
    premium: %{stable: 2, volatile: 3},
    institutional: %{stable: 1, volatile: 2}
  }

  @routing_bps %{
    standard: %{stable: 8, volatile: 12},
    trusted: %{stable: 6, volatile: 9},
    verified: %{stable: 4, volatile: 6},
    premium: %{stable: 2, volatile: 4},
    institutional: %{stable: 1, volatile: 2}
  }

  @tier_attestation_requirements %{
    standard: [],
    trusted: [],
    verified: [:compliance],
    premium: [:compliance, :non_membership],
    institutional: [:compliance, :non_membership]
  }

  @surplus_share_pct 15

  @tier_order [:standard, :trusted, :verified, :premium, :institutional]

  @doc "Every tier, lowest trust first."
  @spec tiers() :: [tier()]
  def tiers, do: @tier_order

  @doc "The trust score at which `tier` starts."
  @spec min_score(tier()) :: non_neg_integer()
  def min_score(tier) when tier in @tier_order do
    {score, ^tier} = Enum.find(@tier_boundaries, fn {_score, t} -> t == tier end)
    score
  end

  @doc """
  The tier a trust score earns, before attestation gating.

  A non-integer or negative score falls back to `:standard`, matching the
  server rather than raising: a malformed score must price at the highest
  rate, not fail the quote.
  """
  @spec tier_for_score(term()) :: tier()
  def tier_for_score(score) when is_integer(score) and score >= 0 do
    Enum.find_value(@tier_boundaries, :standard, fn {min, tier} ->
      score >= min && tier
    end)
  end

  def tier_for_score(_score), do: :standard

  @doc "The three fee layers for a tier and asset class, in bps."
  @spec layers(tier(), asset_class()) :: layers()
  def layers(tier, asset_class)
      when tier in @tier_order and asset_class in [:stable, :volatile] do
    %{
      solver_bps: @solver_base_bps[asset_class],
      venue_bps: @venue_bps[tier][asset_class],
      routing_bps: @routing_bps[tier][asset_class]
    }
  end

  @doc """
  The headline rate for a tier and asset class, in bps.

  `acp: true` waives the routing layer, which is what an intent originating
  from an ACP job actually pays -- the routing cut is already in the job
  budget, and charging it twice would be a double charge.
  """
  @spec headline_bps(tier(), asset_class(), keyword()) :: integer()
  def headline_bps(tier, asset_class, opts \\ []) do
    %{solver_bps: solver, venue_bps: venue, routing_bps: routing} =
      layers(tier, asset_class)

    routing = if Keyword.get(opts, :acp, false), do: 0, else: routing

    solver + venue + routing
  end

  @doc """
  Every tier as a display row: the tier, the score band that earns it, and the
  headline rate for each asset class.

  `max_score` is `nil` for the open-ended top tier.
  """
  @spec all(keyword()) :: [
          %{
            tier: tier(),
            min_score: non_neg_integer(),
            max_score: non_neg_integer() | nil,
            stable_bps: integer(),
            volatile_bps: integer(),
            requires: [attestation()]
          }
        ]
  def all(opts \\ []) do
    @tier_order
    |> Enum.with_index()
    |> Enum.map(fn {tier, index} ->
      next = Enum.at(@tier_order, index + 1)

      %{
        tier: tier,
        min_score: min_score(tier),
        max_score: next && min_score(next) - 1,
        stable_bps: headline_bps(tier, :stable, opts),
        volatile_bps: headline_bps(tier, :volatile, opts),
        requires: @tier_attestation_requirements[tier]
      }
    end)
  end

  @doc "Attestation proofs each tier requires before it can be granted."
  @spec tier_attestation_requirements() :: %{tier() => [attestation()]}
  def tier_attestation_requirements, do: @tier_attestation_requirements

  @doc "The solver spread per asset class -- the layer no tier discounts."
  @spec solver_base_bps() :: %{asset_class() => integer()}
  def solver_base_bps, do: @solver_base_bps

  @doc "Percentage of positive fill slippage kept by the protocol."
  @spec surplus_share_pct() :: integer()
  def surplus_share_pct, do: @surplus_share_pct
end
