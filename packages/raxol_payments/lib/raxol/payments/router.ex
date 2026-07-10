defmodule Raxol.Payments.Router do
  @moduledoc """
  Selects the optimal payment protocol based on transfer requirements.

  ## Routing Logic

      Same-chain + HTTP 402 detected -> x402 or MPP (auto-pay plugin)
      Cross-chain transfer          -> Xochi (agent-facing, cash-positive)
      Explicit privacy request      -> Xochi with stealth/shielded settlement
      Direct solver access          -> Riddler (internal, not default)

  When a trust score is provided, the router also determines the
  settlement target (public/stealth/shielded) via `PrivacyTier`.

  Xochi is the default for cross-chain because it's the revenue-positive
  path with tier-based fees. Riddler Commerce is B2B (Coinbase/Shopify)
  and not intended for agent use.
  """

  alias Raxol.Payments.PrivacyTier
  alias Raxol.Payments.Relay.Schemas, as: RelaySchemas
  alias Raxol.Payments.Zksar

  @type privacy :: :public | :stealth | :shielded | :auto

  @doc """
  Select the best protocol for a payment.

  Returns a protocol atom: `:x402`, `:mpp`, `:xochi`, or `:riddler`.

  ## Options

  - `:cross_chain` -- true if source and dest chains differ (default: false)
  - `:privacy` -- `:public`, `:stealth`, `:shielded`, or `:auto` (default: `:auto`)
  - `:protocol` -- force a specific protocol (overrides routing)
  - `:trust_score` -- trust score for privacy tier resolution (used by `settlement_for/1`)
  - `:attestations` -- list of raw ZKSAR proofs (`type_code`/`signature`/`issuer`/...).
    They are verified here (see below) before buying any trust; unverified proofs
    are dropped. Computes the trust score when `:trust_score` is absent.

  ## Attestation trust (fail closed)

  Callers supply *raw, signed* attestations; the router verifies each via
  `Raxol.Payments.Zksar.verify_batch/2` against the operator-pinned issuer
  allowlist BEFORE any proof counts toward the trust score or a privacy-tier
  requirement. This runs on every path (computed-score and explicit-`trust_score`),
  so a self-asserted `%{valid: true}` map with no signature -- or a proof from a
  non-allowlisted issuer -- buys nothing.

      config :raxol_payments, :zksar_allowed_issuers, ["0xoracle..."]

  When the allowlist is unset (the default), no attestation can be verified, so
  none buys trust. An explicit `:trust_score` integer is a separate, caller-owned
  hint and is clamped, not attestation-derived.
  """
  @spec select(keyword()) :: atom()
  def select(opts \\ []) do
    case Keyword.get(opts, :protocol) do
      nil -> auto_select(opts)
      forced -> forced
    end
  end

  @doc """
  Determine the settlement target for a payment.

  Uses trust score when available, falls back to explicit privacy option.

  ## Options

  - `:trust_score` -- non-negative integer trust score
  - `:privacy` -- explicit privacy level (overrides trust score derivation)
  - `:tier_override` -- passed through to `PrivacyTier.from_trust_score/2`
  - `:attestations` -- list of verified ZKSAR proofs (computes trust score if absent)
  """
  @spec settlement_for(keyword()) :: PrivacyTier.settlement()
  def settlement_for(opts \\ []) do
    case Keyword.get(opts, :privacy) do
      p when p in [:public, :stealth, :shielded] ->
        p

      _ ->
        opts = maybe_compute_trust_score(opts)
        score = Keyword.get(opts, :trust_score)
        tier_opts = Keyword.take(opts, [:tier_override, :attestations])
        tier = PrivacyTier.from_trust_score(score, tier_opts)
        tier.settlement
    end
  end

  @doc """
  Compute effective trust score from options.

  Returns the explicit `:trust_score` if present, otherwise aggregates
  from `:attestations`. Returns 0 if neither is provided.
  """
  @spec trust_score_for(keyword()) :: non_neg_integer()
  def trust_score_for(opts \\ []) do
    opts = maybe_compute_trust_score(opts)
    Keyword.get(opts, :trust_score, 0)
  end

  defp auto_select(opts) do
    privacy = Keyword.get(opts, :privacy, :auto)
    cross_chain = Keyword.get(opts, :cross_chain, false)

    resolved_privacy =
      case privacy do
        :auto -> resolve_privacy_from_score(opts)
        explicit -> explicit
      end

    # A Tron leg always routes to the Relay rail, ahead of privacy: Relay is
    # public-only, so a stealth request to Tron is downgraded at the action.
    if tron_leg?(opts),
      do: :relay,
      else: select_protocol(resolved_privacy, cross_chain)
  end

  defp tron_leg?(opts) do
    RelaySchemas.tron_chain?(Keyword.get(opts, :from_chain_id, 0)) or
      RelaySchemas.tron_chain?(Keyword.get(opts, :to_chain_id, 0))
  end

  defp resolve_privacy_from_score(opts) do
    opts = maybe_compute_trust_score(opts)

    case Keyword.get(opts, :trust_score) do
      nil ->
        :auto

      score ->
        tier_opts = Keyword.take(opts, [:tier_override, :attestations])
        tier = PrivacyTier.from_trust_score(score, tier_opts)
        tier.settlement
    end
  end

  @max_trust_score 100

  defp maybe_compute_trust_score(opts) do
    # Verify attestations up front, on every path: the verified subset replaces
    # the caller-supplied list so nothing unverified reaches the score
    # aggregation OR the PrivacyTier tier-requirement check downstream.
    opts = replace_with_verified_attestations(opts)

    case {Keyword.get(opts, :trust_score), Keyword.get(opts, :attestations)} do
      {nil, attestations} when is_list(attestations) and attestations != [] ->
        score = Zksar.TrustScore.aggregate(attestations)
        Keyword.put(opts, :trust_score, clamp_score(score))

      {score, _} when is_integer(score) ->
        Keyword.put(opts, :trust_score, clamp_score(score))

      _ ->
        opts
    end
  end

  # Replace `:attestations` with only the proofs that recover to an allowlisted
  # issuer. A self-asserted map (no signature / not a raw proof) or a proof from
  # an unpinned issuer verifies to nothing, so it cannot buy trust -- fail closed.
  defp replace_with_verified_attestations(opts) do
    case Keyword.get(opts, :attestations) do
      list when is_list(list) and list != [] ->
        Keyword.put(opts, :attestations, verify_attestations(list))

      _ ->
        opts
    end
  end

  defp verify_attestations(attestations) do
    case allowed_issuers() do
      [] ->
        # No trusted-issuer allowlist configured: trust cannot be established, so
        # no attestation is credited (rather than trusting a caller's `valid`).
        []

      issuers ->
        {verified, _errors} = Zksar.verify_batch(attestations, allowed_issuers: issuers)
        verified
    end
  end

  defp allowed_issuers do
    :raxol_payments
    |> Application.get_env(:zksar_allowed_issuers, [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  # A trust score is a non-negative 0..100 value, but callers can pass any
  # integer (an explicit override, an aggregation quirk). Clamp to the valid
  # band so an out-of-range score degrades to the nearest tier -- below 0 is
  # the least trusted (public), above 100 the most -- rather than crashing
  # `PrivacyTier.from_trust_score/2` or leaking a negative through `trust_score_for/1`.
  defp clamp_score(score), do: score |> max(0) |> min(@max_trust_score)

  defp select_protocol(privacy, _cross_chain) when privacy in [:stealth, :shielded], do: :xochi
  defp select_protocol(_privacy, true), do: :xochi
  defp select_protocol(_privacy, _cross_chain), do: :x402
end
