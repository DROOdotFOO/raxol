defmodule Raxol.UI.Accessibility.ComponentA11yTest do
  @moduledoc """
  Exercises the real Component `a11y_node/1` Providers through
  `Raxol.Core.Accessibility.Projection` (default 15-Component type_map). This
  runs in the main app where the Component modules are loaded, so it covers the
  provider-dispatch path the raxol_core suite cannot.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Accessibility.Projection

  test "Button -> :button with label, disabled state, and visual variant" do
    node = %{
      type: :button,
      id: "save",
      attrs: %{label: "Save", disabled: true, focused: false, role: :primary}
    }

    assert %{role: :button, label: "Save", id: "save", state: state} =
             Projection.project(node)

    assert state[:disabled?] == true
    assert state[:variant] == :primary
    refute Map.has_key?(state, :focused?)
  end

  test "Checkbox reads top-level checked (View.Components shape)" do
    node = %{type: :checkbox, id: "agree", label: "Agree", checked: true}

    assert %{role: :checkbox, label: "Agree", state: %{checked?: true}} =
             Projection.project(node)
  end

  test "Checkbox reads attrs.checked (MCP fixture shape), keeps checked? false" do
    node = %{
      type: :checkbox,
      id: "agree",
      attrs: %{checked: false, label: "Agree"}
    }

    assert %{role: :checkbox, label: "Agree", state: %{checked?: false}} =
             Projection.project(node)
  end

  test "TextInput -> :textbox with value and placeholder-derived label" do
    node = %{
      type: :text_input,
      id: "name",
      attrs: %{value: "Alice"},
      placeholder: "Name"
    }

    assert %{role: :textbox, value: "Alice", label: "Name"} =
             Projection.project(node)
  end

  test "TextInput reflects focused?" do
    node = %{type: :text_input, id: "n", focused: true}

    assert %{role: :textbox, state: %{focused?: true}} =
             Projection.project(node)
  end

  test "PasswordField -> :textbox but never exposes value" do
    node = %{
      type: :password_field,
      id: "pw",
      value: "hunter2",
      placeholder: "Password"
    }

    assert %{role: :textbox, value: nil, label: "Password"} =
             Projection.project(node)
  end

  test "SelectList synthesizes :option children with aria-selected on all" do
    node = %{
      type: :select_list,
      id: "s",
      options: ["x", "y"],
      selected_index: 1
    }

    assert %{
             role: :listbox,
             children: [
               %{role: :option, label: "x", state: %{selected?: false}},
               %{role: :option, label: "y", state: %{selected?: true}}
             ]
           } = Projection.project(node)
  end

  test "Tabs synthesizes :tab children with the active tab selected" do
    node = %{
      type: :tabs,
      id: "t",
      tabs: [%{id: :a, label: "A"}, %{id: :b, label: "B"}],
      active_index: 0
    }

    assert %{
             role: :tablist,
             children: [
               %{role: :tab, label: "A", id: "a", state: %{selected?: true}},
               %{role: :tab, label: "B", id: "b", state: %{selected?: false}}
             ]
           } = Projection.project(node)
  end

  test "Modal -> :dialog with title label and recursed content children" do
    node = %{
      type: :modal,
      id: "m",
      title: "Confirm",
      children: [%{type: :button, id: "ok", attrs: %{label: "OK"}}]
    }

    assert %{role: :dialog, label: "Confirm", children: [child]} =
             Projection.project(node)

    assert %{role: :button, label: "OK", id: "ok"} = child
  end

  test "Table -> :grid with :row and :gridcell children" do
    node = %{
      type: :table,
      id: "tbl",
      columns: [%{id: :name, label: "Name"}, %{id: :age, label: "Age"}],
      data: [%{name: "Alice", age: 30}]
    }

    assert %{role: :grid, children: [row]} = Projection.project(node)

    assert %{
             role: :row,
             children: [
               %{role: :gridcell, label: "Alice"},
               %{role: :gridcell, label: "30"}
             ]
           } = row
  end

  test "Tree -> :tree/:treeitem with expanded? and nested items" do
    node = %{
      type: :tree,
      id: "tr",
      nodes: [
        %{
          id: :root,
          label: "Root",
          children: [%{id: :child, label: "Child", children: []}]
        }
      ],
      expanded: MapSet.new([:root])
    }

    assert %{role: :tree, children: [root]} = Projection.project(node)

    assert %{
             role: :treeitem,
             label: "Root",
             id: "root",
             state: %{expanded?: true},
             children: [%{role: :treeitem, label: "Child", id: "child"}]
           } = root
  end

  test "collapsed Tree node hides its children" do
    node = %{
      type: :tree,
      id: "tr",
      nodes: [
        %{
          id: :root,
          label: "Root",
          children: [%{id: :child, label: "Child", children: []}]
        }
      ],
      expanded: MapSet.new()
    }

    assert %{children: [%{state: %{expanded?: false}, children: []}]} =
             Projection.project(node)
  end

  test "Charts -> :img with id-derived or default label" do
    assert %{role: :img, label: "cpu"} =
             Projection.project(%{type: :bar_chart, id: "cpu"})

    assert %{role: :img, label: "line chart"} =
             Projection.project(%{type: :line_chart})

    assert %{role: :img, label: "scatter chart"} =
             Projection.project(%{type: :scatter_chart})
  end

  test "Viewport -> :region and recurses its content Elements" do
    node = %{
      type: :viewport,
      id: "vp",
      children: [%{type: :text, content: "row 1"}]
    }

    assert %{
             role: :region,
             id: "vp",
             children: [%{role: :text, label: "row 1"}]
           } =
             Projection.project(node)
  end

  test "Menu -> :menu with nested :menuitem children" do
    node = %{
      type: :menu,
      id: "menu",
      items: [
        %{
          id: :file,
          label: "File",
          children: [%{id: :open, label: "Open", children: []}]
        }
      ]
    }

    assert %{role: :menu, children: [file]} = Projection.project(node)

    assert %{
             role: :menuitem,
             label: "File",
             id: "file",
             children: [%{role: :menuitem, label: "Open", id: "open"}]
           } = file
  end
end
