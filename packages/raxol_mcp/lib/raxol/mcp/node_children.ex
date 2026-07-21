defmodule Raxol.MCP.NodeChildren do
  @moduledoc """
  Single source of truth for a UI node's child element nodes as the MCP tree
  consumers traverse them -- tool derivation (`Raxol.MCP.TreeWalker`) and the
  widgets resource (`Raxol.MCP.StructuredScreenshot`).

  Two shape rules must be applied identically by both consumers:

    * The View DSL allows `:children` to be a LIST or a SINGLE element map
      (a box whose do-block is one column) -- the same duality the Bubbler's
      path-finding handles.
    * An `:absolute_layer` (`Raxol.UI.Components.AbsoluteLayer`) parents its
      subtree through `:flow_child` + `:overlays[].element`, NOT `:children`,
      and carries no `:id` of its own.

  When these two consumers each grew their own copy of this walk, a change to
  one (e.g. a new overlay wiring) could silently diverge from the other,
  yielding derived tools for widgets not present in the screenshot resource,
  or vice versa. Keeping the extraction here makes that divergence impossible.
  """

  @doc """
  The child element nodes of `node`, in order: direct `:children` first, then
  the `:absolute_layer` flow child + overlay elements. Empty for a non-map or
  a leaf.
  """
  @spec child_nodes(map() | term()) :: [map()]
  def child_nodes(node) when is_map(node) do
    direct_children(node) ++ absolute_layer_children(node)
  end

  def child_nodes(_node), do: []

  defp direct_children(node) do
    case Map.get(node, :children) do
      kids when is_list(kids) -> kids
      kid when is_map(kid) -> [kid]
      _ -> []
    end
  end

  # The flow child plus each overlay's `:element`. Absent on ordinary nodes
  # (both default to []), so a no-op everywhere except an absolute layer.
  defp absolute_layer_children(node) do
    flow =
      case Map.get(node, :flow_child) do
        child when is_map(child) -> [child]
        _ -> []
      end

    overlay_elements =
      node
      |> Map.get(:overlays, [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{element: element} when is_map(element) -> [element]
        _ -> []
      end)

    flow ++ overlay_elements
  end
end
