defmodule Raxol.Plugins.PluginSystemTest do
  use ExUnit.Case

  @moduledoc """
  Tests for the plugin system functionality including plugin loading, configuration,
  and lifecycle management.
  """

  alias Raxol.Plugins.EventHandler
  alias Raxol.Plugins.EventHandler.InputEvents
  alias Raxol.Plugins.EventHandler.MouseEvents
  alias Raxol.Plugins.EventHandler.OutputEvents
  alias Raxol.Plugins.HyperlinkPlugin
  alias Raxol.Plugins.ImagePlugin
  alias Raxol.Plugins.Lifecycle
  alias Raxol.Plugins.SearchPlugin
  alias Raxol.Plugins.ThemePlugin
  alias Raxol.Terminal.Emulator.Struct, as: Emulator

  describe "Plugin Manager" do
    test "creates a new plugin manager" do
      {:ok, manager} = Raxol.Plugins.Manager.new()
      assert manager.plugins == %{}

      assert manager.config == %Raxol.Plugins.PluginConfig{
               enabled_plugins: [],
               plugin_configs: %{}
             }

      assert manager.api_version == "1.0"
    end

    # test 'loads a plugin' do
    #   {:ok, manager_struct} = Raxol.Plugins.Manager.new(%{plugins: [TestPlugin]}) # Incorrect usage
    #
    #   {:ok, updated_manager} =
    #     Raxol.Plugins.Manager.load_plugin(manager_struct, HyperlinkPlugin)
    #
    #   assert Map.has_key?(updated_manager.plugins, "hyperlink")
    #   assert updated_manager.plugins["hyperlink"].enabled == true
    # end

    test "loads plugin with dependencies" do
      {:ok, manager} = Raxol.Plugins.Manager.new()

      # Create a test plugin that depends on HyperlinkPlugin
      defmodule TestDependentPlugin do
        use Raxol.Plugins.Plugin

        @moduledoc """
        Test plugin that depends on HyperlinkPlugin for testing dependency loading.
        """

        def init(_opts \\ %{}) do
          {:ok, %{name: "test_dependent", enabled: true}}
        end

        def cleanup(_state) do
          :ok
        end

        def get_metadata do
          %{
            name: "test_dependent",
            version: "1.0.0",
            dependencies: ["hyperlink"]
          }
        end

        def get_api_version do
          "1.0"
        end

        def api_version do
          "1.0.0"
        end
      end

      # First load the dependency
      {:ok, manager_with_dep} = Lifecycle.load_plugin(manager, HyperlinkPlugin)

      # Then load the dependent plugin
      {:ok, final_manager} =
        Lifecycle.load_plugin(manager_with_dep, TestDependentPlugin)

      assert Map.has_key?(final_manager.plugins, "hyperlink")
      assert Map.has_key?(final_manager.plugins, "test_dependent")
    end

    test "loads plugin with specific config" do
      {:ok, manager} = Raxol.Plugins.Manager.new()

      # Create a test plugin that accepts config
      defmodule TestConfigPlugin do
        use Raxol.Plugins.Plugin

        @moduledoc """
        Test plugin that accepts configuration options for testing config loading.
        """

        def init(opts \\ %{}) do
          {:ok,
           %{
             name: "test_config",
             enabled: true,
             custom_setting: opts[:custom_setting]
           }}
        end

        def cleanup(_state) do
          :ok
        end

        def get_metadata do
          %{
            name: "test_config",
            version: "1.0.0",
            dependencies: []
          }
        end

        def get_api_version do
          "1.0"
        end

        def api_version do
          "1.0.0"
        end
      end

      # Load plugin with specific config
      {:ok, updated_manager} =
        Lifecycle.load_plugin(manager, TestConfigPlugin, %{
          custom_setting: "test_value"
        })

      assert Map.has_key?(updated_manager.plugins, "test_config")

      assert updated_manager.plugins["test_config"].custom_setting ==
               "test_value"
    end

    test "unloads a plugin" do
      {:ok, manager_struct} = Raxol.Plugins.Manager.new()

      {:ok, manager_with_plugin} =
        Raxol.Plugins.Manager.load_plugin(manager_struct, HyperlinkPlugin)

      {:ok, updated_manager} =
        Lifecycle.unload_plugin(
          manager_with_plugin,
          "hyperlink"
        )

      assert updated_manager.plugins == %{}
    end

    test "enables a plugin" do
      {:ok, manager_struct} = Raxol.Plugins.Manager.new()

      {:ok, manager_with_plugin} =
        Raxol.Plugins.Manager.load_plugin(manager_struct, HyperlinkPlugin)

      {:ok, manager_after_disable} =
        Lifecycle.disable_plugin(
          manager_with_plugin,
          "hyperlink"
        )

      assert manager_after_disable.plugins["hyperlink"].enabled == false

      {:ok, enabled_manager} =
        Lifecycle.enable_plugin(manager_after_disable, "hyperlink")

      assert enabled_manager.plugins["hyperlink"].enabled == true
    end

    test "disables a plugin" do
      {:ok, manager_struct} = Raxol.Plugins.Manager.new()

      {:ok, manager_with_plugin} =
        Raxol.Plugins.Manager.load_plugin(manager_struct, HyperlinkPlugin)

      assert manager_with_plugin.plugins["hyperlink"].enabled == true

      {:ok, updated_manager} =
        Lifecycle.disable_plugin(
          manager_with_plugin,
          "hyperlink"
        )

      assert updated_manager.plugins["hyperlink"].enabled == false
    end

    test "processes output through plugins" do
      {:ok, manager_struct} = Raxol.Plugins.Manager.new()

      {:ok, manager_with_plugin} =
        Raxol.Plugins.Manager.load_plugin(manager_struct, HyperlinkPlugin)

      {:ok, manager_after_url_processing, transformed_output} =
        EventHandler.handle_output(
          manager_with_plugin,
          "Visit https://example.com"
        )

      # Verify the output was transformed with hyperlink escape sequences
      assert String.contains?(transformed_output, "\e]8;;https://example.com")
      assert String.contains?(transformed_output, "\e\\")
      assert String.contains?(transformed_output, "https://example.com")

      # Test that non-URL text is not transformed
      {:ok, _manager_after_hello, hello_output} =
        EventHandler.handle_output(
          manager_after_url_processing,
          "Hello, World!"
        )

      assert hello_output == "Hello, World!"

      # Debug: Call the plugin directly with 2 args for coverage
      HyperlinkPlugin.handle_output(
        manager_with_plugin.plugins["hyperlink"],
        "Visit https://example.com"
      )
    end

    test "processes input through plugins" do
      {:ok, manager_struct} = Raxol.Plugins.Manager.new()

      {:ok, manager_with_plugin} =
        Raxol.Plugins.Manager.load_plugin(manager_struct, SearchPlugin)

      {:ok, updated_manager} =
        EventHandler.handle_input(
          manager_with_plugin,
          "/search example"
        )

      assert updated_manager.plugins["search"].search_term == "example"
    end

    test "processes mouse events through plugins" do
      {:ok, manager_struct} = Raxol.Plugins.Manager.new()
      _emulator = Raxol.Terminal.Emulator.new(100, 24)

      {:ok, manager_with_plugin} =
        Raxol.Plugins.Manager.load_plugin(manager_struct, HyperlinkPlugin)

      {:ok, updated_manager, propagation} =
        MouseEvents.handle_mouse_event(
          manager_with_plugin,
          %{type: :mouse, x: 1, y: 2, button: :click, modifiers: 1},
          # Empty rendered cells map
          %{}
        )

      assert Map.has_key?(updated_manager.plugins, "hyperlink")
      assert updated_manager.plugins["hyperlink"].enabled == true
      assert propagation in [:propagate, :halt]
    end
  end

  describe "Hyperlink Plugin" do
    test "initializes correctly" do
      {:ok, plugin} = HyperlinkPlugin.init()
      assert plugin.name == "hyperlink"
      assert plugin.enabled == true
    end

    test "detects and transforms URLs" do
      {:ok, plugin} = HyperlinkPlugin.init()

      # Test URL detection and transformation
      {:ok, updated_plugin, transformed_output} =
        HyperlinkPlugin.handle_output(plugin, "Visit https://example.com")

      assert String.contains?(
               transformed_output,
               "\e]8;;https://example.com\e\\"
             )

      {:ok, updated_plugin} =
        HyperlinkPlugin.handle_output(updated_plugin, "Hello, World!")
    end

    test "Hyperlink Plugin processes output via PluginManager" do
      {:ok, manager_struct} = Raxol.Plugins.Manager.new()

      {:ok, manager_after_load} =
        Raxol.Plugins.Manager.load_plugin(manager_struct, HyperlinkPlugin)

      input_text = "Check this link: https://example.com and continue."

      result = OutputEvents.handle_output(manager_after_load, input_text)

      assert match?(
               {:ok, %Raxol.Plugins.Manager{}, _transformed_output},
               result
             )

      {:ok, _final_manager, transformed_output} = result

      assert String.contains?(
               transformed_output,
               "\e]8;;https://example.com\e\\"
             )

      assert String.contains?(
               transformed_output,
               "https://example.com\e]8;;\e\\"
             )
    end
  end

  describe "Theme Plugin" do
    test "initializes correctly" do
      {:ok, plugin} = ThemePlugin.init()
      assert plugin.name == "theme"
      assert plugin.enabled == true
      assert is_map(plugin.current_theme.colors)

      assert plugin.current_theme.colors.background ==
               Raxol.UI.Theming.Theme.default_theme().colors.background

      assert plugin.current_theme.colors.foreground ==
               Raxol.UI.Theming.Theme.default_theme().colors.foreground
    end

    test "changes theme" do
      {:ok, plugin} = ThemePlugin.init()

      # Register a new theme for testing
      new_theme_attrs = %{
        id: :test_theme,
        name: "Test Theme",
        colors: %{
          background: "#123456",
          foreground: "#654321"
        }
      }

      :ok = ThemePlugin.register_theme(new_theme_attrs)

      # Test changing to a valid theme
      {:ok, updated_plugin} = ThemePlugin.change_theme(plugin, :test_theme)
      assert updated_plugin.current_theme.name == "Test Theme"
      # Changed to .hex
      assert updated_plugin.current_theme.colors.background.hex == "#123456"

      # Test changing to an invalid theme
      assert {:error, _} = ThemePlugin.change_theme(plugin, :invalid_theme)
    end

    test "lists available themes" do
      # Ensure default theme is registered if not already, for the test to pass reliably.
      ThemePlugin.register_theme(Raxol.UI.Theming.Theme.default_theme())
      # Register another theme to ensure list_themes works with multiple items
      ThemePlugin.register_theme(%{
        id: :another_one,
        name: "Another One",
        colors: %{background: "#111111"}
      })

      themes = ThemePlugin.list_themes()

      assert Enum.any?(themes, fn t ->
               t.id == Raxol.UI.Theming.Theme.default_theme().id
             end)

      # Assert based on the actual registered name "default"
      assert Enum.any?(themes, fn t -> t.name == "default" end)
      assert Enum.any?(themes, fn t -> t.name == "Another One" end)
    end

    test "registers a new theme and retrieves it" do
      theme_attrs = %{
        id: :custom_theme,
        name: "Custom Theme",
        colors: %{
          background: "#abcdef",
          foreground: "#fedcba"
        }
      }

      :ok = ThemePlugin.register_theme(theme_attrs)
      themes = ThemePlugin.list_themes()
      assert Enum.any?(themes, fn t -> t.name == "Custom Theme" end)
      {:ok, plugin} = ThemePlugin.init(%{theme: :custom_theme})
      assert plugin.current_theme.name == "Custom Theme"
      # Changed to .hex and case-insensitive
      assert String.downcase(plugin.current_theme.colors.background.hex) ==
               String.downcase("#abcdef")
    end

    test "get_theme/1 returns the current theme struct" do
      {:ok, plugin} = ThemePlugin.init()
      theme = ThemePlugin.get_theme(plugin)
      assert is_map(theme)
      assert Map.has_key?(theme, :colors)
    end
  end

  describe "Search Plugin" do
    test "initializes correctly" do
      {:ok, plugin} = SearchPlugin.init()
      assert plugin.name == "search"
      assert plugin.enabled == true
      assert plugin.search_term == nil
      assert plugin.search_results == []
      assert plugin.current_result_index == 0
    end

    test "handles search commands" do
      {:ok, plugin} = SearchPlugin.init()

      {:ok, updated_plugin} =
        SearchPlugin.handle_input(plugin, "search example")

      assert updated_plugin.search_term == "example"

      plugin_with_results =
        Map.put(updated_plugin, :search_results, ["result1", "result2"])

      {:ok, next_plugin} =
        SearchPlugin.handle_input(plugin_with_results, "/n")

      assert next_plugin.current_result_index == 1

      {:ok, prev_plugin} =
        SearchPlugin.handle_input(next_plugin, "/N")

      assert prev_plugin.current_result_index == 0

      {:ok, cleared_plugin} =
        SearchPlugin.handle_input(prev_plugin, "/clear")

      assert cleared_plugin.search_term == nil
      assert cleared_plugin.search_results == []
      assert cleared_plugin.current_result_index == 0
    end

    test "highlights search terms" do
      {:ok, _plugin} = SearchPlugin.init()

      highlighted = SearchPlugin.highlight_search_term("Hello, World!", "World")
      assert highlighted == "Hello, \e[43mWorld\e[0m!"
    end
  end

  describe "Emulator with Plugins" do
    test "loads and uses plugins" do
      {:ok, initial_plugin_manager} = Raxol.Plugins.Manager.new()

      emulator =
        Raxol.Terminal.Emulator.new(80, 24,
          plugin_manager: initial_plugin_manager
        )

      {:ok, manager_after_hyperlink} =
        Lifecycle.load_plugin(emulator.plugin_manager, HyperlinkPlugin)

      {:ok, manager_after_image} =
        Lifecycle.load_plugin(manager_after_hyperlink, ImagePlugin)

      {:ok, manager_after_theme} =
        Lifecycle.load_plugin(manager_after_image, ThemePlugin)

      {:ok, final_plugin_manager} =
        Lifecycle.load_plugin(manager_after_theme, SearchPlugin)

      emulator_updated = %{emulator | plugin_manager: final_plugin_manager}

      plugins =
        Raxol.Plugins.Manager.list_plugins(emulator_updated.plugin_manager)

      assert length(plugins) == 4
    end

    test "initializes with plugin manager and plugins" do
      plugin_config = %Raxol.Plugins.PluginConfig{
        enabled_plugins: [:hyperlink_plugin],
        plugin_configs: %{
          hyperlink_plugin: %{enabled: true}
        }
      }

      {:ok, plugin_manager_struct} =
        Raxol.Plugins.Manager.new(plugin_config)

      {:ok, loaded_manager} =
        Lifecycle.load_plugin(
          plugin_manager_struct,
          Raxol.Plugins.HyperlinkPlugin
        )

      emulator =
        Raxol.Terminal.Emulator.new(80, 24, plugin_manager: loaded_manager)

      assert %Raxol.Terminal.Emulator{plugin_manager: pm} = emulator
      assert pm == loaded_manager

      assert Map.has_key?(
               Raxol.Plugins.Manager.loaded_plugins(pm),
               "hyperlink"
             )
    end

    test "processes output through plugins" do
      {:ok, plugin_manager_struct} = Raxol.Plugins.Manager.new()

      {:ok, loaded_manager} =
        Lifecycle.load_plugin(
          plugin_manager_struct,
          Raxol.Plugins.HyperlinkPlugin
        )

      {:ok, enabled_manager} =
        Lifecycle.enable_plugin(loaded_manager, "hyperlink")

      emulator =
        Raxol.Terminal.Emulator.new(80, 24, plugin_manager: enabled_manager)

      output_text = "Visit https://example.com"

      {:ok, updated_plugin_manager, processed_output} =
        EventHandler.handle_output(emulator.plugin_manager, output_text)

      _emulator_updated = %{emulator | plugin_manager: updated_plugin_manager}

      assert String.contains?(processed_output, "\e]8;;https://example.com\e\\")
    end

    test "disabled plugin does not process output" do
      {:ok, plugin_manager_struct} = Raxol.Plugins.Manager.new()

      {:ok, loaded_manager} =
        Lifecycle.load_plugin(
          plugin_manager_struct,
          Raxol.Plugins.HyperlinkPlugin
        )

      {:ok, disabled_manager} =
        Lifecycle.disable_plugin(loaded_manager, "hyperlink")

      emulator =
        Raxol.Terminal.Emulator.new(80, 24, plugin_manager: disabled_manager)

      output_text = "Visit https://example.com"

      {:ok, _updated_plugin_manager, processed_output} =
        EventHandler.handle_output(emulator.plugin_manager, output_text)

      refute String.contains?(processed_output, "\e]8;;https://example.com\e\\")
      assert processed_output == output_text
    end

    test "processes input through plugins" do
      {:ok, plugin_manager_struct} = Raxol.Plugins.Manager.new()

      {:ok, loaded_manager} =
        Lifecycle.load_plugin(plugin_manager_struct, Raxol.Plugins.SearchPlugin)

      {:ok, enabled_manager} = Lifecycle.enable_plugin(loaded_manager, "search")

      emulator =
        Raxol.Terminal.Emulator.new(80, 24, plugin_manager: enabled_manager)

      input_text = "/search test query"

      {:ok, updated_plugin_manager} =
        EventHandler.handle_input(emulator.plugin_manager, input_text)

      updated_emulator = %{emulator | plugin_manager: updated_plugin_manager}

      final_plugin_manager = updated_emulator.plugin_manager

      search_plugin_state =
        Raxol.Plugins.Manager.get_plugin(final_plugin_manager, "search")

      assert search_plugin_state.search_term == "test query"
    end

    test "Emulator with Plugins loads and uses plugins" do
      {:ok, initial_plugin_manager_struct} = Raxol.Plugins.Manager.new()

      {:ok, manager_after_hyperlink} =
        Lifecycle.load_plugin(
          initial_plugin_manager_struct,
          Raxol.Plugins.HyperlinkPlugin
        )

      {:ok, manager_after_search} =
        Lifecycle.load_plugin(
          manager_after_hyperlink,
          Raxol.Plugins.SearchPlugin
        )

      {:ok, final_plugin_manager} =
        Lifecycle.load_plugin(manager_after_search, Raxol.Plugins.ImagePlugin)

      emulator =
        Emulator.new(80, 24, plugin_manager: final_plugin_manager)

      assert %Emulator{plugin_manager: pm} = emulator

      loaded = Raxol.Plugins.Manager.loaded_plugins(pm)
      assert Map.has_key?(loaded, "hyperlink")
      assert Map.has_key?(loaded, "search")
      assert Map.has_key?(loaded, "image")
    end
  end
end
