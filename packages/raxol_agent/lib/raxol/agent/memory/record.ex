defmodule Raxol.Agent.Memory.Record do
  @moduledoc """
  A single cross-session memory entry.

  Records are plain structs (no Ecto), scoped to an `agent_id`. `tokenize/1`
  is shared by the writer (to build the inverted index) and the searcher (to
  parse a query) so the index and queries always agree on tokenization.
  """

  @enforce_keys [:id, :content]
  defstruct [
    :id,
    :agent_id,
    :content,
    :type,
    :inserted_at,
    :last_accessed,
    :score,
    tags: []
  ]

  @type mem_type :: :decision | :pattern | :gotcha | :link | :insight | :note
  @type t :: %__MODULE__{
          id: String.t(),
          agent_id: String.t() | nil,
          content: String.t(),
          type: mem_type(),
          tags: [String.t()],
          inserted_at: integer(),
          last_accessed: integer(),
          score: float() | nil
        }

  @types ~w(decision pattern gotcha link insight note)a

  @doc "Build a record, filling id, type, tags, and timestamps."
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    now = System.system_time(:second)

    %__MODULE__{
      id: Map.get(attrs, :id) || gen_id(),
      agent_id: Map.get(attrs, :agent_id),
      content: Map.fetch!(attrs, :content),
      type: normalize_type(Map.get(attrs, :type)),
      tags: normalize_tags(Map.get(attrs, :tags, [])),
      inserted_at: Map.get(attrs, :inserted_at) || now,
      last_accessed: Map.get(attrs, :last_accessed) || now,
      score: Map.get(attrs, :score)
    }
  end

  @doc "Downcase, split on non-word boundaries, drop short tokens, dedup."
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) > 2))
    |> Enum.uniq()
  end

  def tokenize(_), do: []

  @doc "The valid memory types."
  @spec types() :: [mem_type()]
  def types, do: @types

  defp gen_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp normalize_type(type) when type in @types, do: type

  defp normalize_type(type) when is_binary(type) do
    Enum.find(@types, :note, &(Atom.to_string(&1) == type))
  end

  defp normalize_type(_), do: :note

  defp normalize_tags(tags) when is_list(tags) do
    tags |> Enum.map(&(&1 |> to_string() |> String.downcase())) |> Enum.uniq()
  end

  defp normalize_tags(_), do: []
end
