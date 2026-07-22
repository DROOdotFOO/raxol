defmodule Raxol.Terminal.Plugin.UnifiedPluginTest do
  use ExUnit.Case, async: false
  alias Raxol.Terminal.Plugin.PluginServer

  setup do
    # Stop any existing PluginServer
    case Process.whereis(PluginServer) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, pid} =
      PluginServer.start_link(
        name: PluginServer,
        plugin_paths: ["test/fixtures/plugins"],
        auto_load: false
      )

    theme_file = "test/fixtures/plugins/theme/theme.ex"
    original_content = File.read!(theme_file)

    on_exit(fn ->
      # Always restore the theme file after each test
      File.write!(theme_file, original_content)

      # Server may be mid-shutdown at teardown; swallow the stop's :exit.
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "basic operations" do
    test ~c"loads and unloads plugins" do
      # Load theme plugin
      assert {:ok, theme_id} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/theme",
                 :theme,
                 name: "Test Theme",
                 version: "1.0.0"
               )

      # Load script plugin
      assert {:ok, script_id} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/script",
                 :script,
                 name: "Test Script",
                 version: "1.0.0"
               )

      # Get plugin states
      assert {:ok, theme_state} = PluginServer.get_plugin_state(theme_id)
      assert {:ok, script_state} = PluginServer.get_plugin_state(script_id)

      assert theme_state.type == :theme
      assert script_state.type == :script

      # Unload plugins
      assert :ok = PluginServer.unload_plugin(theme_id)
      assert :ok = PluginServer.unload_plugin(script_id)

      assert {:error, :plugin_not_found} =
               PluginServer.get_plugin_state(theme_id)

      assert {:error, :plugin_not_found} =
               PluginServer.get_plugin_state(script_id)
    end

    test ~c"handles plugin configuration" do
      # Load plugin with config
      config = %{
        colors: %{
          background: "#000000",
          foreground: "#ffffff"
        },
        font: "monospace"
      }

      assert {:ok, plugin_id} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/theme",
                 :theme,
                 name: "Test Theme",
                 version: "1.0.0",
                 config: config
               )

      # Update config
      new_config = %{
        colors: %{
          background: "#ffffff",
          foreground: "#000000"
        },
        font: "sans-serif"
      }

      assert :ok = PluginServer.update_plugin_config(plugin_id, new_config)

      # Verify config update
      assert {:ok, plugin_state} = PluginServer.get_plugin_state(plugin_id)
      assert plugin_state.config == new_config
    end
  end

  describe "plugin types" do
    test ~c"handles theme plugins" do
      assert {:ok, plugin_id} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/theme",
                 :theme,
                 name: "Test Theme",
                 version: "1.0.0"
               )

      # Execute theme function
      assert {:ok, result} =
               PluginServer.execute_plugin_function(
                 plugin_id,
                 :apply_theme,
                 [%{colors: %{background: "#000000"}}]
               )

      assert is_map(result)
    end

    test ~c"handles script plugins" do
      assert {:ok, plugin_id} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/script",
                 :script,
                 name: "Test Script",
                 version: "1.0.0"
               )

      # Execute script function
      assert {:ok, result} =
               PluginServer.execute_plugin_function(
                 plugin_id,
                 :run_script,
                 ["test_script"]
               )

      assert {:ok, result_map} = result
      assert is_map(result_map)
    end

    test ~c"handles extension plugins" do
      assert {:ok, plugin_id} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/extension",
                 :extension,
                 name: "Test Extension",
                 version: "1.0.0"
               )

      # Execute extension function
      assert {:ok, result} =
               PluginServer.execute_plugin_function(
                 plugin_id,
                 :run_extension,
                 ["test_extension"]
               )

      assert {:ok, result_map} = result
      assert is_map(result_map)
    end
  end

  describe "plugin management" do
    test ~c"lists plugins with filters" do
      # Load different types of plugins
      assert {:ok, theme_id} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/theme",
                 :theme,
                 name: "Test Theme",
                 version: "1.0.0"
               )

      assert {:ok, _script_id} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/script",
                 :script,
                 name: "Test Script",
                 version: "1.0.0"
               )

      # Get all plugins
      assert {:ok, all_plugins} = PluginServer.get_plugins()
      assert map_size(all_plugins) == 2

      # Filter by type
      assert {:ok, theme_plugins} = PluginServer.get_plugins(type: :theme)
      assert map_size(theme_plugins) == 1
      assert Map.has_key?(theme_plugins, theme_id)

      # Filter by status
      assert {:ok, active_plugins} = PluginServer.get_plugins(status: :active)
      assert map_size(active_plugins) == 2
    end

    test ~c"handles plugin dependencies" do
      # Load dependent plugin - currently fails due to missing dependency
      assert {:error, :module_not_found} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/dependent",
                 :extension,
                 name: "Dependent Plugin",
                 version: "1.0.0",
                 dependencies: ["base_plugin"]
               )

      # Load base plugin first
      assert {:ok, base_id} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/base",
                 :extension,
                 name: "base_plugin",
                 version: "1.0.0"
               )

      # Now dependent plugin should load successfully
      assert {:ok, dependent_id} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/dependent",
                 :extension,
                 name: "Dependent Plugin",
                 version: "1.0.0",
                 dependencies: ["base_plugin"]
               )

      # Verify both plugins are active
      assert {:ok, base_state} = PluginServer.get_plugin_state(base_id)
      assert base_state.status == :active

      assert {:ok, dependent_state} =
               PluginServer.get_plugin_state(dependent_id)

      assert dependent_state.status == :active
    end
  end

  describe "error handling" do
    test ~c"handles invalid plugin types" do
      assert {:error, :invalid_plugin_type} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/invalid",
                 :invalid_type,
                 name: "Invalid Plugin",
                 version: "1.0.0"
               )
    end

    test ~c"handles invalid plugin formats" do
      assert {:error, :enoent} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/invalid",
                 :theme,
                 name: "Invalid Plugin"
                 # Missing required fields
               )
    end

    test ~c"handles non-existent plugins" do
      assert {:error, :plugin_not_found} =
               PluginServer.get_plugin_state("non_existent")

      assert {:error, :plugin_not_found} =
               PluginServer.unload_plugin("non_existent")

      assert {:error, :plugin_not_found} =
               PluginServer.update_plugin_config("non_existent", %{})
    end

    test ~c"handles invalid configurations" do
      assert {:ok, plugin_id} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/theme",
                 :theme,
                 name: "Test Theme",
                 version: "1.0.0"
               )

      assert {:error, :invalid_config_format} =
               PluginServer.update_plugin_config(plugin_id, "invalid_config")
    end
  end

  describe "plugin reloading" do
    test ~c"reloads plugins successfully" do
      # Load plugin
      assert {:ok, plugin_id} =
               PluginServer.load_plugin(
                 "test/fixtures/plugins/theme",
                 :theme,
                 name: "Test Theme",
                 version: "1.0.0"
               )

      # Update plugin file
      # (In a real test, we would modify the plugin file here)

      # Reload plugin
      assert :ok = PluginServer.reload_plugin(plugin_id)

      # Verify plugin is still active
      assert {:ok, plugin_state} = PluginServer.get_plugin_state(plugin_id)
      assert plugin_state.status == :active
    end

    test ~c"handles reload errors" do
      # Create a temporary copy of the theme plugin for this test
      original_theme_dir = "test/fixtures/plugins/theme"

      temp_theme_dir =
        "test/fixtures/plugins/theme_temp_#{System.system_time()}"

      # Copy the theme plugin to a temporary location
      File.cp_r!(original_theme_dir, temp_theme_dir)

      # Load plugin from temporary location
      assert {:ok, plugin_id} =
               PluginServer.load_plugin(
                 temp_theme_dir,
                 :theme,
                 name: "Test Theme",
                 version: "1.0.0"
               )

      temp_theme_file = Path.join(temp_theme_dir, "theme.ex")
      original_content = File.read!(temp_theme_file)

      # Corrupt the temporary theme file
      File.write!(
        temp_theme_file,
        "defmodule InvalidModule do\n  def broken_function(\nend"
      )

      try do
        # Attempt to reload - should fail
        assert {:error, :reload_failed, _state} =
                 PluginServer.reload_plugin(plugin_id)

        # Verify plugin is in error state
        assert {:ok, plugin_state} = PluginServer.get_plugin_state(plugin_id)
        assert plugin_state.status == :error
      after
        # Clean up: restore the temporary file and remove the temp directory
        File.write!(temp_theme_file, original_content)
        File.rm_rf!(temp_theme_dir)

        # Purge and delete the corrupted module if it was loaded
        try do
          :code.purge(InvalidModule)
          :code.delete(InvalidModule)
        rescue
          _ -> :ok
        end

        # Additional cleanup: remove any compiled beam files
        beam_file = Path.join(temp_theme_dir, "InvalidModule.beam")
        if File.exists?(beam_file), do: File.rm!(beam_file)
      end
    end
  end
end
