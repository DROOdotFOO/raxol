defmodule Raxol.UI.Rendering.TreeDiffer do
  @moduledoc """
  Provides functions to compute the difference (diff) between two UI trees.
  This module is responsible for identifying changes, additions, removals,
  and reordering of nodes, supporting both keyed and non-keyed children.
  """

  # All Kernel functions are now available


  @doc """
  Computes the minimal set of changes (diff) between two UI trees.

  Returns:

    * `:no_change` if trees are identical
    * `{:replace, new_tree}` if the root node differs significantly
    * `{:update, path, changes}` for subtree updates. `path` is a list of indices
      to the parent node, and `changes` describes the modifications to its children
      (either as indexed diffs or keyed operations).

  The `path` in `{:update, path, changes}` always refers to the parent node whose
  children have changed. For keyed children, the recursive diffs for individual
  children (e.g., in `{:key_update, key, child_diff}`) will have their own paths
  relative to that child (i.e., starting with `[]` if the child itself is the root
  of that sub-diff).
  """
  @spec diff_trees(old_tree :: map() | nil, new_tree :: map() | nil) ::
          :no_change
          | {:replace, map()}
          | {:update, [integer()], any()}
  def diff_trees(old_tree, new_tree), do: do_diff_trees(old_tree, new_tree, [])

  # `rev_path` is the path to the current node, stored in reverse so we can
  # prepend the next index in O(1). It is reversed once at the output
  # boundaries (`process_child_diffs`, `select_keyed_diff_result`) so callers
  # still see the public path in forward order.
  defp do_diff_trees(nil, nil, _rev_path), do: :no_change
  defp do_diff_trees(nil, new, _rev_path), do: {:replace, new}
  defp do_diff_trees(_old, nil, _rev_path), do: {:replace, nil}
  defp do_diff_trees(old, new, _rev_path) when old == new, do: :no_change

  defp do_diff_trees(%{type: t1} = _old, %{type: t2} = new, _rev_path)
       when t1 != t2 do
    {:replace, new}
  end

  defp do_diff_trees(
         %{type: type, children: old_children} = _old,
         %{type: type, children: new_children} = _new,
         rev_path
       ) do
    attempt_keyed_diff =
      are_children_consistently_keyed?(old_children) &&
        are_children_consistently_keyed?(new_children)

    children_diff_result =
      perform_children_diff(
        attempt_keyed_diff,
        old_children,
        new_children,
        rev_path
      )

    case children_diff_result do
      :no_change -> :no_change
      other -> other
    end
  end

  # Fallback for non-map nodes or nodes without :children that are not identical
  defp do_diff_trees(_old, new, _rev_path), do: {:replace, new}

  defp perform_children_diff(true, old_children, new_children, rev_path) do
    perform_keyed_children_diff(old_children, new_children, rev_path)
  end

  defp perform_children_diff(false, old_children, new_children, rev_path) do
    perform_non_keyed_children_diff(old_children, new_children, rev_path)
  end

  # Helper to check if a list of children is consistently keyed
  defp are_children_consistently_keyed?(children) when is_list(children) do
    check_keyed_consistency(children)
  end

  defp are_children_consistently_keyed?(_other), do: false

  defp check_keyed_consistency([]), do: true

  defp check_keyed_consistency(children) do
    Enum.all?(children, fn
      child when is_map(child) -> Map.has_key?(child, :key)
      _non_map_child -> false
    end)
  end

  defp validate_child_has_key!(nil, _list_name), do: :ok

  defp validate_child_has_key!(child, list_name) when not is_map(child) do
    Raxol.Core.Runtime.Log.warning(
      "Keyed diffing expected map child in #{list_name}, got: #{inspect(child)}. Problems may occur."
    )

    :ok
  end

  defp validate_child_has_key!(child, list_name) do
    validate_key_presence(Map.has_key?(child, :key), child, list_name)
  end

  defp validate_key_presence(false, child, list_name) do
    Raxol.Core.Runtime.Log.error(
      "Child in #{list_name} is missing :key for keyed diffing: #{inspect(child)}"
    )

    # Consider raising: raise ArgumentError, "Child in #{list_name} missing :key: #{inspect(child)}"
    :ok
  end

  defp validate_key_presence(true, _child, _list_name), do: :ok

  defp perform_non_keyed_children_diff(old_children, new_children, rev_path) do
    child_diffs =
      zip_longest(old_children, new_children)
      |> Enum.with_index()
      |> Enum.map(fn
        {{old_child, new_child}, idx} ->
          case do_diff_trees(old_child, new_child, [idx | rev_path]) do
            :no_change -> nil
            diff_for_child_at_idx -> {idx, diff_for_child_at_idx}
          end
      end)
      |> Enum.reject(&is_nil/1)

    process_child_diffs(child_diffs, rev_path)
  end

  defp process_child_diffs([], _rev_path), do: :no_change

  defp process_child_diffs(child_diffs, rev_path) do
    {:update, Enum.reverse(rev_path),
     %{type: :indexed_children, diffs: child_diffs}}
  end

  defp perform_keyed_children_diff(
         old_children_list,
         new_children_list,
         rev_path_to_parent
       ) do
    old_children_map_by_key =
      build_children_map_by_key(old_children_list, "old_children_list")

    new_children_map_by_key =
      build_children_map_by_key(new_children_list, "new_children_list")

    old_keys_set = Map.keys(old_children_map_by_key) |> MapSet.new()
    new_keys_set = Map.keys(new_children_map_by_key) |> MapSet.new()
    new_keys_ordered = Enum.map(new_children_list || [], & &1[:key])

    ops =
      build_keyed_operations(
        old_children_map_by_key,
        new_children_list,
        old_keys_set,
        new_keys_set
      )

    determine_keyed_diff_result(
      ops,
      old_children_list,
      new_keys_ordered,
      rev_path_to_parent
    )
  end

  defp build_children_map_by_key(children_list, list_name) do
    Map.new(children_list || [], fn child ->
      validate_child_has_key!(child, list_name)
      {child[:key], child}
    end)
  end

  defp build_keyed_operations(
         old_children_map_by_key,
         new_children_list,
         old_keys_set,
         new_keys_set
       ) do
    add_and_update_ops =
      build_add_and_update_operations(
        old_children_map_by_key,
        new_children_list,
        old_keys_set
      )

    remove_ops = build_remove_operations(old_keys_set, new_keys_set)

    remove_ops ++ add_and_update_ops
  end

  defp build_add_and_update_operations(
         old_children_map_by_key,
         new_children_list,
         old_keys_set
       ) do
    Enum.reduce(new_children_list || [], [], fn new_child_node, acc ->
      key = new_child_node[:key]

      process_keyed_child(
        MapSet.member?(old_keys_set, key),
        old_children_map_by_key,
        new_child_node,
        key,
        acc
      )
    end)
  end

  defp process_keyed_child(
         true,
         old_children_map_by_key,
         new_child_node,
         key,
         acc
       ) do
    handle_existing_key(old_children_map_by_key, new_child_node, key, acc)
  end

  defp process_keyed_child(
         false,
         _old_children_map_by_key,
         new_child_node,
         key,
         acc
       ) do
    [{:key_add, key, new_child_node} | acc]
  end

  defp handle_existing_key(old_children_map_by_key, new_child_node, key, acc) do
    old_child_node = old_children_map_by_key[key]
    child_diff = do_diff_trees(old_child_node, new_child_node, [])

    case child_diff do
      :no_change -> acc
      _ -> [{:key_update, key, child_diff} | acc]
    end
  end

  defp build_remove_operations(old_keys_set, new_keys_set) do
    Enum.reduce(MapSet.to_list(old_keys_set), [], fn old_key, acc ->
      process_old_key(MapSet.member?(new_keys_set, old_key), old_key, acc)
    end)
  end

  defp process_old_key(false, old_key, acc) do
    [{:key_remove, old_key} | acc]
  end

  defp process_old_key(true, _old_key, acc) do
    acc
  end

  defp determine_keyed_diff_result(
         ops,
         old_children_list,
         new_keys_ordered,
         rev_path_to_parent
       ) do
    has_structural_changes = ops != []
    old_keys_ordered = Enum.map(old_children_list || [], & &1[:key])
    order_changed = old_keys_ordered != new_keys_ordered

    select_keyed_diff_result(
      has_structural_changes,
      order_changed,
      ops,
      new_keys_ordered,
      rev_path_to_parent
    )
  end

  defp select_keyed_diff_result(
         false,
         false,
         _ops,
         _new_keys_ordered,
         _rev_path_to_parent
       ) do
    :no_change
  end

  defp select_keyed_diff_result(
         false,
         true,
         _ops,
         new_keys_ordered,
         rev_path_to_parent
       ) do
    {:update, Enum.reverse(rev_path_to_parent),
     %{type: :keyed_children, ops: [{:key_reorder, new_keys_ordered}]}}
  end

  defp select_keyed_diff_result(
         true,
         _order_changed,
         ops,
         new_keys_ordered,
         rev_path_to_parent
       ) do
    # Partition ops so that :key_reorder is always last
    {_reorder_ops, other_ops} =
      Enum.split_with(ops, fn
        {:key_reorder, _} -> true
        _ -> false
      end)

    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    all_ops = other_ops ++ [{:key_reorder, new_keys_ordered}]

    {:update, Enum.reverse(rev_path_to_parent),
     %{type: :keyed_children, ops: all_ops}}
  end

  defp zip_longest(a, b), do: Raxol.Core.Utils.List.zip_longest(a, b)
end
