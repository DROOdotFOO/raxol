defmodule Raxol.Terminal.Theme.ThemeServerTest do
  use ExUnit.Case, async: false
  alias Raxol.Terminal.Theme.ThemeServer

  setup do
    {:ok, pid} =
      ThemeServer.start_link(
        name: Raxol.Terminal.Theme.ThemeServer,
        theme_paths: ["test/fixtures/themes"],
        auto_load: false
      )

    on_exit(fn ->
      # Server may be mid-shutdown at teardown; swallow the stop's :exit.
      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end)

    %{pid: pid}
  end

  describe "initialization" do
    test "starts with default configuration", %{pid: pid} do
      state = :sys.get_state(pid)
      assert state.themes == %{}
      assert state.theme_paths == ["test/fixtures/themes"]
      assert state.auto_load == false
      assert state.current_theme == nil
      assert state.preview_theme == nil
      assert state.theme_config == %{}
    end

    test "initializes with custom configuration" do
      {:ok, pid} =
        ThemeServer.start_link(
          name: :custom_config_test,
          theme_paths: ["custom/path"],
          auto_load: true,
          theme_config: %{custom: "config"}
        )

      state = :sys.get_state(pid)
      assert state.theme_paths == ["custom/path"]
      assert state.auto_load == true
      assert state.theme_config == %{custom: "config"}
    end
  end

  describe "load_theme/2" do
    test "loads a valid theme from file", %{pid: _pid} do
      assert {:ok, theme_id} =
               ThemeServer.load_theme("test/fixtures/themes/dark.json")

      assert {:ok, theme_state} = ThemeServer.get_theme_state(theme_id)
      assert theme_state.name == "Dark Theme"
      assert theme_state.version == "1.0.0"

      assert theme_state.description ==
               "A dark theme for the Raxol terminal emulator"

      assert theme_state.author == "Raxol Team"
      assert theme_state.status == :active
      assert theme_state.error == nil
      assert is_map(theme_state.colors)
      assert is_map(theme_state.font)
      assert is_map(theme_state.cursor)
      assert is_map(theme_state.padding)
    end

    test "loads theme with custom options", %{pid: _pid} do
      opts = [name: "Custom Dark", version: "2.0.0"]

      assert {:ok, theme_id} =
               ThemeServer.load_theme("test/fixtures/themes/dark.json", opts)

      assert {:ok, theme_state} = ThemeServer.get_theme_state(theme_id)
      # Original name from file
      assert theme_state.name == "Dark Theme"
      # Original version from file
      assert theme_state.version == "1.0.0"
    end

    test "returns error for non-existent file", %{pid: _pid} do
      assert {:error, {:file_read_error, :enoent}} =
               ThemeServer.load_theme("non/existent/path.json")
    end

    test "returns error for invalid JSON", %{pid: _pid} do
      # Create a temporary invalid JSON file
      invalid_json = "invalid json content"
      temp_file = Path.join(System.tmp_dir!(), "invalid_theme.json")
      File.write!(temp_file, invalid_json)

      assert {:error, {:invalid_theme_format, _}} =
               ThemeServer.load_theme(temp_file)

      # Cleanup
      File.rm!(temp_file)
    end

    test "returns error for theme missing required fields", %{pid: _pid} do
      # Create a temporary incomplete theme file
      incomplete_theme = %{
        "name" => "Incomplete Theme",
        "version" => "1.0.0"
        # Missing required fields
      }

      temp_file = Path.join(System.tmp_dir!(), "incomplete_theme.json")
      File.write!(temp_file, Jason.encode!(incomplete_theme))

      assert {:error, :invalid_theme_format} =
               ThemeServer.load_theme(temp_file)

      # Cleanup
      File.rm!(temp_file)
    end
  end

  describe "unload_theme/1" do
    test "unloads an existing theme", %{pid: _pid} do
      # First load a theme
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      assert {:ok, _theme_state} = ThemeServer.get_theme_state(theme_id)

      # Then unload it
      assert :ok = ThemeServer.unload_theme(theme_id)
      assert {:error, :theme_not_found} = ThemeServer.get_theme_state(theme_id)
    end

    test "returns error for non-existent theme", %{pid: _pid} do
      assert {:error, :theme_not_found} =
               ThemeServer.unload_theme("non_existent_theme")
    end
  end

  describe "get_theme_state/1" do
    test "returns theme state for existing theme", %{pid: _pid} do
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      assert {:ok, theme_state} = ThemeServer.get_theme_state(theme_id)
      assert theme_state.name == "Dark Theme"
      assert theme_state.status == :active
    end

    test "returns error for non-existent theme", %{pid: _pid} do
      assert {:error, :theme_not_found} =
               ThemeServer.get_theme_state("non_existent_theme")
    end
  end

  describe "get_themes/1" do
    test "returns all loaded themes", %{pid: _pid} do
      # Load multiple themes
      {:ok, dark_theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      {:ok, light_theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/light.json")

      assert {:ok, themes} = ThemeServer.get_themes()
      assert map_size(themes) == 2
      assert Map.has_key?(themes, dark_theme_id)
      assert Map.has_key?(themes, light_theme_id)
    end

    test "filters themes by status", %{pid: _pid} do
      {:ok, dark_theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      assert {:ok, themes} = ThemeServer.get_themes(status: :active)
      assert map_size(themes) == 1
      assert Map.has_key?(themes, dark_theme_id)

      assert {:ok, themes} = ThemeServer.get_themes(status: :inactive)
      assert map_size(themes) == 0
    end

    test "returns empty map when no themes loaded", %{pid: _pid} do
      assert {:ok, themes} = ThemeServer.get_themes()
      assert themes == %{}
    end
  end

  describe "update_theme_config/2" do
    test "updates theme configuration", %{pid: _pid} do
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      new_config = %{custom_setting: "value", another_setting: 123}
      assert :ok = ThemeServer.update_theme_config(theme_id, new_config)

      assert {:ok, theme_state} = ThemeServer.get_theme_state(theme_id)
      assert theme_state.config == new_config
    end

    test "returns error for non-existent theme", %{pid: _pid} do
      config = %{setting: "value"}

      assert {:error, :theme_not_found} =
               ThemeServer.update_theme_config("non_existent", config)
    end

    test "returns error for invalid config format", %{pid: _pid} do
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      assert {:error, :invalid_config_format} =
               ThemeServer.update_theme_config(theme_id, "not_a_map")
    end
  end

  describe "apply_theme/1" do
    test "applies an active theme", %{pid: pid} do
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      assert :ok = ThemeServer.apply_theme(theme_id)

      state = :sys.get_state(pid)
      assert state.current_theme == theme_id
    end

    test "returns error for non-existent theme", %{pid: _pid} do
      assert {:error, :theme_not_found} =
               ThemeServer.apply_theme("non_existent_theme")
    end

    test "returns error for inactive theme", %{pid: pid} do
      # This test would require modifying a theme's status to :inactive
      # Since the current implementation always sets status to :active,
      # we'll test the error path by creating a theme with inactive status
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      # Manually set the theme status to inactive in the state
      state = :sys.get_state(pid)

      inactive_theme =
        Map.get(state.themes, theme_id) |> Map.put(:status, :inactive)

      new_state = Map.put(state.themes, theme_id, inactive_theme)
      :sys.replace_state(pid, fn _ -> Map.put(state, :themes, new_state) end)

      assert {:error, :theme_inactive} = ThemeServer.apply_theme(theme_id)
    end

    test "returns error for theme with error status", %{pid: pid} do
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      # Manually set the theme status to error in the state
      state = :sys.get_state(pid)
      error_theme = Map.get(state.themes, theme_id) |> Map.put(:status, :error)
      new_state = Map.put(state.themes, theme_id, error_theme)
      :sys.replace_state(pid, fn _ -> Map.put(state, :themes, new_state) end)

      assert {:error, :theme_error} = ThemeServer.apply_theme(theme_id)
    end
  end

  describe "preview_theme/1" do
    test "previews an active theme", %{pid: pid} do
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      assert :ok = ThemeServer.preview_theme(theme_id)

      state = :sys.get_state(pid)
      assert state.preview_theme == theme_id
    end

    test "returns error for non-existent theme", %{pid: _pid} do
      assert {:error, :theme_not_found} =
               ThemeServer.preview_theme("non_existent_theme")
    end

    test "returns error for inactive theme", %{pid: pid} do
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      # Manually set the theme status to inactive
      state = :sys.get_state(pid)

      inactive_theme =
        Map.get(state.themes, theme_id) |> Map.put(:status, :inactive)

      new_state = Map.put(state.themes, theme_id, inactive_theme)
      :sys.replace_state(pid, fn _ -> Map.put(state, :themes, new_state) end)

      assert {:error, :theme_inactive} = ThemeServer.preview_theme(theme_id)
    end
  end

  describe "export_theme/2" do
    test "exports theme to file", %{pid: _pid} do
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      export_path = Path.join(System.tmp_dir!(), "exported_theme.json")

      assert :ok = ThemeServer.export_theme(theme_id, export_path)
      assert File.exists?(export_path)

      # Verify the exported content
      exported_content = File.read!(export_path)
      assert {:ok, exported_theme} = Jason.decode(exported_content)
      assert exported_theme["name"] == "Dark Theme"

      # Cleanup
      File.rm!(export_path)
    end

    test "returns error for non-existent theme", %{pid: _pid} do
      export_path = Path.join(System.tmp_dir!(), "exported_theme.json")

      assert {:error, :theme_not_found} =
               ThemeServer.export_theme("non_existent", export_path)
    end

    test "returns error for invalid export path", %{pid: _pid} do
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      # Try to export to a directory (which should fail)
      invalid_path = System.tmp_dir!()

      assert {:error, {:file_write_error, :eisdir}} =
               ThemeServer.export_theme(theme_id, invalid_path)
    end
  end

  describe "import_theme/1" do
    test "imports theme from file", %{pid: _pid} do
      import_path = "test/fixtures/themes/light.json"

      assert {:ok, theme_id} = ThemeServer.import_theme(import_path)

      assert {:ok, theme_state} = ThemeServer.get_theme_state(theme_id)
      assert theme_state.name == "Light Theme"
      assert theme_state.status == :active
    end

    test "returns error for non-existent file", %{pid: _pid} do
      assert {:error, {:file_read_error, :enoent}} =
               ThemeServer.import_theme("non/existent/path.json")
    end

    test "returns error for invalid JSON", %{pid: _pid} do
      # Create a temporary invalid JSON file
      invalid_json = "invalid json content"
      temp_file = Path.join(System.tmp_dir!(), "invalid_import.json")
      File.write!(temp_file, invalid_json)

      assert {:error, {:invalid_theme_format, _}} =
               ThemeServer.import_theme(temp_file)

      # Cleanup
      File.rm!(temp_file)
    end
  end

  describe "theme ID generation" do
    test "generates consistent IDs for same path", %{pid: _pid} do
      path = "test/fixtures/themes/dark.json"

      # Load the same theme twice
      {:ok, theme_id1} = ThemeServer.load_theme(path)
      {:ok, theme_id2} = ThemeServer.load_theme(path)

      assert theme_id1 == theme_id2
    end

    test "generates different IDs for different paths", %{pid: _pid} do
      {:ok, dark_theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      {:ok, light_theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/light.json")

      assert dark_theme_id != light_theme_id
    end
  end

  describe "theme validation" do
    test "validates theme with all required fields", %{pid: _pid} do
      # This test uses the existing valid theme files
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      assert {:ok, theme_state} = ThemeServer.get_theme_state(theme_id)

      # Verify all required fields are present
      required_fields = [
        :id,
        :name,
        :version,
        :description,
        :author,
        :colors,
        :font,
        :cursor,
        :padding
      ]

      Enum.each(required_fields, fn field ->
        assert Map.has_key?(theme_state, field)
      end)
    end

    test "rejects theme missing required fields", %{pid: _pid} do
      # Create a temporary incomplete theme file
      incomplete_theme = %{
        "name" => "Incomplete Theme",
        "version" => "1.0.0"
        # Missing required fields
      }

      temp_file = Path.join(System.tmp_dir!(), "incomplete_theme.json")
      File.write!(temp_file, Jason.encode!(incomplete_theme))

      assert {:error, :invalid_theme_format} =
               ThemeServer.load_theme(temp_file)

      # Cleanup
      File.rm!(temp_file)
    end
  end

  describe "state management" do
    test "maintains separate states for multiple instances", %{pid: _pid} do
      # Start another instance
      {:ok, pid2} = ThemeServer.start_link(name: :test_instance_2)

      # Load theme in first instance
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      # Verify theme exists in first instance
      assert {:ok, _theme_state} = ThemeServer.get_theme_state(theme_id)

      # Verify theme doesn't exist in second instance
      assert {:error, :theme_not_found} =
               GenServer.call(pid2, {:get_theme_state, theme_id})
    end

    test "handles concurrent theme operations", %{pid: _pid} do
      # Load multiple themes concurrently
      tasks = [
        Task.async(fn ->
          ThemeServer.load_theme("test/fixtures/themes/dark.json")
        end),
        Task.async(fn ->
          ThemeServer.load_theme("test/fixtures/themes/light.json")
        end)
      ]

      results = Task.await_many(tasks)

      # Both should succeed
      assert Enum.all?(results, fn {status, _} -> status == :ok end)

      # Verify both themes are loaded
      assert {:ok, themes} = ThemeServer.get_themes()
      assert map_size(themes) == 2
    end
  end

  describe "error handling" do
    test "handles file system errors gracefully", %{pid: _pid} do
      # Test with a directory that doesn't exist
      assert {:error, {:file_read_error, :enoent}} =
               ThemeServer.load_theme("/non/existent/path/theme.json")
    end

    test "handles JSON parsing errors", %{pid: _pid} do
      # Create a file with invalid JSON
      temp_file = Path.join(System.tmp_dir!(), "malformed.json")
      File.write!(temp_file, "{ invalid json")

      assert {:error, {:invalid_theme_format, _}} =
               ThemeServer.load_theme(temp_file)

      # Cleanup
      File.rm!(temp_file)
    end

    test "handles theme cleanup errors gracefully", %{pid: _pid} do
      # This test verifies that the system handles cleanup errors
      # The current implementation always returns :ok for cleanup
      {:ok, theme_id} =
        ThemeServer.load_theme("test/fixtures/themes/dark.json")

      # Unloading should always succeed
      assert :ok = ThemeServer.unload_theme(theme_id)
    end
  end
end
