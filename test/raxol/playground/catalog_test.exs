defmodule Raxol.Playground.CatalogTest do
  use ExUnit.Case, async: true

  alias Raxol.Playground.Catalog

  describe "list_components/0" do
    test "returns all registered components" do
      components = Catalog.list_components()
      assert length(components) == 48
      assert Enum.all?(components, &is_map/1)
    end

    test "each component has required fields" do
      for comp <- Catalog.list_components() do
        assert is_binary(comp.name)
        assert is_atom(comp.module)

        assert comp.category in [
                 :input,
                 :display,
                 :feedback,
                 :navigation,
                 :overlay,
                 :layout,
                 :visualization,
                 :effects,
                 # Harness structure (shell, regions, indication, footer,
                 # composer, overlay) vs the chat-message widgets the body
                 # iterator routes into (message/reasoning/tool/diff/error/
                 # approval) -- split 2026-07-18.
                 :harness,
                 :harness_chat_widgets
               ]

        assert is_binary(comp.description)
        assert comp.complexity in [:basic, :intermediate, :advanced]
        assert is_list(comp.tags)
        assert is_binary(comp.code_snippet)
      end
    end

    test "each component module exists and implements init/1" do
      for comp <- Catalog.list_components() do
        assert Code.ensure_loaded?(comp.module),
               "#{inspect(comp.module)} not loaded for #{comp.name}"

        assert function_exported?(comp.module, :init, 1),
               "#{inspect(comp.module)} missing init/1"
      end
    end
  end

  describe "get_component/1" do
    test "returns component by name" do
      assert %{name: "Button"} = Catalog.get_component("Button")
      assert %{name: "Table"} = Catalog.get_component("Table")
    end

    test "returns nil for unknown name" do
      assert is_nil(Catalog.get_component("Nonexistent"))
    end
  end

  describe "list_categories/0" do
    test "returns unique categories" do
      categories = Catalog.list_categories()
      assert is_list(categories)
      assert length(categories) == length(Enum.uniq(categories))
      assert Enum.all?(categories, &is_atom/1)
    end
  end

  describe "filter/1" do
    test "filters by category" do
      input_components = Catalog.filter(category: :input)
      assert input_components != []
      assert Enum.all?(input_components, &(&1.category == :input))
    end

    test "filters by complexity" do
      basic = Catalog.filter(complexity: :basic)
      assert basic != []
      assert Enum.all?(basic, &(&1.complexity == :basic))
    end

    test "filters by search query" do
      results = Catalog.filter(search: "button")
      assert results != []
      assert Enum.any?(results, &(&1.name == "Button"))
    end

    test "search is case-insensitive" do
      assert Catalog.filter(search: "TABLE") == Catalog.filter(search: "table")
    end

    test "empty search returns all" do
      assert Catalog.filter(search: "") == Catalog.list_components()
    end

    test "no filters returns all" do
      assert Catalog.filter() == Catalog.list_components()
    end

    test "multiple filters combine" do
      results = Catalog.filter(category: :input, complexity: :basic)

      assert Enum.all?(
               results,
               &(&1.category == :input and &1.complexity == :basic)
             )
    end
  end
end
