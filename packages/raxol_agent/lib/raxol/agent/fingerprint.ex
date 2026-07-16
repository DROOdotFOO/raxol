defmodule Raxol.Agent.Fingerprint do
  @moduledoc """
  Model / params fingerprint — the replay-identity of a provider call
  (`docs/proposals/in-flight/harness-freeze-contracts.md` §2.1, "Model/params
  fingerprint").

  This is the U11 *enabler*. Two things are frozen and real here:

    * `excluded_keys/0` — the **exhaustive, frozen** (grow-only) list of
      ephemeral param keys excluded from `params_hash`. Note `:seed` is NOT
      excluded — it is a sampling parameter and replay identity needs it.
    * the fingerprint *shape* (documented below; asserted by the red suite).

  The ONE normative serializer, `canonical_json/1`, is `:not_implemented` until
  U11-I lands: `params_hash` MUST be `sha256` over exactly this serialization
  (sorted keys) so two independent encoders can never diverge. The red suite
  pins the byte-stability property against it.

  ## Fingerprint shape (frozen)

      %{
        provider:         String.t(),
        name:             String.t(),
        revision:         String.t() | nil,   # OPTIONAL — strict seam must not require it
        params_hash:      String.t(),         # sha256 over canonical_json/1
        params_inline:    %{...},             # capped subset, grow-only keys
        prompt_cache_key: String.t() | nil    # provider telemetry, NOT replay identity
      }
  """

  # Exhaustive, frozen (grow-only) ephemeral-key exclusion list. Everything NOT
  # in this list is included in the hash — in particular `:seed` is INCLUDED.
  @excluded_keys [:request_id, :idempotency_key, :trace_id, :timestamp, :ts]

  # The capped `params_inline` subset (grow-only keys) — the human/audit split.
  @inline_keys [:temperature, :top_p, :max_tokens, :seed]

  @doc """
  The frozen ephemeral-key exclusion list for `params_hash`.

  Grow-only. `:seed` is deliberately absent — it is part of replay identity.
  """
  @spec excluded_keys() :: [atom()]
  def excluded_keys, do: @excluded_keys

  @doc "The capped `params_inline` key set (grow-only)."
  @spec inline_keys() :: [atom()]
  def inline_keys, do: @inline_keys

  @doc """
  The ONE normative canonical JSON serialization of a params object: `sha256`'s
  input, sorted keys, ephemeral keys stripped.

  `:not_implemented` until U11-I. Every golden fixture MUST hash through this so
  two independent encoders cannot diverge.
  """
  @spec canonical_json(map()) :: String.t() | :not_implemented
  def canonical_json(params) when is_map(params), do: :not_implemented

  @doc """
  `sha256` hex of `canonical_json/1` — the `params_hash` field.

  `:not_implemented` until U11-I.
  """
  @spec params_hash(map()) :: String.t() | :not_implemented
  def params_hash(params) when is_map(params), do: :not_implemented
end
