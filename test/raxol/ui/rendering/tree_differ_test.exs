defmodule Raxol.UI.Rendering.TreeDifferTest do
  use ExUnit.Case, async: true
  # Changed from Pipeline to TreeDiffer
  alias Raxol.UI.Rendering.TreeDiffer

  describe "diff_trees/2" do
    # --- Basic Cases ---
    test "returns :no_change for two nils" do
      assert TreeDiffer.diff_trees(nil, nil) == :no_change
    end

    test "returns :replace for nil old tree and new tree" do
      new_tree = %{type: :div, children: []}
      assert TreeDiffer.diff_trees(nil, new_tree) == {:replace, new_tree}
    end

    test "returns :replace for old tree and nil new tree" do
      old_tree = %{type: :div, children: []}
      assert TreeDiffer.diff_trees(old_tree, nil) == {:replace, nil}
    end

    test "returns :no_change for identical trees" do
      tree = %{type: :div, children: [%{type: :span, content: "hello"}]}
      assert TreeDiffer.diff_trees(tree, tree) == :no_change
    end

    test "returns :replace when root types differ" do
      old_tree = %{type: :div}
      new_tree = %{type: :span}
      assert TreeDiffer.diff_trees(old_tree, new_tree) == {:replace, new_tree}
    end

    # --- Non-Keyed Children ---

    test "non-keyed: adds a child to an empty list" do
      old_tree = %{type: :ul, children: []}
      new_child = %{type: :li, content: "item 1"}
      new_tree = %{type: :ul, children: [new_child]}

      expected_diff =
        {:update, [],
         %{type: :indexed_children, diffs: [{0, {:replace, new_child}}]}}

      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end

    test "non-keyed: removes a child" do
      old_child = %{type: :li, content: "item 1"}
      old_tree = %{type: :ul, children: [old_child]}
      new_tree = %{type: :ul, children: []}

      expected_diff =
        {:update, [], %{type: :indexed_children, diffs: [{0, {:replace, nil}}]}}

      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end

    test "non-keyed: updates a child" do
      old_child = %{type: :li, content: "item 1 old"}
      new_child = %{type: :li, content: "item 1 new"}
      old_tree = %{type: :ul, children: [old_child]}
      new_tree = %{type: :ul, children: [new_child]}
      expected_child_diff = {:replace, new_child}

      expected_diff =
        {:update, [],
         %{type: :indexed_children, diffs: [{0, expected_child_diff}]}}

      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end

    test "non-keyed: adds multiple children" do
      old_tree = %{type: :ul, children: []}
      child1 = %{type: :li, content: "item 1"}
      child2 = %{type: :li, content: "item 2"}
      new_tree = %{type: :ul, children: [child1, child2]}

      expected_diff =
        {:update, [],
         %{
           type: :indexed_children,
           diffs: [
             {0, {:replace, child1}},
             {1, {:replace, child2}}
           ]
         }}

      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end

    test "non-keyed: no change in children" do
      child1 = %{type: :li, content: "item 1"}
      tree = %{type: :ul, children: [child1]}
      assert TreeDiffer.diff_trees(tree, tree) == :no_change
    end

    # --- Keyed Children ---

    test "keyed: adds a child" do
      old_tree = %{type: :ul, children: []}
      new_child = %{type: :li, key: "a", content: "item A"}
      new_tree = %{type: :ul, children: [new_child]}

      expected_ops = [
        {:key_add, "a", new_child},
        {:key_reorder, ["a"]}
      ]

      expected_diff = {:update, [], %{type: :keyed_children, ops: expected_ops}}
      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end

    test "keyed: removes a child" do
      old_child = %{type: :li, key: "a", content: "item A"}
      old_tree = %{type: :ul, children: [old_child]}
      new_tree = %{type: :ul, children: []}

      expected_ops = [
        {:key_remove, "a"},
        {:key_reorder, []}
      ]

      expected_diff = {:update, [], %{type: :keyed_children, ops: expected_ops}}
      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end

    test "keyed: updates a child's content" do
      old_child_content = %{type: :li, key: "a", content: "old A"}
      new_child_content = %{type: :li, key: "a", content: "new A"}
      old_tree = %{type: :ul, children: [old_child_content]}
      new_tree = %{type: :ul, children: [new_child_content]}
      child_specific_diff = {:replace, new_child_content}

      expected_ops = [
        {:key_update, "a", child_specific_diff},
        {:key_reorder, ["a"]}
      ]

      expected_diff = {:update, [], %{type: :keyed_children, ops: expected_ops}}
      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end

    test "keyed: reorders children" do
      child_a = %{type: :li, key: "a", content: "A"}
      child_b = %{type: :li, key: "b", content: "B"}
      old_tree = %{type: :ul, children: [child_a, child_b]}
      new_tree = %{type: :ul, children: [child_b, child_a]}

      expected_ops = [
        {:key_reorder, ["b", "a"]}
      ]

      expected_diff = {:update, [], %{type: :keyed_children, ops: expected_ops}}
      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end

    test "keyed: complex scenario - add, remove, update, reorder" do
      c1_old = %{type: :item, key: "1", version: 1}
      c2 = %{type: :item, key: "2", version: 1}
      c3_old = %{type: :item, key: "3", version: 1}
      c4_old = %{type: :item, key: "4", version: 1}
      old_tree = %{type: :container, children: [c1_old, c2, c3_old, c4_old]}

      c3_new_content = %{type: :item, key: "3", version: 2}
      c5_new = %{type: :item, key: "5", version: 1}
      new_tree = %{type: :container, children: [c5_new, c3_new_content, c2]}

      diff_for_c3 = {:replace, c3_new_content}

      {:update, path, update_details} =
        TreeDiffer.diff_trees(old_tree, new_tree)

      assert path == []
      assert update_details.type == :keyed_children
      actual_ops = update_details.ops

      # Find ops by arity and type
      found_add_5 =
        Enum.find(actual_ops, fn
          {:key_add, "5", ^c5_new} -> true
          _ -> false
        end)

      assert found_add_5 == {:key_add, "5", c5_new}

      found_update_3 =
        Enum.find(actual_ops, fn
          {:key_update, "3", ^diff_for_c3} -> true
          _ -> false
        end)

      assert found_update_3 == {:key_update, "3", diff_for_c3}

      found_remove_1 =
        Enum.find(actual_ops, fn
          {:key_remove, "1"} -> true
          _ -> false
        end)

      assert found_remove_1 == {:key_remove, "1"}

      found_remove_4 =
        Enum.find(actual_ops, fn
          {:key_remove, "4"} -> true
          _ -> false
        end)

      assert found_remove_4 == {:key_remove, "4"}

      expected_reorder_op = {:key_reorder, ["5", "3", "2"]}
      assert Enum.member?(actual_ops, expected_reorder_op)
      assert length(actual_ops) == 5
    end

    test "keyed: no actual changes, only reorder op (idempotent reorder)" do
      child_a = %{type: :li, key: "a", content: "A"}
      child_b = %{type: :li, key: "b", content: "B"}
      old_tree = %{type: :ul, children: [child_a, child_b]}
      new_tree = %{type: :ul, children: [child_a, child_b]}
      assert TreeDiffer.diff_trees(old_tree, new_tree) == :no_change
    end

    test "keyed: fallback to non-keyed if new children are not consistently keyed" do
      old_child_keyed = %{type: :li, key: "a", content: "item A"}
      old_tree = %{type: :ul, children: [old_child_keyed]}
      new_child_not_keyed = %{type: :li, content: "item B"}
      new_tree = %{type: :ul, children: [new_child_not_keyed]}

      expected_diff =
        {:update, [],
         %{
           type: :indexed_children,
           diffs: [{0, {:replace, new_child_not_keyed}}]
         }}

      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end

    test "keyed: fallback to non-keyed if old children are not consistently keyed" do
      old_child_not_keyed = %{type: :li, content: "item A"}
      old_tree = %{type: :ul, children: [old_child_not_keyed]}
      new_child_keyed = %{type: :li, key: "b", content: "item B"}
      new_tree = %{type: :ul, children: [new_child_keyed]}

      expected_diff =
        {:update, [],
         %{type: :indexed_children, diffs: [{0, {:replace, new_child_keyed}}]}}

      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end

    test "keyed: empty old children, multiple new keyed children" do
      old_tree = %{type: :ul, children: []}
      child_a = %{type: :li, key: "a", content: "A"}
      child_b = %{type: :li, key: "b", content: "B"}
      new_tree = %{type: :ul, children: [child_a, child_b]}

      {:update, path, update_details} =
        TreeDiffer.diff_trees(old_tree, new_tree)

      assert path == []
      assert update_details.type == :keyed_children
      actual_ops = update_details.ops

      assert Enum.member?(actual_ops, {:key_add, "a", child_a})
      assert Enum.member?(actual_ops, {:key_add, "b", child_b})
      assert Enum.member?(actual_ops, {:key_reorder, ["a", "b"]})
      assert length(actual_ops) == 3
    end

    test "keyed: multiple old keyed children, empty new children" do
      child_a = %{type: :li, key: "a", content: "A"}
      child_b = %{type: :li, key: "b", content: "B"}
      old_tree = %{type: :ul, children: [child_a, child_b]}
      new_tree = %{type: :ul, children: []}

      {:update, path, update_details} =
        TreeDiffer.diff_trees(old_tree, new_tree)

      assert path == []
      assert update_details.type == :keyed_children
      actual_ops = update_details.ops
      assert Enum.member?(actual_ops, {:key_remove, "a"})
      assert Enum.member?(actual_ops, {:key_remove, "b"})
      assert Enum.member?(actual_ops, {:key_reorder, []})
      assert length(actual_ops) == 3
    end

    # Test for when only props of a keyed child change, not the type or structure
    test "keyed: updates only props of a child" do
      old_child = %{type: :item, key: "k1", id: 1, value: "old"}
      # Only value changed
      new_child = %{type: :item, key: "k1", id: 1, value: "new"}
      old_tree = %{type: :container, children: [old_child]}
      new_tree = %{type: :container, children: [new_child]}

      # Diffing old_child vs new_child with path [] should give an update for props.
      # This depends on how granular do_diff_trees is for non-children changes.
      # do_diff_trees emits {:replace, new_child} when the two are not `==`.
      # A granular diff would need it to compare props when the types match.
      expected_child_diff = {:replace, new_child}

      expected_ops = [
        {:key_update, "k1", expected_child_diff},
        {:key_reorder, ["k1"]}
      ]

      expected_diff = {:update, [], %{type: :keyed_children, ops: expected_ops}}
      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end

    # Test for mixed keyed and non-map children (should trigger non-keyed path)
    test "keyed: mixed keyed map and non-map child in new list triggers non-keyed diff" do
      old_child_keyed = %{type: :li, key: "a", content: "item A"}
      old_tree = %{type: :ul, children: [old_child_keyed]}

      new_child_keyed = %{type: :li, key: "b", content: "item B"}
      new_child_non_map = "text_item"
      new_tree = %{type: :ul, children: [new_child_keyed, new_child_non_map]}

      # Expected: Behaves like non-keyed diff because new_children is not consistently keyed.
      # Old: [A_keyed]
      # New: [B_keyed, "text_item"]
      # Zip: [{A_keyed, B_keyed}, {nil, "text_item"}]
      # Diff 0: A_keyed vs B_keyed -> replace B_keyed
      # Diff 1: nil vs "text_item" -> replace "text_item"
      expected_diff =
        {:update, [],
         %{
           type: :indexed_children,
           diffs: [
             {0, {:replace, new_child_keyed}},
             {1, {:replace, new_child_non_map}}
           ]
         }}

      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end

    test "keyed: mixed keyed map and map without key in new list triggers non-keyed diff" do
      old_child_keyed = %{type: :li, key: "a", content: "item A"}
      old_tree = %{type: :ul, children: [old_child_keyed]}

      new_child_keyed = %{type: :li, key: "b", content: "item B"}
      # Map, but no key
      new_child_no_key = %{type: :li, content: "item C"}
      new_tree = %{type: :ul, children: [new_child_keyed, new_child_no_key]}

      expected_diff =
        {:update, [],
         %{
           type: :indexed_children,
           diffs: [
             {0, {:replace, new_child_keyed}},
             {1, {:replace, new_child_no_key}}
           ]
         }}

      assert TreeDiffer.diff_trees(old_tree, new_tree) == expected_diff
    end
  end
end
