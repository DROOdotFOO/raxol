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

  import ExUnit.CaptureLog

  alias Raxol.Core.Accessibility.{Projection, Provider}
  alias Raxol.MCP.{ToolProvider, TreeWalker}
  alias Raxol.Playground.Catalog
  alias Raxol.UI.Layout.Engine
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

    # The reverse direction, and the one that catches a silent LOSS of reach.
    # `TreeWalker`'s map used to carry `approval_prompt`, which derived nothing
    # (`Harness.ApprovalPrompt` exports no `mcp_tools/1`), and it was dropped so
    # the map would agree with this registry. Harmless exactly because the entry
    # was inert -- but nothing was watching the condition that made it inert.
    # Give that Component `mcp_tools/1` tomorrow and it becomes tool-providing
    # everywhere except in the map that decides, with every assertion above
    # still green.
    #
    # So: a Component that CAN provide tools must be registered, or named here
    # as a deliberate exclusion.
    @unregistered_tool_providers []

    test "every Component implementing ToolProvider is registered" do
      registered = MapSet.new(Registry.list(), & &1.module)
      excluded = MapSet.new(@unregistered_tool_providers)

      {:ok, modules} = :application.get_key(:raxol, :modules)

      missing =
        modules
        |> Enum.filter(&ui_component?/1)
        |> Enum.filter(&ToolProvider.tool_provider?/1)
        |> MapSet.new()
        |> MapSet.difference(registered)
        |> MapSet.difference(excluded)

      assert MapSet.size(missing) == 0,
             "these Components derive MCP tools but no declaration type maps " <>
               "to them, so an agent can never reach them: " <>
               inspect(MapSet.to_list(missing)) <>
               ". Register them, or list them in " <>
               "@unregistered_tool_providers with a reason."
    end

    defp ui_component?(module) do
      String.starts_with?(Atom.to_string(module), "Elixir.Raxol.UI.") and
        Code.ensure_loaded?(module)
    end
  end

  # The third drift axis, and the one whose failure mode is invisible.
  #
  # `Engine.process_element/3` and `measure_element/2` dispatch on `:type`
  # too, and their catch-all logs a warning and returns the accumulator
  # unchanged -- so a widget whose type reaches the engine with no layout
  # clause renders NOTHING. Not a crash, not a stack trace: a blank region.
  # The scrubber needed both clauses hand-added, and the two map assertions
  # above would have passed without either.
  #
  # Most registered types never reach the engine: their `render/2` returns a
  # DIFFERENT node type, so the registry entry is only a discovery key for MCP
  # and a11y. `Raxol.UI.Components.Input.TextArea.render/2` delegates straight
  # to `MultiLineInput.render/2`, for instance, so no tree ever carries
  # `type: :text_area`. The scrubber is the exception: `Components.scrubber/1`
  # stamps its own type onto the node the engine has to lay out.
  #
  # Naming them here rather than skipping the axis: a new widget that stamps
  # its own type and forgets the engine has to add itself to this list on
  # purpose, and say why.
  @layout_alias_only [
    :text_area,
    :password_field,
    :select_list,
    :menu,
    :tree,
    :viewport,
    :bar_chart,
    :line_chart,
    :scatter_chart
  ]

  describe "Raxol.UI.Layout.Engine reach" do
    test "every type that reaches the engine has a layout clause" do
      space = %{x: 0, y: 0, width: 40, height: 10}

      for type <- Registry.types(), type not in @layout_alias_only do
        log =
          capture_log(fn ->
            Engine.process_element(probe_node(type), space, [])
            Engine.measure_element(probe_node(type), space)
          end)

        refute log =~ "Unknown or unhandled element type",
               "#{inspect(type)} is registered but the layout engine has no " <>
                 "clause for it, so it renders as a blank region with only a " <>
                 "log line to say so. Add the clause, or add the type to " <>
                 "@layout_alias_only with the node type it renders as."
      end
    end

    test "the alias-only list names no type the engine already handles" do
      # Stops the list becoming a dumping ground: an entry that IS handled is
      # a stale exclusion suppressing a live axis.
      space = %{x: 0, y: 0, width: 40, height: 10}

      for type <- @layout_alias_only, type in Registry.types() do
        log =
          capture_log(fn ->
            Engine.process_element(probe_node(type), space, [])
          end)

        assert log =~ "Unknown or unhandled element type",
               "#{inspect(type)} is excluded from the layout axis but the " <>
                 "engine handles it -- drop it from @layout_alias_only"
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

        under_registry =
          Projection.descriptor(probe, type_map: Registry.type_map())

        under_fallback = Projection.descriptor(probe, type_map: %{})

        assert under_default == under_registry,
               "Projection's default map does not resolve #{inspect(type)} to #{inspect(Registry.get(type).module)}"

        assert under_registry != under_fallback,
               "probe for #{inspect(type)} no longer distinguishes the Provider from default extraction, so the assertion above cannot fail"
      end
    end
  end

  describe "Raxol.Core.Renderer.View is the complete DSL" do
    # `view.ex:330` says "Delegate unique Components functions so View is the
    # single complete DSL", and `use Raxol.Core.Runtime.Application` imports
    # ONLY `Raxol.Core.Renderer.View`. So a helper added to
    # `Raxol.View.Components` and not delegated is invisible to every TEA app
    # and every `examples/*.exs` -- which is how `scrubber/1` shipped with a
    # demo that could not compile. Nothing compiles `examples/`, so this is
    # the guard.
    test "every Raxol.View.Components helper is reachable from View" do
      missing =
        exported_names(Raxol.View.Components)
        |> MapSet.difference(exported_names(Raxol.Core.Renderer.View))
        |> Enum.sort()

      assert missing == [],
             "not delegated from Raxol.Core.Renderer.View, so no TEA app or example can call them: #{inspect(missing)}"
    end
  end

  # Names, not name/arity: `defdelegate f(opts \\ [])` generates f/0 and f/1
  # while several View helpers are defined with a required argument, so the
  # arity sets legitimately differ. A helper missing at EVERY arity is the
  # defect worth failing on.
  defp exported_names(module) do
    module.__info__(:functions)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
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
