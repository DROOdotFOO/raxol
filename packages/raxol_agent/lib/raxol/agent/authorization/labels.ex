defmodule Raxol.Agent.Authorization.Labels do
  @moduledoc """
  Label state for the authorization engine, with monotonic merge.

  Labels are a plain map that policies read (to gate on) and write (verdict
  `writes`). When several policies write the SAME key, a monotonic label keeps the
  MOST-RESTRICTIVE value rather than last-write-wins -- the CRDT-flavored
  `_merge_monotonic_writes` from omnigent. This guarantees a stricter policy can
  never be loosened by a later, more permissive one in the same pass.

  A monotonic spec maps a label key to an ordering, least-restrictive first:

      %{access: [:read, :write, :admin], risk: [:low, :medium, :high]}

  Keys not in the spec merge last-write-wins.
  """

  @type labels :: map()
  @type monotonic :: %{optional(term()) => [term()]}

  @doc """
  Merge `writes` into `labels`. Monotonic keys keep the most-restrictive value;
  other keys take the written value.
  """
  @spec merge(labels(), map(), monotonic()) :: labels()
  def merge(labels, writes, monotonic \\ %{}) do
    Enum.reduce(writes, labels, fn {key, value}, acc ->
      case Map.fetch(monotonic, key) do
        {:ok, ordering} -> Map.put(acc, key, most_restrictive(Map.get(acc, key), value, ordering))
        :error -> Map.put(acc, key, value)
      end
    end)
  end

  # The value with the higher rank in the ordering wins; the incoming value wins
  # ties so an equally-ranked rewrite is idempotent.
  defp most_restrictive(nil, value, _ordering), do: value

  defp most_restrictive(current, value, ordering) do
    if rank(value, ordering) >= rank(current, ordering), do: value, else: current
  end

  defp rank(value, ordering) do
    case Enum.find_index(ordering, &(&1 == value)) do
      nil -> -1
      index -> index
    end
  end
end
