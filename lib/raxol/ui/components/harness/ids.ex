defmodule Raxol.UI.Components.Harness.Ids do
  @moduledoc """
  Shared id-fallback helper for harness components.

  Returns the caller-supplied `:id` from `props` (keyword list or map),
  or a fresh `"<prefix>-<n>"` where `n` is a positive unique integer.
  """

  @spec default_id(keyword() | map(), String.t()) :: term()
  def default_id(props, prefix) when is_list(props),
    do: Keyword.get(props, :id, generate(prefix))

  def default_id(props, prefix) when is_map(props),
    do: Map.get(props, :id, generate(prefix))

  defp generate(prefix), do: "#{prefix}-#{:erlang.unique_integer([:positive])}"
end
