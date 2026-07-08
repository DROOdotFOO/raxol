defmodule Raxol.UI.Rendering.Composer do
  @moduledoc """
  Handles composition of UI rendering trees.
  """


  @doc """
  Composes a render tree or command list from the layout tree.
  Currently a stub; in the future, this will build a render tree or command list,
  potentially processing diffs or layout-specific changes.
  """
  @spec compose_render_tree(
          layout_stage_output :: any(),
          new_tree_for_reference :: map() | nil,
          previous_composed_tree :: any()
        ) :: map() | any()
  def compose_render_tree(
        layout_data,
        _new_tree_for_reference,
        previous_composed_tree
      ) do
    Raxol.Core.Runtime.Log.debug(
      "Composition Stage: Starting with layout_data: #{inspect(layout_data)}, prev_composed_tree: #{inspect(previous_composed_tree)}"
    )

    do_compose_recursive(layout_data, previous_composed_tree)
  end

  # Renamed and modified do_compose_node to be recursive and diff-aware
  defp do_compose_recursive(current_layout_node, previous_composed_node)
       when is_map(current_layout_node) do
    handle_node_composition(
      can_reuse_previous_node?(current_layout_node, previous_composed_node),
      current_layout_node,
      previous_composed_node
    )
  end

  defp do_compose_recursive(current_layout_node, _previous_composed_node)
       when not is_map(current_layout_node) do
    Raxol.Core.Runtime.Log.debug(
      "Composition Stage: Passing through non-map primitive node: #{inspect(current_layout_node)}"
    )

    %{composed_type: :primitive, value: current_layout_node}
  end


  defp can_reuse_previous_node?(current_layout_node, previous_composed_node) do
    is_map(current_layout_node[:layout_attrs]) &&
      current_layout_node[:layout_attrs][:processed_with_diff] == :no_change &&
      is_map(previous_composed_node) &&
      current_layout_node_type(current_layout_node) ==
        previous_composed_node[:original_type]
  end

  defp log_reuse_previous_node(current_layout_node) do
    Raxol.Core.Runtime.Log.debug(
      "Composition Stage: Reusing previous composed node for type: #{current_layout_node_type(current_layout_node)}"
    )
  end

  defp build_new_composed_node(current_layout_node, previous_composed_node) do
    original_type = current_layout_node_type(current_layout_node)
    layout_attrs = current_layout_node[:layout_attrs]

    properties_to_carry_forward =
      Map.drop(current_layout_node, [:children, :layout_attrs, :type])

    composed_children =
      build_composed_children(current_layout_node, previous_composed_node)

    %{
      composed_type: :composed_element,
      original_type: original_type,
      attributes: layout_attrs,
      properties: properties_to_carry_forward,
      children: composed_children
    }
  end

  defp build_composed_children(current_layout_node, previous_composed_node) do
    (current_layout_node[:children] || [])
    |> Enum.with_index()
    |> Enum.map(fn {child_layout_node, idx} ->
      prev_child_composed_node = get_previous_child(previous_composed_node, idx)
      do_compose_recursive(child_layout_node, prev_child_composed_node)
    end)
  end

  defp current_layout_node_type(node) do
    extract_node_type(node)
  end

  defp get_previous_child(previous_composed_node, idx) do
    extract_child_at_index(
      is_map(previous_composed_node) &&
        is_list(previous_composed_node[:children]),
      previous_composed_node,
      idx
    )
  end

  # Removed unused logging functions: log_recomposition_reason/2

  # Removed unused function: log_recomposition_for_map/2

  # Removed unused function: determine_recomposition_reason/2

  # Missing helper functions

  defp extract_child_at_index(false, _previous_composed_node, _idx), do: nil

  defp extract_child_at_index(true, previous_composed_node, idx) do
    children = previous_composed_node[:children]
    extract_child_from_list(is_list(children), children, idx)
  end

  defp extract_child_from_list(false, _children, _idx), do: nil

  defp extract_child_from_list(true, children, idx)
       when idx < length(children) do
    Enum.at(children, idx)
  end

  defp extract_child_from_list(true, _children, _idx), do: nil

  # Removed unused function: handle_recomposition_logging/3

  defp handle_node_composition(
         true,
         current_layout_node,
         previous_composed_node
       ) do
    log_reuse_previous_node(current_layout_node)
    previous_composed_node
  end

  defp handle_node_composition(
         false,
         current_layout_node,
         previous_composed_node
       ) do
    build_new_composed_node(current_layout_node, previous_composed_node)
  end

  # node is always a map in our call sites
  defp extract_node_type(node) when is_map(node) do
    node[:type] || node[:composed_type] || :unknown
  end
end
