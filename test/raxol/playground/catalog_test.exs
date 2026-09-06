defmodule Raxol.Playground.CatalogTest do
  use ExUnit.Case, async: true

  alias Raxol.Playground.Catalog

  describe "list_components/0" do
    test "returns all registered components" do
      components = Catalog.list_components()
      assert length(components) == 42
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
                 :effects
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

    # Every snippet is extracted from its demo's marked region at compile
    # time (a missing marker pair fails the build, so no test is needed for
    # that); what a test can still hold is that the extraction yields a
    # real excerpt and that the derived sub-line never merely repeats the
    # card's name.
    test "derived snippets are real excerpts, never empty" do
      for comp <- Catalog.list_components() do
        assert String.trim(comp.code_snippet) != "",
               "#{comp.name} derived an empty snippet"
      end
    end

    test "a shows sub-line adds a name, never repeats one" do
      for comp <- Catalog.list_components(), comp.shows != nil do
        refute Raxol.Playground.Snippet.redundant?(comp.name, comp.shows),
               "#{comp.name} shows #{comp.shows}, which only repeats the name"

        assert comp.code_snippet =~ comp.shows,
               "#{comp.name} shows #{comp.shows}, which its snippet never calls"
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
