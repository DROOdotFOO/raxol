defmodule Raxol.Agent.Code.EventCodec do
  @moduledoc """
  Decode persisted durable contract events back into the projection wire
  shape, so a resumed session can rebuild its visual transcript.

  Live events are `Raxol.Harness.EventBoundary`-normalized maps — atom
  top-level fields, an atom `type`/`family`/`tier`/`scope`, and a
  **string-keyed** payload. Persisting them as JSON stringifies every
  top-level key and those enum values (the payload already round-trips
  unchanged). `decode_all/1` reverses that: it re-atomizes the top-level
  keys and the enum values **from fixed vocabularies only** — an
  unrecognized `type` string is left as a string (which
  `Raxol.Harness.Projection` already demotes safely), never minted into an
  atom. Nothing on disk can grow the atom table.

  The output is exactly what `Raxol.Harness.Projection.project/1` consumes,
  so a decoded stream renders identically to the live one it was saved from.
  """

  # The frozen loop vocabulary (mirrors Raxol.Agent.Contract's v0 types plus
  # the approval/state markers the projection understands).
  @loop_types ~w(
    turn_started item_started item_delta item_completed turn_completed
    error approval_requested approval_decided state_change idle
  )a
  @type_lookup Map.new(@loop_types, &{Atom.to_string(&1), &1})

  @families %{"loop" => :loop, "meta" => :meta}
  @tiers %{"durable" => :durable, "ephemeral" => :ephemeral}
  @scopes %{"session" => :session, "global" => :global}
  @sources %{"primary" => :primary, "meta" => :meta}
  @trust %{"trusted" => :trusted, "tainted" => :tainted}

  @doc "Decode a list of persisted event records into projection events."
  @spec decode_all([map()]) :: [map()]
  def decode_all(records) when is_list(records) do
    records
    |> Enum.map(&decode/1)
    |> Enum.reject(&is_nil/1)
  end

  def decode_all(_other), do: []

  @doc "Decode one persisted record; `nil` if it has no integer id."
  @spec decode(map()) :: map() | nil
  def decode(%{"id" => id} = record) when is_integer(id) do
    %{
      id: id,
      turn_id: string_or_nil(Map.get(record, "turn_id")),
      ts: integer(Map.get(record, "ts")),
      family: Map.get(@families, Map.get(record, "family"), :loop),
      # An unknown type stays a string — the projection demotes it safely
      # (N-DORM-04) rather than us minting an atom from disk.
      type: decode_type(Map.get(record, "type")),
      tier: Map.get(@tiers, Map.get(record, "tier"), :durable),
      scope: Map.get(@scopes, Map.get(record, "scope"), :session),
      provenance: decode_provenance(Map.get(record, "provenance")),
      payload: payload(Map.get(record, "payload"))
    }
  end

  def decode(_other), do: nil

  defp decode_type(type) when is_binary(type), do: Map.get(@type_lookup, type, type)
  defp decode_type(_other), do: nil

  defp decode_provenance(%{"source" => source, "trust" => trust}) do
    %{
      source: Map.get(@sources, source, :primary),
      trust: Map.get(@trust, trust, :trusted)
    }
  end

  defp decode_provenance(_other), do: %{source: :primary, trust: :trusted}

  # Payload round-trips unchanged (string keys, JSON values) — exactly the
  # fixture wire shape the projection reads.
  defp payload(%{} = payload), do: payload
  defp payload(_other), do: %{}

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_other), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_other), do: 0
end
