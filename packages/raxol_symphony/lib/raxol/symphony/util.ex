defmodule Raxol.Symphony.Util do
  @moduledoc "Small shared helpers for Symphony internals."

  @doc "True for nil, empty, or whitespace-only strings; false for any other value."
  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(s) when is_binary(s), do: String.trim(s) == ""
  def blank?(_), do: false
end
