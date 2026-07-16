defmodule Raxol.Agent.Red.MetaOracle do
  @moduledoc """
  Independent reference oracle for the U11 meta family (FI-5) —
  `docs/proposals/in-flight/harness-freeze-contracts.md` §2.

  This is the **independent decoder** (meta-invariant m6, oracle independence):
  a small, hand-written model of the frozen contract that the U11-R red suite
  compares the real `Raxol.Agent.Meta` seam against, and that the negative
  controls mutate to prove each red has teeth (meta-invariant m4).

  Records are string-keyed maps exactly as the tolerant Reader
  (`Raxol.Agent.Journal.FileStore.Reader`) returns them. Nothing here consults
  `Raxol.Agent.Meta` — the whole point is a second, disagreeing implementation.

  Each seam has a `*_correct` reference **and** one or more `*_<injector>`
  broken variants named for the freeze's dead injectors (N-U11.1 … N-U11.10).
  """

  alias Raxol.Agent.Meta.Registry

  # ===========================================================================
  # Record accessors (string-keyed, Reader-shaped)
  # ===========================================================================

  @doc "The record's `family` as an atom (`:loop` / `:meta`)."
  def family(%{"family" => f}), do: existing_atom(f)
  def family(_), do: :loop

  @doc "The record's `type` as an atom."
  def type(%{"type" => t}) when is_binary(t), do: existing_atom(t)
  def type(%{"type" => t}) when is_atom(t), do: t

  # Bounded token conversion — an independent mirror of the impl's atom-table
  # DoS guard (never `String.to_atom/1` on record input: one copy-paste from a
  # generator-token corpus would otherwise reintroduce the exact VM-crashing
  # DoS the impl's `decode_token` was hardened against). Every registered
  # family/type/kind is already interned, so a KNOWN token resolves to its
  # atom; an unknown token stays a raw binary.
  defp existing_atom(value) when is_atom(value), do: value

  defp existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  @doc "The record's journal offset."
  def offset(%{"id" => id}), do: id

  @doc "The `refs` list from the payload (default `[]`)."
  def refs(%{"payload" => %{"refs" => refs}}) when is_list(refs), do: refs
  def refs(_), do: []

  @doc "The STORED trust on a record's provenance (`:trusted` / `:tainted`)."
  def stored_trust(%{"provenance" => %{"trust" => "tainted"}}), do: :tainted
  def stored_trust(%{"provenance" => %{"trust" => "trusted"}}), do: :trusted
  # Grandfather / missing provenance decodes to the frozen default.
  def stored_trust(_), do: :trusted

  defp index(records), do: Map.new(records, fn r -> {offset(r), r} end)

  defp meta?(r), do: family(r) == :meta

  # ===========================================================================
  # Producer seam — validate/1 (N-U11.1, N-U11.2, N-U11.4, N-U11.10)
  # ===========================================================================

  @doc """
  Correct producer-strict validator. `event` is an atom-keyed map with
  `:family`, `:type`, `:payload`, and optional `:scope`.
  """
  def validate_correct(%{family: :meta, type: type, payload: payload} = event) do
    scope = Map.get(event, :scope, :session)

    cond do
      not Registry.known?(type) ->
        {:error, {:unknown_meta_type, type}}

      (missing = missing_keys(type, payload)) != [] ->
        {:error, {:invalid_meta_payload, type, missing}}

      type == :promote and Map.get(payload, :refs, []) == [] ->
        {:error, :provenance_required}

      scope == :global and Registry.scope(type) != :global ->
        {:error, {:scope_violation, type}}

      true ->
        :ok
    end
  end

  def validate_correct(_non_meta), do: :ok

  defp missing_keys(type, payload) do
    required = Registry.required_keys(type) || []
    Enum.reject(required, fn k -> Map.has_key?(payload, k) end)
  end

  @doc "N-U11.1 dead injector — pass-through emit seam (accepts unknown types)."
  def validate_pass_through(_event), do: :ok

  @doc "N-U11.2 dead injector — required-key sets emptied (accepts missing keys)."
  def validate_empty_required(%{family: :meta, type: type} = event) do
    if Registry.known?(type) do
      # scope check kept, required-key check dropped
      scope = Map.get(event, :scope, :session)

      if scope == :global and Registry.scope(type) != :global,
        do: {:error, {:scope_violation, type}},
        else: :ok
    else
      {:error, {:unknown_meta_type, type}}
    end
  end

  def validate_empty_required(_), do: :ok

  @doc "N-U11.4 dead injector — scope check deleted (accepts :global anywhere)."
  def validate_no_scope_check(%{family: :meta, type: type, payload: payload}) do
    cond do
      not Registry.known?(type) ->
        {:error, {:unknown_meta_type, type}}

      (m = missing_keys(type, payload)) != [] ->
        {:error, {:invalid_meta_payload, type, m}}

      type == :promote and Map.get(payload, :refs, []) == [] ->
        {:error, :provenance_required}

      true ->
        :ok
    end
  end

  def validate_no_scope_check(_), do: :ok

  @doc "N-U11.10 dead injector — speculation `:begin` refs hardcoded to length 1."
  def validate_singular_refs(
        %{family: :meta, type: :speculation, payload: payload} = event
      ) do
    with :ok <- validate_correct(event) do
      case payload do
        %{phase: :begin, refs: refs} when length(refs) == 1 ->
          :ok

        %{phase: :begin} ->
          {:error, {:invalid_meta_payload, :speculation, [:refs]}}

        _ ->
          :ok
      end
    end
  end

  def validate_singular_refs(event), do: validate_correct(event)

  # ===========================================================================
  # Reader seam — decode tolerance (N-U11.6)
  # ===========================================================================

  @doc "Correct reader-tolerant decode: unknown meta type is preserved, never errors."
  def decode_correct(record), do: {:ok, record}

  @doc "N-U11.6 dead injector — producer-strictness applied at the reader seam."
  def decode_strict(record) do
    if meta?(record) and not Registry.known?(type(record)) do
      {:error, {:unknown_meta_type, type(record)}}
    else
      {:ok, record}
    end
  end

  # ===========================================================================
  # Taint algebra — derive_taint / taint_violations (N-U11.3, N-U11.5)
  # ===========================================================================

  @doc """
  Correct taint derivation: `%{offset => trust}` for every meta event, by the
  two-point tainted-absorbing algebra over `refs` (recursively). Loop events
  keep their stored (entry-point) trust.
  """
  def derive_taint_correct(records) do
    idx = index(records)

    for r <- records, meta?(r), into: %{} do
      {offset(r), derived_trust(r, idx, MapSet.new())}
    end
  end

  # Recursive tainted-absorbing meet over refs. Loop events anchor with stored
  # trust; meta events derive from their refs (cycle-guarded).
  defp derived_trust(record, idx, seen) do
    id = offset(record)

    cond do
      MapSet.member?(seen, id) ->
        :trusted

      not meta?(record) ->
        stored_trust(record)

      true ->
        seen = MapSet.put(seen, id)

        tainted? =
          record
          |> refs()
          |> Enum.any?(fn ref ->
            case Map.get(idx, ref) do
              nil -> false
              ref_rec -> derived_trust(ref_rec, idx, seen) == :tainted
            end
          end)

        if tainted?, do: :tainted, else: :trusted
    end
  end

  @doc "N-U11.3 dead injector — producer hardcodes trust `:trusted`."
  def derive_taint_hardcode_trusted(records) do
    for r <- records, meta?(r), into: %{}, do: {offset(r), :trusted}
  end

  @doc """
  N-U11.5 dead injector — a "launder" branch: any `promote` is treated as
  sanitized and upgraded to `:trusted` regardless of tainted refs.
  """
  def derive_taint_launder(records) do
    idx = index(records)

    for r <- records, meta?(r), into: %{} do
      trust =
        if type(r) == :promote,
          do: :trusted,
          else: derived_trust(r, idx, MapSet.new())

      {offset(r), trust}
    end
  end

  @doc """
  Correct taint-violation fold: the offsets where a record's STORED trust
  disagrees with the derived answer (`:taint_violation` markers, OQ-U11.3).
  """
  def taint_violations_correct(records) do
    derived = derive_taint_correct(records)

    for r <- records, meta?(r), derived[offset(r)] != stored_trust(r) do
      %{offset: offset(r), stored: stored_trust(r), derived: derived[offset(r)]}
    end
  end

  # ===========================================================================
  # Actor fold — fold_actors (N-U11.8)
  # ===========================================================================

  @doc """
  Correct actor fold: `%{offset => actor}` for every `kind: "event"` record;
  an absent actor folds to `%{kind: :system}` by rule.
  """
  def fold_actors_correct(records) do
    for r <- records, event?(r), into: %{}, do: {offset(r), decode_actor(r)}
  end

  defp event?(r), do: Map.get(r, "kind", "event") == "event"

  defp decode_actor(%{"actor" => %{"kind" => k} = a}) do
    %{kind: existing_atom(k), id: Map.get(a, "id")}
  end

  # Absent actor => system, BY RULE (never inferred as human/agent).
  defp decode_actor(_), do: %{kind: :system}

  @doc "N-U11.8 dead injector — reader infers `:agent` from an absent actor."
  def fold_actors_infer(records) do
    for r <- records, event?(r), into: %{} do
      actor =
        case r do
          %{"actor" => %{"kind" => k} = a} ->
            %{kind: existing_atom(k), id: Map.get(a, "id")}

          _ ->
            %{kind: :agent}
        end

      {offset(r), actor}
    end
  end

  # ===========================================================================
  # Loop projection — fold independence (N-U11.7)
  # ===========================================================================

  @doc "Correct loop-only projection: the ordered `{offset, type}` of loop events."
  def loop_projection_correct(records) do
    for r <- records, family(r) == :loop, do: {offset(r), type(r)}
  end

  @doc "N-U11.7 dead injector — fold does not filter on family before projecting."
  def loop_projection_unfiltered(records) do
    for r <- records, do: {offset(r), type(r)}
  end

  # ===========================================================================
  # Fingerprint precedence — what_produced (N-U11.9)
  # ===========================================================================

  @doc """
  Correct precedence: the `item_completed` at `offset` wins for "what produced
  this content" — its own payload fingerprint.
  """
  def what_produced_correct(records, offset) do
    case Enum.find(records, fn r -> offset(r) == offset end) do
      %{"payload" => %{"fingerprint" => fp}} -> fp
      _ -> nil
    end
  end

  @doc "N-U11.9 dead injector — fold reads the session-head config as what-produced."
  def what_produced_head(records, _offset) do
    case Enum.find(records, fn r -> Map.get(r, "type") == "head_config" end) do
      %{"payload" => %{"fingerprint" => fp}} -> fp
      _ -> nil
    end
  end

  # ===========================================================================
  # Canonical JSON — normative fingerprint serializer (P-U11.7 / P-U11.1)
  # ===========================================================================

  @doc """
  Reference canonical serialization: sorted keys, ephemeral keys stripped,
  `:seed` INCLUDED. The independent oracle for `Raxol.Agent.Fingerprint.canonical_json/1`.
  """
  def canonical_json_correct(params) when is_map(params),
    do: canonical_encode(params)

  # Deterministic, key-sorted encoding independent of Jason map ordering.
  defp canonical_encode(params) do
    params
    |> Map.drop(Raxol.Agent.Fingerprint.excluded_keys())
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {k, v} -> Jason.encode!(k) <> ":" <> Jason.encode!(v) end)
    |> Enum.join(",")
    |> then(&("{" <> &1 <> "}"))
  end
end
