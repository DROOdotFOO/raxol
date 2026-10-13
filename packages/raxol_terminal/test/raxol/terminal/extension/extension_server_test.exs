defmodule Raxol.Terminal.Extension.ExtensionServerTest do
  use ExUnit.Case, async: false
  alias Raxol.Terminal.Extension.ExtensionServer

  setup do
    start_supervised!(
      {ExtensionServer,
       name: ExtensionServer, extension_paths: ["test/fixtures/extensions"], auto_load: false}
    )

    :ok
  end

  describe "basic operations" do
    test "loads and unloads extensions" do
      # Load extension
      assert {:ok, extension_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/theme",
                 :theme,
                 name: "Test Theme",
                 version: "1.0.0",
                 description: "A test theme extension",
                 author: "Test Author",
                 license: "MIT"
               )

      # Get extension state
      assert {:ok, extension_state} =
               ExtensionServer.get_extension_state(extension_id)

      assert extension_state.name == "Test Theme"
      assert extension_state.type == :theme
      assert extension_state.version == "1.0.0"
      assert extension_state.description == "A test theme extension"
      assert extension_state.author == "Test Author"
      assert extension_state.license == "MIT"

      # Unload extension
      assert :ok = ExtensionServer.unload_extension(extension_id)

      assert {:error, :extension_not_found} =
               ExtensionServer.get_extension_state(extension_id)
    end

    test "handles extension configuration" do
      # Load extension with config
      config = %{
        theme: %{
          colors: %{
            background: "#000000",
            foreground: "#ffffff"
          },
          font: %{
            family: "monospace",
            size: 12
          }
        }
      }

      assert {:ok, extension_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/theme",
                 :theme,
                 name: "Test Theme",
                 config: config
               )

      # Update config
      new_config = %{
        theme: %{
          colors: %{
            background: "#ffffff",
            foreground: "#000000"
          },
          font: %{
            family: "sans-serif",
            size: 14
          }
        }
      }

      assert :ok =
               ExtensionServer.update_extension_config(
                 extension_id,
                 new_config
               )

      # Verify config update
      assert {:ok, extension_state} =
               ExtensionServer.get_extension_state(extension_id)

      assert extension_state.config == new_config
    end
  end

  describe "extension activation" do
    test "activates and deactivates extensions" do
      # Load extension
      assert {:ok, extension_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/theme",
                 :theme,
                 name: "Test Theme"
               )

      # Activate extension
      assert :ok = ExtensionServer.activate_extension(extension_id)

      assert {:ok, extension_state} =
               ExtensionServer.get_extension_state(extension_id)

      assert extension_state.active == true

      # Deactivate extension
      assert :ok = ExtensionServer.deactivate_extension(extension_id)

      assert {:ok, extension_state} =
               ExtensionServer.get_extension_state(extension_id)

      assert extension_state.active == false
    end

    test "handles invalid activation states" do
      # Load extension
      assert {:ok, extension_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/theme",
                 :theme,
                 name: "Test Theme"
               )

      # Try to deactivate idle extension
      assert {:error, :invalid_extension_state} =
               ExtensionServer.deactivate_extension(extension_id)

      # Activate extension
      assert :ok = ExtensionServer.activate_extension(extension_id)

      # Try to activate active extension
      assert {:error, :invalid_extension_state} =
               ExtensionServer.activate_extension(extension_id)
    end
  end

  describe "extension commands" do
    test "executes extension commands" do
      # Load extension with commands
      assert {:ok, extension_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/script",
                 :script,
                 name: "Test Script",
                 commands: ["run", "stop", "status"]
               )

      # Execute command
      assert {:ok, result} =
               ExtensionServer.execute_command(extension_id, "run", [
                 "arg1",
                 "arg2"
               ])

      assert result =~ "Command \"run\" executed with args:"

      # Try to execute non-existent command
      assert {:error, :command_not_found} =
               ExtensionServer.execute_command(extension_id, "invalid")
    end
  end

  describe "extension management" do
    test "lists extensions with filters" do
      # Load different extensions
      assert {:ok, _theme_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/theme",
                 :theme,
                 name: "Test Theme"
               )

      assert {:ok, script_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/script",
                 :script,
                 name: "Test Script"
               )

      # Get all extensions
      assert {:ok, all_extensions} = ExtensionServer.get_extensions()
      assert length(all_extensions) == 2

      # Filter by type
      assert {:ok, theme_extensions} =
               ExtensionServer.get_extensions(type: :theme)

      assert length(theme_extensions) == 1

      # Filter by status (inactive extensions)
      assert {:ok, idle_extensions} =
               ExtensionServer.get_extensions(active: false)

      assert length(idle_extensions) == 2
    end

    test "exports and imports extensions" do
      # Load extension
      assert {:ok, extension_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/theme",
                 :theme,
                 name: "Test Theme"
               )

      # Export extension
      export_path = "test/fixtures/extensions/exported.json"
      assert :ok = ExtensionServer.export_extension(extension_id, export_path)

      # Import extension
      assert {:ok, imported_id} = ExtensionServer.import_extension(export_path)

      # Verify imported extension
      assert {:ok, original_state} =
               ExtensionServer.get_extension_state(extension_id)

      assert {:ok, imported_state} =
               ExtensionServer.get_extension_state(imported_id)

      assert imported_state.name == original_state.name
      assert imported_state.type == original_state.type
      assert imported_state.version == original_state.version

      # Clean up
      File.rm!(export_path)
    end
  end

  describe "extension hooks" do
    test "registers and unregisters hooks" do
      # Load extension with hooks
      assert {:ok, extension_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/plugin",
                 :plugin,
                 name: "Test Plugin",
                 hooks: ["init", "cleanup", "update"]
               )

      # Register hook
      callback = fn args -> {:ok, args} end

      assert :ok =
               ExtensionServer.register_hook(extension_id, "init", callback)

      # Trigger hook
      assert {:ok, result} = ExtensionServer.trigger_hook(extension_id, "init", ["test"])
      assert result == {:ok, ["test"]}

      # Unregister hook
      assert :ok = ExtensionServer.unregister_hook(extension_id, "init")

      # Verify hook is unregistered
      assert {:error, :hook_not_found} =
               ExtensionServer.trigger_hook(extension_id, "init", ["test"])
    end

    test "handles hook errors" do
      # Load extension with hooks
      assert {:ok, extension_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/plugin",
                 :plugin,
                 name: "Test Plugin",
                 hooks: ["error"]
               )

      # Register hook that raises an error
      callback = fn _args -> raise "Hook error" end

      assert :ok =
               ExtensionServer.register_hook(extension_id, "error", callback)

      # Trigger hook
      assert {:ok, result} = ExtensionServer.trigger_hook(extension_id, "error", ["test"])
      assert result == {:error, :hook_execution_failed}
    end
  end

  describe "error handling" do
    test "handles invalid extension types" do
      assert {:error, {:module_load_failed, :invalid_extension_type}} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/invalid",
                 :invalid_type,
                 name: "Invalid Extension"
               )
    end

    test "handles invalid configurations" do
      assert {:ok, extension_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/theme",
                 :theme,
                 name: "Test Theme"
               )

      assert {:error, :invalid_extension_config} =
               ExtensionServer.update_extension_config(
                 extension_id,
                 "invalid_config"
               )
    end

    test "handles invalid dependencies" do
      assert {:error, :invalid_extension_dependencies} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/theme",
                 :theme,
                 name: "Test Theme",
                 dependencies: "invalid_dependencies"
               )
    end

    test "handles non-existent extensions" do
      assert {:error, :extension_not_found} =
               ExtensionServer.get_extension_state("non_existent")

      assert {:error, :extension_not_found} =
               ExtensionServer.unload_extension("non_existent")

      assert {:error, :extension_not_found} =
               ExtensionServer.update_extension_config("non_existent", %{})
    end

    test "handles invalid hook names" do
      # Load extension
      assert {:ok, extension_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/plugin",
                 :plugin,
                 name: "Test Plugin",
                 hooks: ["init"]
               )

      # Try to register invalid hook
      callback = fn args -> {:ok, args} end

      assert {:error, :hook_not_found} =
               ExtensionServer.register_hook(extension_id, "invalid", callback)
    end
  end

  describe "extension types" do
    test "handles different extension types" do
      # Theme extension
      assert {:ok, theme_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/theme",
                 :theme,
                 name: "Test Theme"
               )

      # Script extension
      assert {:ok, script_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/script",
                 :script,
                 name: "Test Script"
               )

      # Plugin extension
      assert {:ok, plugin_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/plugin",
                 :plugin,
                 name: "Test Plugin"
               )

      # Custom extension
      assert {:ok, custom_id} =
               ExtensionServer.load_extension(
                 "test/fixtures/extensions/custom",
                 :custom,
                 name: "Test Custom"
               )

      # Verify extension states
      assert {:ok, theme_state} = ExtensionServer.get_extension_state(theme_id)

      assert {:ok, script_state} =
               ExtensionServer.get_extension_state(script_id)

      assert {:ok, plugin_state} =
               ExtensionServer.get_extension_state(plugin_id)

      assert {:ok, custom_state} =
               ExtensionServer.get_extension_state(custom_id)

      assert theme_state.type == :theme
      assert script_state.type == :script
      assert plugin_state.type == :plugin
      assert custom_state.type == :custom
    end
  end
end
