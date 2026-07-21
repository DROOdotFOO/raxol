defmodule Raxol.MCP.NodeChildrenTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.NodeChildren

  describe "child_nodes/1" do
    test "returns a list of :children verbatim" do
      a = %{type: :text, id: "a"}
      b = %{type: :text, id: "b"}
      assert NodeChildren.child_nodes(%{children: [a, b]}) == [a, b]
    end

    test "wraps a single element-map child into a one-item list" do
      kid = %{type: :column, id: "c"}
      assert NodeChildren.child_nodes(%{children: kid}) == [kid]
    end

    test "a leaf (no :children / :flow_child / :overlays) has no children" do
      assert NodeChildren.child_nodes(%{type: :text, id: "leaf"}) == []
    end

    test "an :absolute_layer contributes its flow child then each overlay's :element, in order" do
      flow = %{type: :column, id: "flow"}
      o1 = %{type: :box, id: "o1"}
      o2 = %{type: :box, id: "o2"}

      node = %{
        flow_child: flow,
        overlays: [%{element: o1}, %{element: o2}]
      }

      assert NodeChildren.child_nodes(node) == [flow, o1, o2]
    end

    test "direct children precede absolute-layer children" do
      direct = %{type: :text, id: "d"}
      flow = %{type: :column, id: "flow"}

      node = %{children: [direct], flow_child: flow, overlays: []}

      assert NodeChildren.child_nodes(node) == [direct, flow]
    end

    test "overlays without a map :element are skipped, never crash" do
      o1 = %{type: :box, id: "o1"}

      node = %{overlays: [%{element: o1}, %{element: nil}, %{}, :garbage]}

      assert NodeChildren.child_nodes(node) == [o1]
    end

    test "a non-map node has no children" do
      assert NodeChildren.child_nodes(nil) == []
      assert NodeChildren.child_nodes("text") == []
      assert NodeChildren.child_nodes([]) == []
    end
  end
end
