defmodule Raxol.Agent.Fingerprint do
  @moduledoc """
  Model / params fingerprint — the replay-identity of a provider call.

  Two things are frozen and real here:

    * `excluded_keys/0` — the **exhaustive, frozen** (grow-only) list of
      ephemeral param keys excluded from `params_hash`. Note `:seed` is NOT
      excluded — it is a sampling parameter and replay identity needs it.
    * `canonical_json/1` — the ONE normative serializer. `params_hash` MUST be
      `sha256` over exactly this serialization (sorted keys, ephemeral keys
      stripped) so two independent encoders can never diverge. The red suite
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
  input.

  Frozen serialization rules:

    * ephemeral keys (`excluded_keys/0`) are stripped at the top level — `:seed`
      is NOT one of them, so it stays in the hash input;
    * keys are stringified and **sorted at EVERY map level**, recursively, so
      map iteration order cannot leak into the hash — a nested object hashes
      the same regardless of insertion order (a top-level-only sort left nested
      maps at BEAM term order, diverging across encoders / the JS UI fork);
    * each scalar is JSON-encoded with `Jason` — the single named encoder, so
      two independent callers cannot diverge on number/string formatting.

  **Key-ordering law (frozen).** Sorting is by Erlang binary order. Canonical
  params keys are guaranteed ASCII (temperature, top_p, max_tokens, seed, and
  additive provider params), and for ASCII strings byte order is identical to
  JS UTF-16 code-unit order — so the JS UI fork (I2) byte-matches without a
  code-unit collator. Non-ASCII canonical keys are out of contract.

  Every golden fixture MUST hash through this so two independent encoders cannot
  diverge.
  """
  @spec canonical_json(map()) :: String.t()
  def canonical_json(params) when is_map(params) do
    params
    |> Map.drop(@excluded_keys)
    |> canonical_encode()
  end

  # Recursive, key-sorted canonicalization. Maps sort their stringified keys at
  # every level; lists preserve order but canonicalize each element; scalars go
  # through the single named encoder. Structs are treated as their map form.
  defp canonical_encode(%_{} = struct),
    do: struct |> Map.from_struct() |> canonical_encode()

  defp canonical_encode(map) when is_map(map) do
    inner =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> Jason.encode!(k) <> ":" <> canonical_encode(v) end)
      |> Enum.join(",")

    "{" <> inner <> "}"
  end

  defp canonical_encode(list) when is_list(list) do
    "[" <> (list |> Enum.map(&canonical_encode/1) |> Enum.join(",")) <> "]"
  end

  defp canonical_encode(scalar), do: Jason.encode!(scalar)

  @doc "`sha256` hex (lower-case) of `canonical_json/1` — the `params_hash` field."
  @spec params_hash(map()) :: String.t()
  def params_hash(params) when is_map(params) do
    :crypto.hash(:sha256, canonical_json(params)) |> Base.encode16(case: :lower)
  end
end
