defmodule Raxol.Core.ID do
  @moduledoc """
  Deterministic id minting for component instances.

  Component ids only need to be unique within one rendered tree: every
  consumer (MCP tool names, `data-raxol-id` DOM attributes,
  `{:component_event, id, _}` routing) is scoped to the process that rendered
  the tree. `:erlang.unique_integer/1` bought VM-global uniqueness nobody
  needed at the price of a different id on every boot, which put throwaway
  ids into committed recordings (`surface.mcp.json` carried "tool-call-293",
  an id no agent would ever see again) and into derived MCP tool names.

  A per-process, per-prefix counter keeps the same within-tree guarantee
  (component `init/1` runs in the owning app's process) and mints the same
  ids on every identical boot. The counter lives in the process dictionary
  on purpose: it is incidental per-process state with no reader outside this
  module, the same shape as `:rand`'s seed.
  """

  @doc """
  The next id for `prefix` in this process: "prefix-1", "prefix-2", ...
  """
  @spec next(String.t()) :: String.t()
  def next(prefix) when is_binary(prefix) do
    "#{prefix}-#{bump(prefix)}"
  end

  @doc """
  Generates a string identifier unique within this process.

  Deterministic across identical boots; see `next/1` for the reasoning.
  Not universally unique like UUIDs.
  """
  @spec generate() :: String.t()
  def generate do
    :bare |> bump() |> Integer.to_string()
  end

  @doc """
  Forgets every counter in this process.

  For recorders that fold several apps' `init`s inside one process and need
  each fold to mint the ids a fresh boot would.
  """
  @spec reset() :: :ok
  def reset do
    for {{__MODULE__, _} = key, _} <- Process.get(), do: Process.delete(key)
    :ok
  end

  defp bump(name) do
    key = {__MODULE__, name}
    n = (Process.get(key) || 0) + 1
    Process.put(key, n)
    n
  end
end
