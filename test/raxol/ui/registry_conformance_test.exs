defmodule Raxol.UI.RegistryConformanceTest do
  @moduledoc """
  Holds `Raxol.UI.Registry` and the two package-side `type -> module` maps to
  each other.

  `raxol_mcp` and `raxol_core` cannot depend on main raxol, so
  `Raxol.MCP.TreeWalker` and `Raxol.Core.Accessibility.Projection` each hand-copy
  the map that makes tool derivation and a11y projection fire, and name Component
  modules only behind `@compile {:no_warn_undefined, ...}`. Nothing in either
  package can notice a typo'd module, a missing entry, or an entry whose module
  does not implement the behaviour the map implies -- their own suites run
  without those modules loaded, so the guards (`ToolProvider.tool_provider?/1`,
  `Provider.provider?/1`) swallow the mistake and derive nothing.

  This test runs in the main app, where every Component module IS loaded, and is
  the only thing standing between that drift and a silent ship.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Accessibility.{Projection, Provider}
  alias Raxol.MCP.{ToolProvider, TreeWalker}
  alias Raxol.Playground.Catalog
  alias Raxol.UI.Registry

  describe "registry entries" do
    test "every type is registered exactly once" do
      dupes =
        Registry.types()
        |> Enum.frequencies()
        |> Enum.filter(fn {_type, count} -> count > 1 end)

      assert dupes == [],
             "duplicate registry types silently shadow in type_map/0: #{inspect(dupes)}"
    end

    test "every module is loadable" do
      for %{type: type, module: module} <- Registry.list() do
        assert Code.ensure_loaded?(module),
               "#{inspect(type)} names #{inspect(module)}, which does not load"
      end
    end

    test "every mcp? entry implements ToolProvider" do
      for %{type: type, module: module} <- Registry.list(), entry_mcp?(type) do
        # function_exported?/3 answers false for a merely-unloaded module, so
        # load first or this whole test degrades into a tautology.
        assert Code.ensure_loaded?(module), "#{inspect(module)} does not load"

        assert function_exported?(module, :mcp_tools, 1),
               "#{inspect(module)} claims mcp?: true but exports no mcp_tools/1"

        assert function_exported?(module, :handle_tool_call, 3),
               "#{inspect(module)} claims mcp?: true but exports no handle_tool_call/3"

        assert ToolProvider.tool_provider?(module),
               "#{inspect(module)} fails ToolProvider.tool_provider?/1, so TreeWalker derives no tools for it"
      end
    end

    test "every a11y? entry implements the Accessibility Provider" do
      for %{type: type, module: module} <- Registry.list(), entry_a11y?(type) do
        assert Code.ensure_loaded?(module), "#{inspect(module)} does not load"

        assert function_exported?(module, :a11y_node, 1),
               "#{inspect(module)} claims a11y?: true but exports no a11y_node/1"

        assert Provider.provider?(module),
               "#{inspect(module)} fails Provider.provider?/1, so Projection falls back to default extraction"
      end
    end

    test "every named demo resolves in the playground catalog" do
      for %{type: type, demo: demo} <- Registry.list(), is_binary(demo) do
        assert Catalog.get_component(demo),
               "#{inspect(type)} names demo #{inspect(demo)}, absent from Raxol.Playground.Catalog"
      end
    end
  end

  describe "Raxol.MCP.TreeWalker default type map" do
    test "agrees with the registry in both directions" do
      registry_map = Map.take(Registry.type_map(), Registry.mcp_types())
      walker_map = TreeWalker.default_type_map()

      missing = Map.keys(registry_map) -- Map.keys(walker_map)

      assert missing == [],
             "registry mcp? types absent from TreeWalker's map derive no tools: #{inspect(missing)}"

      extra = Map.keys(walker_map) -- Map.keys(registry_map)

      assert extra == [],
             "TreeWalker maps types the registry does not know: #{inspect(extra)}"

      assert walker_map == registry_map
    end
  end

  describe "Raxol.Core.Accessibility.Projection default type map" do
    # Projection keeps its map in a private attribute and exposes no accessor,
    # and it lives in raxol_core -- a file this test's owner may not edit. So the
    # map is observed through behaviour: for each registry type, projecting a
    # probe under the default map must equal projecting it under an explicit
    # registry map (proving the default dispatches to the same module), and both
    # must differ from projecting with an empty map (proving the Provider ran at
    # all, rather than both sides silently falling back).
    #
    # Residual gap: this covers registry -> Projection. The reverse direction (a
    # Projection entry for a type the registry does not list) is unobservable
    # without enumerating every atom; it needs a public accessor in raxol_core.
    test "dispatches every registry a11y? type to the registry's module" do
      for %{type: type} <- Registry.list(), entry_a11y?(type) do
        probe = probe_node(type)

        under_default = Projection.descriptor(probe)
        under_registry = Projection.descriptor(probe, type_map: Registry.type_map())
        under_fallback = Projection.descriptor(probe, type_map: %{})

        assert under_default == under_registry,
               "Projection's default map does not resolve #{inspect(type)} to #{inspect(Registry.get(type).module)}"

        assert under_registry != under_fallback,
               "probe for #{inspect(type)} no longer distinguishes the Provider from default extraction, so the assertion above cannot fail"
      end
    end
  end

  # Carries every prop the Providers key off (label, disabled, focused, and the
  # visual `role` variant Button folds into state) so that Provider output
  # diverges from `default_extract/2` for all 16 types.
  defp probe_node(type) do
    %{
      type: type,
      id: "probe",
      attrs: %{label: "Probe", disabled: true, focused: true, role: :primary}
    }
  end

  defp entry_mcp?(type), do: type in Registry.mcp_types()
  defp entry_a11y?(type), do: type in Registry.a11y_types()
end
