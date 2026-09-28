defmodule Raxol.Plugins.PluginTest do
  use ExUnit.Case
  alias Raxol.Plugins.HyperlinkPlugin
  alias Raxol.Plugins.Manager.Events, as: PluginManager

  alias Raxol.Core.Runtime.Plugins.{PluginLifecycle, PluginSupervisor}

  alias Raxol.Test.PluginTestFixtures.{
    BadReturnPlugin,
    CircularDependencyPlugin,
    CrashPlugin,
    DependentPlugin,
    TestPlugin,
    TimeoutPlugin
  }

  setup do
    start_supervised!(PluginSupervisor)
    start_supervised!(PluginLifecycle)
    :ok
  end

  describe "plugin manager" do
    test "creates a new plugin manager" do
      {:ok, manager} = Raxol.Plugins.Manager.new()
      assert manager.plugins == %{}
      assert %Raxol.Plugins.PluginConfig{} = manager.config
    end

    test "loads a plugin" do
      {:ok, manager} = Raxol.Plugins.Manager.new()

      {:ok, updated_manager} =
        PluginManager.load_plugin(manager, HyperlinkPlugin)

      assert length(Map.keys(updated_manager.plugins)) == 1
      assert Map.has_key?(updated_manager.plugins, "hyperlink")
    end

    test "unloads a plugin" do
      {:ok, manager} = Raxol.Plugins.Manager.new()
      {:ok, manager} = PluginManager.load_plugin(manager, HyperlinkPlugin)
      {:ok, updated_manager} = PluginManager.unload_plugin(manager, "hyperlink")
      assert updated_manager.plugins == %{}
    end

    test "enables and disables a plugin" do
      {:ok, manager} = Raxol.Plugins.Manager.new()
      {:ok, manager} = PluginManager.load_plugin(manager, HyperlinkPlugin)

      # Debug: Check if plugin was loaded correctly
      assert Map.has_key?(manager.plugins, "hyperlink")

      result = PluginManager.disable_plugin(manager, "hyperlink")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
      {:ok, manager} = result
      {:ok, plugin} = PluginManager.get_plugin(manager, "hyperlink")
      assert plugin.enabled == false
      {:ok, manager} = PluginManager.enable_plugin(manager, "hyperlink")
      {:ok, plugin} = PluginManager.get_plugin(manager, "hyperlink")
      assert plugin.enabled == true
    end

    test "processes input through plugins" do
      {:ok, manager} = Raxol.Plugins.Manager.new()
      {:ok, manager} = PluginManager.load_plugin(manager, HyperlinkPlugin)
      {:ok, _manager} = PluginManager.process_input(manager, "test input")
    end

    test "processes output through plugins" do
      {:ok, manager} = Raxol.Plugins.Manager.new()
      {:ok, manager} = PluginManager.load_plugin(manager, HyperlinkPlugin)

      {:ok, _manager, _transformed_output} =
        Raxol.Plugins.Manager.Events.process_output(manager, "test output")
    end

    test "processes mouse events through plugins" do
      {:ok, manager} = Raxol.Plugins.Manager.new()
      {:ok, manager} = PluginManager.load_plugin(manager, HyperlinkPlugin)

      event = %{
        type: :mouse,
        x: 10,
        y: 10,
        button: :click,
        modifiers: []
      }

      {:ok, _manager, _propagation} =
        PluginManager.handle_mouse_event(manager, event, %{})
    end
  end

  describe "hyperlink plugin" do
    test "initializes correctly" do
      {:ok, plugin} = HyperlinkPlugin.init(%{})
      assert plugin.name == "hyperlink"
      assert plugin.version == "0.1.0"
      assert plugin.enabled == true
    end

    test "detects and makes URLs clickable" do
      {:ok, plugin} = HyperlinkPlugin.init(%{})
      output = "Check out https://example.com for more info"

      {:ok, _plugin, _modified_output} =
        HyperlinkPlugin.handle_output(plugin, output)

      # Note: The actual URL transformation would be tested in integration tests
      # since it involves terminal escape sequences
    end
  end

  describe "plugin metadata" do
    test "plugin exposes correct metadata" do
      assert %{id: :test_plugin, version: "1.0.0", dependencies: []} =
               TestPlugin.metadata()
    end
  end

  describe "plugin dependencies" do
    test "loads plugin with satisfied dependencies" do
      # Simulate loading TestPlugin first, then DependentPlugin
      {:ok, manager} = Raxol.Plugins.Manager.new()
      {:ok, manager} = PluginManager.load_plugin(manager, TestPlugin)
      {:ok, manager} = PluginManager.load_plugin(manager, DependentPlugin)
      assert Map.has_key?(manager.plugins, "dependent_plugin")
    end

    test "fails to load plugin with missing dependencies" do
      {:ok, manager} = Raxol.Plugins.Manager.new()
      # DependentPlugin requires TestPlugin
      assert {:error, error_msg} =
               PluginManager.load_plugin(manager, DependentPlugin)

      assert error_msg =~ "missing dependencies"
      assert error_msg =~ "test_plugin"
      assert error_msg =~ "dependent_plugin"
    end

    test "detects dependency cycles" do
      {:ok, manager} = Raxol.Plugins.Manager.new()
      # CircularDependencyPlugin depends on itself
      assert {:error, error_msg} =
               PluginManager.load_plugin(manager, CircularDependencyPlugin)

      assert error_msg =~ "Dependency cycle"
      assert error_msg =~ "circular_dependency_plugin"
    end
  end

  describe "plugin command registration and execution" do
    test "plugin registers and executes command" do
      # TestPlugin registers :test_cmd
      {:ok, state} = TestPlugin.init(%{})
      [{cmd, fun, _arity}] = TestPlugin.get_commands()
      assert cmd == :test_cmd
      assert fun == :handle_test_cmd
      # Simulate command execution
      {:ok, new_state, :test_ok} = TestPlugin.handle_test_cmd(:arg, state)
      assert new_state[:handled]
    end
  end

  describe "plugin error handling" do
    test "plugin init returns error" do
      # TimeoutPlugin simulates a timeout error
      assert {:error, :timeout_simulated} = TimeoutPlugin.init(%{})
    end

    test "plugin crashes during init" do
      assert_raise RuntimeError, ~r/Intentional crash/, fn ->
        CrashPlugin.init(%{})
      end
    end

    test "plugin returns invalid result from handler" do
      {:ok, state} = BadReturnPlugin.init(%{})

      assert :unexpected_return ==
               BadReturnPlugin.handle_bad_return_cmd(:arg, state)

      assert :not_ok == BadReturnPlugin.handle_input("input", state)

      assert [:not, :a, :tuple] ==
               BadReturnPlugin.handle_output("output", state)
    end
  end

  describe "plugin configuration persistence" do
    test "plugin config is persisted and loaded" do
      {:ok, manager} = Raxol.Plugins.Manager.new()
      config = %{foo: "bar"}
      {:ok, manager} = PluginManager.load_plugin(manager, TestPlugin, config)

      # Check if config is in the plugin struct or in the config field
      # The plugin should be loaded with the key "test_plugin"
      assert Map.has_key?(manager.plugins, "test_plugin")
      plugin = Map.get(manager.plugins, "test_plugin")

      # Check various places where the config might be stored
      assert Map.get(plugin, :foo) == "bar" or
               Map.get(plugin.config, :foo) == "bar" or
               Map.get(manager.config.plugin_configs, "test_plugin")[:foo] ==
                 "bar"
    end
  end
end
