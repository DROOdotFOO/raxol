defmodule Raxol.Core.Accessibility.ProjectionTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Accessibility.Projection

  # Stub Providers for the injected type_map. The real Components live in main
  # raxol and are not loaded in raxol_core's suite; their integration is covered
  # by Raxol.UI.Accessibility.ComponentA11yTest in the main app.
  defmodule StubButton do
    @behaviour Raxol.Core.Accessibility.Provider
    @impl true
    def a11y_node(node) do
      %{role: :button, label: node[:label], state: %{disabled?: node[:disabled] == true}}
    end
  end

  defmodule StubList do
    @behaviour Raxol.Core.Accessibility.Provider
    @impl true
    def a11y_node(node) do
      children = Enum.map(node[:options] || [], fn opt -> %{role: :option, label: opt} end)
      %{role: :listbox, label: node[:label], children: children}
    end
  end

  defmodule StubRaises do
    @behaviour Raxol.Core.Accessibility.Provider
    @impl true
    def a11y_node(_node), do: raise("boom")
  end

  @stub_map %{stub_button: StubButton, stub_list: StubList, stub_raises: StubRaises}

  defp project(node), do: Projection.project(node, type_map: @stub_map)

  describe "Provider dispatch" do
    test "calls a11y_node/1 for a mapped Provider and normalizes the node" do
      node = %{type: :stub_button, id: "b1", label: "Save", disabled: false}

      assert %{
               role: :button,
               label: "Save",
               id: "b1",
               children: [],
               value: nil,
               live?: false,
               state: state
             } = project(node)

      # disabled? false is dropped (its absence means false)
      refute Map.has_key?(state, :disabled?)
    end

    test "keeps disabled? when true" do
      node = %{type: :stub_button, id: "b1", label: "Save", disabled: true}
      assert %{state: %{disabled?: true}} = project(node)
    end

    test "uses Provider-supplied children, normalizing each terse child" do
      node = %{type: :stub_list, id: "l1", label: "Pick", options: ["a", "b"]}

      assert %{role: :listbox, label: "Pick", children: [c1, c2]} = project(node)

      assert %{
               role: :option,
               label: "a",
               children: [],
               state: %{},
               value: nil,
               live?: false,
               id: nil
             } =
               c1

      assert %{role: :option, label: "b"} = c2
    end
  end

  describe "totality" do
    test "a Provider that raises falls back to default extraction" do
      node = %{type: :stub_raises, id: "x", content: "hi"}
      assert %{role: :generic, label: "hi", id: "x"} = project(node)
    end

    @adversarial [
      nil,
      %{},
      %{type: :text},
      %{type: nil},
      %{type: "string-type"},
      %{type: :row, children: nil},
      %{type: :row, children: "not a list"},
      %{type: :row, children: [nil, "x", 42, %{type: :text, content: "ok"}]},
      %{type: :checkbox, checked: nil, attrs: nil},
      %{type: :button, attrs: %{label: 123}},
      %{type: :text, content: 42},
      %{type: :unknown_xyz, foo: :bar},
      [%{type: :button}, %{type: :text, content: "y"}],
      "just a string",
      42,
      :an_atom
    ]

    test "project/1 never raises for adversarial input" do
      for input <- @adversarial do
        result = Projection.project(input)
        assert is_nil(result) or is_map(result) or is_list(result)
      end
    end
  end

  describe "default extraction (no Provider loaded)" do
    # The default type_map names main-raxol Components not loaded here, so these
    # exercise the fallback path the projection uses for un-opted Elements.
    test "bare text -> :text with content as label" do
      assert %{role: :text, label: "hello", children: []} =
               Projection.project(%{type: :text, content: "hello"})
    end

    test "row -> :group and recurses Element children" do
      tree = %{
        type: :row,
        children: [%{type: :text, content: "a"}, %{type: :text, content: "b"}]
      }

      assert %{role: :group, children: [%{label: "a"}, %{label: "b"}]} = Projection.project(tree)
    end

    test "unknown type -> :generic" do
      assert %{role: :generic} = Projection.project(%{type: :frobnicate})
    end

    test "button-shaped Element falls back to :button + attrs label when unloaded" do
      node = %{type: :button, id: "b", attrs: %{label: "Go", disabled: true}}

      assert %{role: :button, label: "Go", id: "b", state: %{disabled?: true}} =
               Projection.project(node)
    end

    test "non-string labels normalize to nil" do
      assert %{label: nil} = Projection.project(%{type: :text, content: 42})
    end
  end

  describe "by_id/2" do
    test "flattens nodes with binary ids into a map" do
      tree = %{
        type: :row,
        children: [
          %{type: :stub_button, id: "b1", label: "A"},
          %{type: :stub_button, id: "b2", label: "B"}
        ]
      }

      map = Projection.by_id(tree, type_map: @stub_map)

      assert %{"b1" => %{role: :button, label: "A"}, "b2" => %{label: "B"}} = map
      assert map_size(map) == 2
    end

    test "skips nodes without a binary id" do
      tree = %{type: :row, children: [%{type: :text, content: "x"}]}
      assert Projection.by_id(tree) == %{}
    end
  end
end
