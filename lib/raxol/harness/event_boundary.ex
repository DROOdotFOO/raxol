defmodule Raxol.Harness.EventBoundary do
  @moduledoc """
  Normalizes a live session event into the shape
  `Raxol.Harness.Projection.project/2` reads. `raxol_agent` 2.7.0 calls
  `normalize/1`; nothing in this repository does.

  The input is an atom-keyed map or struct whose payload may hold atom
  keys and atom values. The output has atom top-level fields and a payload
  with string keys and JSON-shaped values, as
  `Jason.encode!/1 |> Jason.decode!/1` would give.

  The event comes from another process and is treated as untrusted:

    * No atom is created. Strings stay strings, and atoms in the payload
      become strings.
    * Only `:id`, `:turn_id`, `:ts`, `:family`, `:type`, `:tier`, `:scope`,
      `:provenance` and `:payload` are kept.
    * `:provenance.trust` is `:trusted` or `:tainted`; any other value
      becomes `:tainted`.
    * `:tier` must be `:durable` or `:ephemeral`; anything else is
      `{:error, :invalid_event}`.

  `:type` and `:family` pass through unchanged, atom or not.
  """

  @allowed_keys [
    :id,
    :turn_id,
    :ts,
    :family,
    :type,
    :tier,
    :scope,
    :provenance,
    :payload
  ]

  @doc """
  Normalize a live event into the fixture wire shape.

  Accepts any map, including a struct (fields are read via `Map.get/2`,
  never struct pattern matching, so any atom-keyed struct works).
  Returns `{:ok, map}` on success; `{:error, :invalid_event}` when `:id`,
  `:ts`, `:payload`, or `:tier` fail their respective shape checks (see
  moduledoc).
  """
  @spec normalize(map()) :: {:ok, map()} | {:error, :invalid_event}
  def normalize(event) when is_map(event) do
    with {:ok, id} <- normalize_id(event),
         {:ok, ts} <- normalize_ts(event),
         {:ok, tier} <- normalize_tier(event),
         {:ok, payload} <- normalize_payload(event) do
      {:ok,
       %{
         id: id,
         turn_id: normalize_turn_id(event),
         ts: ts,
         family: Map.get(event, :family),
         type: Map.get(event, :type),
         tier: tier,
         scope: normalize_scope(event),
         provenance: normalize_provenance(event),
         payload: payload
       }}
    end
  end

  def normalize(_other), do: {:error, :invalid_event}

  # -- top-level field checks ------------------------------------------

  defp normalize_id(event) do
    case Map.get(event, :id) do
      id when is_integer(id) and id >= 0 -> {:ok, id}
      _other -> {:error, :invalid_event}
    end
  end

  defp normalize_ts(event) do
    case Map.get(event, :ts) do
      ts when is_integer(ts) -> {:ok, ts}
      _other -> {:error, :invalid_event}
    end
  end

  defp normalize_tier(event) do
    case Map.get(event, :tier) do
      :durable -> {:ok, :durable}
      :ephemeral -> {:ok, :ephemeral}
      _other -> {:error, :invalid_event}
    end
  end

  defp normalize_payload(event) do
    case Map.get(event, :payload) do
      %{} = payload -> {:ok, deep_normalize(payload)}
      _other -> {:error, :invalid_event}
    end
  end

  defp normalize_turn_id(event) do
    case Map.get(event, :turn_id) do
      nil -> nil
      turn_id when is_binary(turn_id) -> turn_id
      other -> inspect(other)
    end
  end

  # `nil` is itself an atom, so this single guard covers both "an atom
  # scope passes through" and "absent (nil) becomes nil" -- no separate
  # nil-handling clause needed.
  defp normalize_scope(event) do
    case Map.get(event, :scope) do
      scope when is_atom(scope) -> scope
      _other -> nil
    end
  end

  # -- provenance (taint-absorbing) ------------------------------------

  defp normalize_provenance(event) do
    case Map.get(event, :provenance) do
      %{} = provenance ->
        %{
          source: normalize_provenance_source(Map.get(provenance, :source)),
          trust: normalize_provenance_trust(Map.get(provenance, :trust))
        }

      _absent_or_malformed ->
        nil
    end
  end

  # `nil` is an atom, so `Atom.to_string(nil)` already does the right
  # thing for an absent source without a separate clause.
  defp normalize_provenance_source(source) when is_atom(source),
    do: Atom.to_string(source)

  defp normalize_provenance_source(source) when is_binary(source), do: source
  defp normalize_provenance_source(other), do: inspect(other)

  defp normalize_provenance_trust(:trusted), do: :trusted
  defp normalize_provenance_trust(:tainted), do: :tainted
  # Taint-absorbing: any other value (an unrecognized atom, a string, a
  # missing key read back as `nil`) is never passed through raw -- this
  # seam may only ADD taint, never remove or launder it.
  defp normalize_provenance_trust(_other), do: :tainted

  # -- payload deep-normalize (never String.to_atom/1) -----------------

  defp deep_normalize(%_struct{} = struct),
    do: struct |> Map.from_struct() |> deep_normalize()

  defp deep_normalize(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {normalize_key(k), deep_normalize(v)} end)

  # `is_list/1` also matches an IMPROPER list in Elixir/Erlang (it only
  # checks the term is `[]` or a cons cell, never that the tail is
  # itself a proper list) -- `List.improper?/1` distinguishes the two
  # cases here rather than crashing on `Enum.map/2` over a non-proper
  # tail.
  defp deep_normalize(list) when is_list(list) do
    if List.improper?(list) do
      inspect(list)
    else
      Enum.map(list, &deep_normalize/1)
    end
  end

  defp deep_normalize(v)
       when is_nil(v) or is_boolean(v) or is_binary(v) or is_number(v),
       do: v

  # Comes after the nil/boolean guard above (both are technically atoms)
  # -- every OTHER atom becomes a string, never minting one on the way
  # out (this only ever consumes an atom that already exists on the
  # input side).
  defp deep_normalize(v) when is_atom(v), do: Atom.to_string(v)

  defp deep_normalize(v)
       when is_tuple(v) or is_pid(v) or is_reference(v) or is_function(v),
       do: inspect(v)

  defp deep_normalize(v), do: inspect(v)

  defp normalize_key(k) when is_binary(k), do: k
  defp normalize_key(k) when is_atom(k), do: Atom.to_string(k)
  defp normalize_key(k), do: inspect(k)

  @doc false
  @spec allowed_keys() :: [atom()]
  def allowed_keys, do: @allowed_keys
end
