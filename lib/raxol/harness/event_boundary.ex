defmodule Raxol.Harness.EventBoundary do
  @moduledoc """
  The live-session security seam: converts a live agent contract event
  (atom-keyed struct/map, atom payload keys AND atom payload values --
  e.g. `payload: %{item_type: :tool_use}`) into the fixture wire shape
  `Raxol.Harness.Projection.project/2` and the stall detector already
  consume (atom top-level fields; payload with STRING keys and
  JSON-shaped values -- exactly what `Jason.encode!/1 |> Jason.decode!/1`
  would produce).

  ## Security posture

  A live event crosses a PROCESS boundary (`Raxol.Harness.SessionLane`'s
  `subscribe/1` delivers `{:session_event, session_id, event}` messages
  from a process this package does not control) and is therefore
  untrusted input, not merely differently-shaped input. `normalize/1`
  enforces four properties, every one load-bearing:

    * **No atom minting.** `String.to_atom/1` is never called anywhere in
      this module -- an attacker (or a buggy producer) who controls
      `type`/`family`/payload key or value strings must never be able to
      grow the atom table by sending events. Every string stays a
      string; every already-existing atom on the INPUT side is turned
      into a string on the way out (never the reverse).
    * **Unknown fields are dropped.** The output map carries ONLY the
      nine fields the projection/status-strip pipeline understands
      (`:id`, `:turn_id`, `:ts`, `:family`, `:type`, `:tier`, `:scope`,
      `:provenance`, `:payload`) -- anything else on the input (extra
      struct fields, a producer's internal bookkeeping) never reaches
      the surface.
    * **Taint is never laundered.** `:provenance.trust` accepts exactly
      `:trusted` and `:tainted` from the input; every other value
      (including an unrecognized atom, `nil`, or a missing key) is
      absorbed to `:tainted` -- this seam may only ever ADD taint on an
      ambiguous signal, never remove it.
    * **`:tier` is never guessed.** Tier decides whether content becomes
      permanent transcript (`Raxol.Harness.Fixture.Event`'s own
      `:durable`/`:ephemeral` split). Anything other than the two
      literal atoms `:durable`/`:ephemeral` is a hard `{:error,
      :invalid_event}` -- there is no safe default to fall back to.

  `:type` and `:family` are the one deliberate exception to "never pass
  untyped data through": both pass through UNCHANGED, whether the input
  value is an atom or not. `Raxol.Harness.Projection.Recovery`'s own
  partitioning already treats a non-atom `:type`/unrecognized `:family`
  as unrecognized and demotes it safely (N-DORM-04) -- this boundary
  would only be "fixing" that by minting a fresh atom out of whatever a
  hostile string claims to be, which is exactly the failure mode this
  module exists to prevent.
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
