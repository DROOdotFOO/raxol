defmodule Raxol.UI.Components.Harness.Ids do
  @moduledoc """
  Shared id-fallback helper for harness components.

  Returns the caller-supplied `:id` from `props` (keyword list or map), or
  the next `"<prefix>-<n>"` from `Raxol.Core.ID`, which counts per process
  so identical boots mint identical ids.
  """

  @spec default_id(keyword() | map(), String.t()) :: term()
  def default_id(props, prefix) when is_list(props),
    do: Keyword.get_lazy(props, :id, fn -> Raxol.Core.ID.next(prefix) end)

  def default_id(props, prefix) when is_map(props),
    do: Map.get_lazy(props, :id, fn -> Raxol.Core.ID.next(prefix) end)
end
