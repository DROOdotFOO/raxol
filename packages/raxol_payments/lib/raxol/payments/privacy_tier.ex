defmodule Raxol.Payments.PrivacyTier do
  @moduledoc """
  Maps trust scores to privacy tiers, fees, and settlement targets.

  Based on the Xochi whitepaper Glass Cube model. Higher trust scores
  unlock deeper privacy at lower fees. Users can always opt into less
  privacy than their score allows.

  ## Attestations are pre-verified

  The `:attestations` this module reads for tier-requirement gating must already
  be **verified** -- the output of `Raxol.Payments.Zksar.verify/2` (which carries
  `valid: true`). `Raxol.Payments.Router` is the verification choke point: it runs
  `Zksar.verify_batch/2` against the operator-pinned issuer allowlist and passes
  only the verified subset here. Do not call `from_trust_score/2` with raw,
  caller-supplied attestations expecting them to be trusted; a self-asserted
  `%{valid: true}` map is not a proof.

  ## Tiers

  | Score | Tier      | Fee (bps) | Settlement |
  | ----- | --------- | --------- | ---------- |
  | --    | Open      | -2        | public     |
  | --    | Public    | 0         | public     |
  | 0-24  | Standard  | 30        | public     |
  | 25-49 | Stealth   | 25        | stealth    |
  | 50-74 | Private   | 20        | shielded   |
  | 75+   | Sovereign | 15        | shielded   |
  """

  @type tier :: :open | :public | :standard | :stealth | :private | :sovereign
  @type settlement :: :public | :stealth | :shielded

  @type t :: %{
          tier: tier(),
          fee_bps: integer(),
          settlement: settlement(),
          data_retention: :full_analytics | :full | :amounts | :ranges | :wallet | :nothing
        }

  @tiers %{
    open: %{fee_bps: -2, settlement: :public, data_retention: :full_analytics},
    public: %{fee_bps: 0, settlement: :public, data_retention: :full},
    standard: %{fee_bps: 30, settlement: :public, data_retention: :amounts},
    stealth: %{fee_bps: 25, settlement: :stealth, data_retention: :ranges},
    private: %{fee_bps: 20, settlement: :shielded, data_retention: :wallet},
    sovereign: %{fee_bps: 15, settlement: :shielded, data_retention: :nothing}
  }

  @tier_order [:open, :public, :standard, :stealth, :private, :sovereign]
  @tier_rank @tier_order |> Enum.with_index() |> Map.new()

  @tier_attestation_requirements %{
    open: [],
    public: [],
    standard: [],
    stealth: [],
    private: [:compliance],
    sovereign: [:compliance, :non_membership]
  }

  @doc """
  Determine privacy tier from a trust score.

  ## Options

  - `:tier_override` -- force a specific tier (user opts into less privacy)
  """
  @spec from_trust_score(non_neg_integer() | nil, keyword()) :: t()
  def from_trust_score(score, opts \\ [])

  def from_trust_score(nil, opts) do
    from_trust_score(0, opts)
  end

  def from_trust_score(score, opts) when is_integer(score) and score >= 0 do
    max_tier = score_to_tier(score)
    attestation_types = extract_attestation_types(opts)
    max_tier = maybe_downgrade_for_attestations(max_tier, attestation_types)

    tier =
      case Keyword.get(opts, :tier_override) do
        nil -> max_tier
        override -> clamp_tier(override, max_tier)
      end

    build(tier)
  end

  @doc "Get tier info for a named tier."
  @spec info(tier()) :: t()
  def info(tier) when is_map_key(@tiers, tier), do: build(tier)

  @doc "List all tiers in ascending privacy order."
  @spec all() :: [t()]
  def all do
    [:open, :public, :standard, :stealth, :private, :sovereign]
    |> Enum.map(&build/1)
  end

  @doc "Check if a settlement type requires PXE bridge."
  @spec shielded?(t()) :: boolean()
  def shielded?(%{settlement: :shielded}), do: true
  def shielded?(_), do: false

  @doc "Required attestation proof types for a given tier."
  @spec attestation_requirements(tier()) :: [atom()]
  def attestation_requirements(tier) when is_map_key(@tier_attestation_requirements, tier) do
    @tier_attestation_requirements[tier]
  end

  # -- Private --

  # Consumes PRE-VERIFIED attestations (Zksar.verify output; Router verifies
  # before calling here). The `valid: true` filter is a guard, not the trust
  # decision -- a raw caller-supplied `valid: true` is meaningless here because it
  # never passed through the Router's `Zksar.verify_batch/2`. See the moduledoc.
  defp extract_attestation_types(opts) do
    case Keyword.get(opts, :attestations) do
      nil ->
        nil

      [] ->
        nil

      attestations when is_list(attestations) ->
        attestations
        |> Enum.filter(&(&1[:valid] == true))
        |> Enum.map(& &1.type)
        |> MapSet.new()
    end
  end

  defp maybe_downgrade_for_attestations(tier, nil), do: tier

  defp maybe_downgrade_for_attestations(tier, attestation_types) do
    required = MapSet.new(@tier_attestation_requirements[tier] || [])

    if MapSet.subset?(required, attestation_types) do
      tier
    else
      downgrade_tier(tier, attestation_types)
    end
  end

  # Walk tiers downward from `tier` until we find one whose attestation
  # requirements are satisfied. Falls back to :standard (which requires []).
  defp downgrade_tier(tier, attestation_types) do
    @tier_order
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 != tier))
    |> Enum.find(:standard, fn t ->
      required = MapSet.new(@tier_attestation_requirements[t] || [])
      MapSet.subset?(required, attestation_types)
    end)
  end

  defp score_to_tier(score) when score >= 75, do: :sovereign
  defp score_to_tier(score) when score >= 50, do: :private
  defp score_to_tier(score) when score >= 25, do: :stealth
  defp score_to_tier(_score), do: :standard

  defp clamp_tier(requested, max_allowed) do
    req_idx = Map.get(@tier_rank, requested, 0)
    max_idx = Map.get(@tier_rank, max_allowed, 0)

    if req_idx <= max_idx do
      requested
    else
      max_allowed
    end
  end

  defp build(tier) do
    Map.put(@tiers[tier], :tier, tier)
  end
end
