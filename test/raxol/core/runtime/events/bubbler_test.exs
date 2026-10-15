defmodule Raxol.Core.Runtime.Events.BubblerTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Events.Bubbler

  # --- Test Helpers ---

  defp key_event(key, opts \\ []) do
    %Event{
      type: :key,
      data: %{key: key, modifiers: Keyword.get(opts, :modifiers, [])}
    }
  end

  defp click_event do
    %Event{type: :click, data: %{}}
  end

  # --- find_ancestor_path tests ---

  describe "find_ancestor_path/2" do
    test "finds element at root" do
      tree = %{type: :box, id: :root, children: []}
      path = Bubbler.find_ancestor_path(tree, :root)
      assert [%{id: :root}] = path
    end

    test "finds nested element and returns bottom-up path" do
      tree = %{
        type: :column,
        id: :root,
        children: [
          %{type: :row, id: :row1, children: [
            %{type: :button, id: :btn1},
            %{type: :button, id: :btn2}
          ]}
        ]
      }

      path = Bubbler.find_ancestor_path(tree, :btn2)
      ids = Enum.map(path, & &1.id)
      assert ids == [:btn2, :row1, :root]
    end

    test "returns nil when element not found" do
      tree = %{type: :box, id: :root, children: []}
      assert Bubbler.find_ancestor_path(tree, :nonexistent) == nil
    end

    test "handles single child map (not list)" do
      tree = %{
        type: :box,
        id: :root,
        children: %{type: :text, id: :label}
      }

      path = Bubbler.find_ancestor_path(tree, :label)
      ids = Enum.map(path, & &1.id)
      assert ids == [:label, :root]
    end

    test "handles deeply nested elements" do
      tree = %{
        type: :column,
        id: :root,
        children: [
          %{type: :box, id: :level1, children: [
            %{type: :row, id: :level2, children: [
              %{type: :column, id: :level3, children: [
                %{type: :button, id: :deep_btn}
              ]}
            ]}
          ]}
        ]
      }

      path = Bubbler.find_ancestor_path(tree, :deep_btn)
      ids = Enum.map(path, & &1.id)
      assert ids == [:deep_btn, :level3, :level2, :level1, :root]
    end

    test "handles elements without id" do
      tree = %{
        type: :column,
        id: :root,
        children: [
          %{type: :box, children: [
            %{type: :button, id: :btn}
          ]}
        ]
      }

      path = Bubbler.find_ancestor_path(tree, :btn)
      assert length(path) == 3
      assert hd(path).id == :btn
    end

    test "handles leaf elements without children" do
      tree = %{
        type: :column,
        id: :root,
        children: [
          %{type: :text, id: :label, content: "hello"}
        ]
      }

      path = Bubbler.find_ancestor_path(tree, :label)
      ids = Enum.map(path, & &1.id)
      assert ids == [:label, :root]
    end
  end

  # --- Inline handler tests ---

  describe "bubble/4 with inline handlers" do
    test "on_click handler fires on click event" do
      tree = %{
        type: :column,
        id: :root,
        children: [
          %{type: :button, id: :btn, on_click: :increment}
        ]
      }

      result = Bubbler.bubble(click_event(), tree, :btn, %{})
      assert {:handled, {:message, :increment}} = result
    end

    test "on_click handler fires on enter key" do
      tree = %{
        type: :column,
        id: :root,
        children: [
          %{type: :button, id: :btn, on_click: :submit}
        ]
      }

      result = Bubbler.bubble(key_event(:enter), tree, :btn, %{})
      assert {:handled, {:message, :submit}} = result
    end

    test "on_click handler fires on space key" do
      tree = %{
        type: :column,
        id: :root,
        children: [
          %{type: :button, id: :btn, on_click: :submit}
        ]
      }

      result = Bubbler.bubble(key_event(:space), tree, :btn, %{})
      assert {:handled, {:message, :submit}} = result
    end

    test "on_click with tuple message" do
      tree = %{
        type: :column,
        id: :root,
        children: [
          %{type: :button, id: :btn, on_click: {:button_clicked, :btn}}
        ]
      }

      result = Bubbler.bubble(click_event(), tree, :btn, %{})
      assert {:handled, {:message, {:button_clicked, :btn}}} = result
    end

    test "on_click does not fire on unrelated key" do
      tree = %{
        type: :column,
        id: :root,
        children: [
          %{type: :button, id: :btn, on_click: :submit}
        ]
      }

      result = Bubbler.bubble(key_event(:down), tree, :btn, %{})
      assert result in [:passthrough, {:handled, :ok}]
    end
  end

  # --- Bubbling behavior tests ---

  describe "bubble/4 propagation" do
    test "returns passthrough when element not found" do
      tree = %{type: :box, id: :root, children: []}
      result = Bubbler.bubble(click_event(), tree, :nonexistent, %{})
      assert result == :passthrough
    end

    test "returns passthrough when view_tree has no matching handler" do
      tree = %{
        type: :column,
        id: :root,
        children: [
          %{type: :text, id: :label, content: "static"}
        ]
      }

      result = Bubbler.bubble(key_event(:a), tree, :label, %{})
      assert result == :passthrough
    end

    test "bubbles from child to parent on_click" do
      tree = %{
        type: :box,
        id: :parent,
        on_click: :parent_clicked,
        children: [
          %{type: :text, id: :child, content: "hello"}
        ]
      }

      result = Bubbler.bubble(click_event(), tree, :child, %{})
      assert {:handled, {:message, :parent_clicked}} = result
    end

    test "child handler takes priority over parent" do
      tree = %{
        type: :box,
        id: :parent,
        on_click: :parent_clicked,
        children: [
          %{type: :button, id: :child, on_click: :child_clicked}
        ]
      }

      result = Bubbler.bubble(click_event(), tree, :child, %{})
      assert {:handled, {:message, :child_clicked}} = result
    end

    test "skips elements without handlers and continues bubbling" do
      tree = %{
        type: :column,
        id: :root,
        on_click: :root_clicked,
        children: [
          %{type: :row, id: :middle, children: [
            %{type: :text, id: :leaf, content: "text"}
          ]}
        ]
      }

      result = Bubbler.bubble(click_event(), tree, :leaf, %{})
      assert {:handled, {:message, :root_clicked}} = result
    end
  end

  # --- Capture phase tests ---

  describe "dispatch/4 capture phase" do
    test "on_capture atom handler intercepts before target" do
      tree = %{
        type: :column,
        id: :root,
        on_capture: :captured_at_root,
        children: [
          %{type: :button, id: :btn, on_click: :should_not_reach}
        ]
      }

      result = Bubbler.dispatch(click_event(), tree, :btn, %{})
      assert {:handled, {:message, :captured_at_root}} = result
    end

    test "on_capture function handler can halt" do
      tree = %{
        type: :column,
        id: :root,
        on_capture: fn _event -> :halt end,
        children: [
          %{type: :button, id: :btn, on_click: :should_not_reach}
        ]
      }

      result = Bubbler.dispatch(click_event(), tree, :btn, %{})
      assert {:handled, :ok} = result
    end

    test "on_capture function handler can halt with message" do
      tree = %{
        type: :column,
        id: :root,
        on_capture: fn _event -> {:halt, :intercepted} end,
        children: [
          %{type: :button, id: :btn, on_click: :should_not_reach}
        ]
      }

      result = Bubbler.dispatch(click_event(), tree, :btn, %{})
      assert {:handled, {:message, :intercepted}} = result
    end

    test "on_capture function handler can passthrough" do
      tree = %{
        type: :column,
        id: :root,
        on_capture: fn _event -> :passthrough end,
        children: [
          %{type: :button, id: :btn, on_click: :reached_target}
        ]
      }

      result = Bubbler.dispatch(click_event(), tree, :btn, %{})
      assert {:handled, {:message, :reached_target}} = result
    end

    test "capture handler receives the event" do
      test_pid = self()

      tree = %{
        type: :column,
        id: :root,
        on_capture: fn event ->
          send(test_pid, {:captured_event, event.type})
          :passthrough
        end,
        children: [
          %{type: :button, id: :btn, on_click: :click_handled}
        ]
      }

      Bubbler.dispatch(click_event(), tree, :btn, %{})
      assert_received {:captured_event, :click}
    end

    test "capture runs on ancestors only, not on target" do
      tree = %{
        type: :button,
        id: :btn,
        on_capture: :should_not_fire_on_self,
        on_click: :target_click
      }

      result = Bubbler.dispatch(click_event(), tree, :btn, %{})
      # on_capture should not fire on target itself, only ancestors
      assert {:handled, {:message, :target_click}} = result
    end

    test "capture walks top-down through ancestors" do
      test_pid = self()

      tree = %{
        type: :column,
        id: :root,
        on_capture: fn _event ->
          send(test_pid, {:capture, :root})
          :passthrough
        end,
        children: [
          %{
            type: :row,
            id: :middle,
            on_capture: fn _event ->
              send(test_pid, {:capture, :middle})
              :passthrough
            end,
            children: [
              %{type: :button, id: :btn, on_click: :click}
            ]
          }
        ]
      }

      Bubbler.dispatch(click_event(), tree, :btn, %{})
      assert_received {:capture, :root}
      assert_received {:capture, :middle}
    end

    test "middle ancestor capture stops propagation" do
      tree = %{
        type: :column,
        id: :root,
        on_click: :should_not_reach,
        children: [
          %{
            type: :row,
            id: :middle,
            on_capture: :captured_at_middle,
            children: [
              %{type: :button, id: :btn, on_click: :should_not_reach}
            ]
          }
        ]
      }

      result = Bubbler.dispatch(click_event(), tree, :btn, %{})
      assert {:handled, {:message, :captured_at_middle}} = result
    end

    test "no capture handlers falls through to bubble" do
      tree = %{
        type: :column,
        id: :root,
        on_click: :root_bubble,
        children: [
          %{type: :text, id: :child, content: "text"}
        ]
      }

      result = Bubbler.dispatch(click_event(), tree, :child, %{})
      assert {:handled, {:message, :root_bubble}} = result
    end

    test "dispatch returns passthrough when nothing handles" do
      tree = %{
        type: :column,
        id: :root,
        children: [
          %{type: :text, id: :child, content: "text"}
        ]
      }

      result = Bubbler.dispatch(key_event(:a), tree, :child, %{})
      assert result == :passthrough
    end

    test "dispatch returns passthrough when element not found" do
      tree = %{type: :box, id: :root, children: []}
      result = Bubbler.dispatch(click_event(), tree, :nonexistent, %{})
      assert result == :passthrough
    end

    test "capture handler exception is caught gracefully" do
      tree = %{
        type: :column,
        id: :root,
        on_capture: fn _event -> raise "boom" end,
        children: [
          %{type: :button, id: :btn, on_click: :fallback}
        ]
      }

      result = Bubbler.dispatch(click_event(), tree, :btn, %{})
      # Exception in capture should passthrough, bubble handles it
      assert {:handled, {:message, :fallback}} = result
    end
  end

  # --- Edge cases ---

  describe "edge cases" do
    test "handles nil on_click gracefully" do
      tree = %{
        type: :column,
        id: :root,
        children: [
          %{type: :button, id: :btn, on_click: nil}
        ]
      }

      result = Bubbler.bubble(click_event(), tree, :btn, %{})
      assert result in [:passthrough, {:handled, :ok}]
    end

    test "handles empty children list" do
      tree = %{type: :box, id: :root, children: []}
      result = Bubbler.bubble(click_event(), tree, :root, %{})
      assert result == :passthrough
    end

    test "handles tree with no children key" do
      tree = %{type: :text, id: :root, content: "hello"}
      path = Bubbler.find_ancestor_path(tree, :root)
      assert [%{id: :root}] = path
    end

    test "nil on_capture is ignored" do
      tree = %{
        type: :column,
        id: :root,
        on_capture: nil,
        children: [
          %{type: :button, id: :btn, on_click: :reached}
        ]
      }

      result = Bubbler.dispatch(click_event(), tree, :btn, %{})
      assert {:handled, {:message, :reached}} = result
    end
  end
end
