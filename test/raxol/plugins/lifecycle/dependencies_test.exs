defmodule Raxol.Plugins.Lifecycle.DependenciesTest do
  use ExUnit.Case, async: true

  alias Raxol.Plugins.Lifecycle.Dependencies
  alias Raxol.Plugins.Plugin

  defp plugin(name, opts \\ []) do
    %Plugin{
      name: name,
      version: Keyword.get(opts, :version, "1.0.0"),
      dependencies: Keyword.get(opts, :dependencies, []),
      enabled: true
    }
  end

  defp manager_with(plugins) do
    {:ok, manager} = Raxol.Plugins.Manager.new()
    %{manager | plugins: Map.new(plugins, &{&1.name, &1})}
  end

  describe "resolve_plugin_order/1" do
    test "places a dependency before the plugin that declares it" do
      # registration order is deliberately wrong
      plugins = [
        plugin("dependent", dependencies: [{"base", ">= 1.0.0"}]),
        plugin("base")
      ]

      assert {:ok, order} = Dependencies.resolve_plugin_order(plugins)
      assert order == ["base", "dependent"]
    end

    test "orders a transitive chain" do
      plugins = [
        plugin("c", dependencies: [{"b", ">= 1.0.0"}]),
        plugin("a"),
        plugin("b", dependencies: [{"a", ">= 1.0.0"}])
      ]

      assert {:ok, ["a", "b", "c"]} = Dependencies.resolve_plugin_order(plugins)
    end

    test "keeps input order for independent plugins" do
      plugins = [plugin("x"), plugin("y"), plugin("z")]
      assert {:ok, ["x", "y", "z"]} = Dependencies.resolve_plugin_order(plugins)
    end

    test "ignores dependencies outside the batch" do
      # "already-loaded" is not being loaded now, so it constrains nothing
      plugins = [plugin("solo", dependencies: [{"already-loaded", ">= 1.0.0"}])]
      assert {:ok, ["solo"]} = Dependencies.resolve_plugin_order(plugins)
    end

    test "rejects a cycle instead of returning an arbitrary order" do
      plugins = [
        plugin("a", dependencies: [{"b", ">= 1.0.0"}]),
        plugin("b", dependencies: [{"a", ">= 1.0.0"}])
      ]

      assert {:error, :circular_dependency, cycle, []} =
               Dependencies.resolve_plugin_order(plugins)

      assert "a" in cycle
      assert "b" in cycle
    end

    test "accepts atom names" do
      plugins = [
        plugin(:dependent, dependencies: [{:base, ">= 1.0.0"}]),
        plugin(:base)
      ]

      assert {:ok, ["base", "dependent"]} =
               Dependencies.resolve_plugin_order(plugins)
    end
  end

  describe "check_for_circular_dependency/2" do
    test "rejects a plugin that depends on itself" do
      p = plugin("loop", dependencies: [{"loop", ">= 1.0.0"}])

      assert {:error, {:circular_dependency, cycle}} =
               Dependencies.check_for_circular_dependency(p, manager_with([]))

      assert "loop" in cycle
    end

    test "rejects an indirect cycle a -> b -> a" do
      # the regression: only self-reference used to be caught
      b = plugin("b", dependencies: [{"a", ">= 1.0.0"}])
      a = plugin("a", dependencies: [{"b", ">= 1.0.0"}])

      assert {:error, {:circular_dependency, cycle}} =
               Dependencies.check_for_circular_dependency(a, manager_with([b]))

      assert "a" in cycle
      assert "b" in cycle
    end

    test "rejects a longer indirect cycle a -> b -> c -> a" do
      b = plugin("b", dependencies: [{"c", ">= 1.0.0"}])
      c = plugin("c", dependencies: [{"a", ">= 1.0.0"}])
      a = plugin("a", dependencies: [{"b", ">= 1.0.0"}])

      assert {:error, {:circular_dependency, _cycle}} =
               Dependencies.check_for_circular_dependency(
                 a,
                 manager_with([b, c])
               )
    end

    test "accepts an acyclic graph" do
      base = plugin("base")
      mid = plugin("mid", dependencies: [{"base", ">= 1.0.0"}])
      top = plugin("top", dependencies: [{"mid", ">= 1.0.0"}])

      assert :ok =
               Dependencies.check_for_circular_dependency(
                 top,
                 manager_with([base, mid])
               )
    end

    test "accepts a diamond, which is not a cycle" do
      base = plugin("base")
      left = plugin("left", dependencies: [{"base", ">= 1.0.0"}])
      right = plugin("right", dependencies: [{"base", ">= 1.0.0"}])

      top =
        plugin("top",
          dependencies: [{"left", ">= 1.0.0"}, {"right", ">= 1.0.0"}]
        )

      assert :ok =
               Dependencies.check_for_circular_dependency(
                 top,
                 manager_with([base, left, right])
               )
    end
  end

  describe "check_dependencies/2" do
    test "reports a dependency that is not loaded" do
      p = plugin("needy", dependencies: [{"absent", ">= 1.0.0"}])

      assert {:error, :missing_dependencies, missing, ["needy"]} =
               Dependencies.check_dependencies(p, manager_with([]))

      assert missing == [{"absent", ">= 1.0.0"}]
    end

    test "accepts a satisfied version requirement" do
      base = plugin("base", version: "2.3.0")
      p = plugin("needy", dependencies: [{"base", "~> 2.0"}])

      assert :ok = Dependencies.check_dependencies(p, manager_with([base]))
    end

    test "rejects an unsatisfied version requirement" do
      # the regression: the version half of the tuple used to be discarded
      base = plugin("base", version: "1.0.0")
      p = plugin("needy", dependencies: [{"base", ">= 2.0.0"}])

      assert {:error, :version_mismatch, mismatches, ["needy"]} =
               Dependencies.check_dependencies(p, manager_with([base]))

      assert mismatches == [{"base", ">= 2.0.0", "1.0.0"}]
    end

    test "rejects a version outside a tilde requirement" do
      base = plugin("base", version: "3.0.0")
      p = plugin("needy", dependencies: [{"base", "~> 2.0"}])

      assert {:error, :version_mismatch, _, _} =
               Dependencies.check_dependencies(p, manager_with([base]))
    end

    test "accepts a bare name with no requirement" do
      base = plugin("base", version: "1.0.0")
      p = plugin("needy", dependencies: ["base"])

      assert :ok = Dependencies.check_dependencies(p, manager_with([base]))
    end

    test "accepts a plugin with no dependencies" do
      assert :ok =
               Dependencies.check_dependencies(plugin("solo"), manager_with([]))
    end

    test "fails closed when the loaded version cannot be parsed" do
      base = plugin("base", version: "not-a-version")
      p = plugin("needy", dependencies: [{"base", ">= 1.0.0"}])

      assert {:error, :version_mismatch, _, _} =
               Dependencies.check_dependencies(p, manager_with([base]))
    end
  end

  describe "validate_plugin_dependencies/2" do
    test "checks the cycle before the dependency set" do
      p = plugin("loop", dependencies: [{"loop", ">= 1.0.0"}])

      assert {:error, {:circular_dependency, _}} =
               Dependencies.validate_plugin_dependencies(p, manager_with([]))
    end

    test "passes a well-formed plugin" do
      base = plugin("base", version: "1.2.0")
      p = plugin("needy", dependencies: [{"base", "~> 1.0"}])

      assert :ok =
               Dependencies.validate_plugin_dependencies(
                 p,
                 manager_with([base])
               )
    end
  end
end
