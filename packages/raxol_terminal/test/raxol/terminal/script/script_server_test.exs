defmodule Raxol.Terminal.Script.UnifiedScriptTest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias Raxol.Terminal.Script.ScriptServer

  setup do
    # Stop any existing ScriptServer
    case Process.whereis(ScriptServer) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, pid} =
      ScriptServer.start_link(
        name: ScriptServer,
        script_paths: ["test/fixtures/scripts"],
        auto_load: false
      )

    on_exit(fn ->
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
    test "loads and unloads scripts" do
      # Load script
      source = """
      def hello do
        IO.puts("Hello, World!")
      end
      """

      assert {:ok, script_id} =
               ScriptServer.load_script(
                 source,
                 :elixir,
                 name: "Hello Script",
                 version: "1.0.0"
               )

      # Get script state
      assert {:ok, script_state} = ScriptServer.get_script_state(script_id)
      assert script_state.name == "Hello Script"
      assert script_state.type == :elixir
      assert script_state.source == source

      # Unload script
      assert :ok = ScriptServer.unload_script(script_id)

      assert {:error, :script_not_found} =
               ScriptServer.get_script_state(script_id)
    end

    test "handles script configuration" do
      # Load script with config
      source = """
      def hello do
        IO.puts("Hello, World!")
      end
      """

      config = %{
        timeout: 5000,
        retries: 3,
        debug: true
      }

      assert {:ok, script_id} =
               ScriptServer.load_script(
                 source,
                 :elixir,
                 name: "Hello Script",
                 version: "1.0.0",
                 config: config
               )

      # Update config
      new_config = %{
        timeout: 10_000,
        retries: 5,
        debug: false
      }

      assert :ok = ScriptServer.update_script_config(script_id, new_config)

      # Verify config update
      assert {:ok, script_state} = ScriptServer.get_script_state(script_id)
      assert script_state.config == new_config
    end
  end

  describe "script execution" do
    test "executes scripts with arguments" do
      # Load script
      source = """
      def main(name) do
        "Hello, \#{name}!"
      end
      """

      assert {:ok, script_id} =
               ScriptServer.load_script(
                 source,
                 :elixir,
                 name: "Hello Script"
               )

      # Execute script with argument
      assert {:ok, result} = ScriptServer.execute_script(script_id, ["World"])
      assert result == "Hello, World!"

      # Get script output
      assert {:ok, output} = ScriptServer.get_script_output(script_id)
      assert output == "Hello, World!"
    end

    test "handles script states" do
      # Load script
      source = """
      def long_running do
        Process.sleep(1000)
        "Done"
      end
      """

      assert {:ok, script_id} =
               ScriptServer.load_script(
                 source,
                 :elixir,
                 name: "Long Running Script"
               )

      # Execute script
      assert {:ok, _} = ScriptServer.execute_script(script_id)

      # Pause script
      assert :ok = ScriptServer.pause_script(script_id)
      assert {:ok, script_state} = ScriptServer.get_script_state(script_id)
      assert script_state.status == :paused

      # Resume script
      assert :ok = ScriptServer.resume_script(script_id)
      assert {:ok, script_state} = ScriptServer.get_script_state(script_id)
      assert script_state.status == :running

      # Stop script
      assert :ok = ScriptServer.stop_script(script_id)
      assert {:ok, script_state} = ScriptServer.get_script_state(script_id)
      assert script_state.status == :idle
    end
  end

  describe "script management" do
    test "lists scripts with filters" do
      # Load different scripts
      assert {:ok, _elixir_id} =
               ScriptServer.load_script(
                 "def hello do end",
                 :elixir,
                 name: "Elixir Script"
               )

      assert {:ok, _lua_id} =
               ScriptServer.load_script(
                 "function hello() end",
                 :lua,
                 name: "Lua Script"
               )

      # Get all scripts
      assert {:ok, all_scripts} = ScriptServer.get_scripts()
      assert map_size(all_scripts) == 2

      # Filter by type
      assert {:ok, elixir_scripts} = ScriptServer.get_scripts(type: :elixir)
      assert map_size(elixir_scripts) == 1

      # Filter by status
      assert {:ok, idle_scripts} = ScriptServer.get_scripts(status: :idle)
      assert map_size(idle_scripts) == 2
    end

    test "exports and imports scripts" do
      # Load script
      source = """
      def hello do
        IO.puts("Hello, World!")
      end
      """

      assert {:ok, script_id} =
               ScriptServer.load_script(
                 source,
                 :elixir,
                 name: "Hello Script"
               )

      # Export script
      export_path = "test/fixtures/scripts/exported.ex"
      assert :ok = ScriptServer.export_script(script_id, export_path)

      # Import script
      assert {:ok, imported_id} = ScriptServer.import_script(export_path)

      # Verify imported script
      assert {:ok, original_state} = ScriptServer.get_script_state(script_id)
      assert {:ok, imported_state} = ScriptServer.get_script_state(imported_id)
      assert imported_state.source == original_state.source
      assert imported_state.type == original_state.type

      # Clean up
      File.rm!(export_path)
    end
  end

  describe "error handling" do
    test "handles invalid script types" do
      assert {:error, :invalid_script_type} =
               ScriptServer.load_script(
                 "def hello do end",
                 :invalid_type,
                 name: "Invalid Script"
               )
    end

    test "handles invalid script sources" do
      assert {:error, :invalid_script_source} =
               ScriptServer.load_script(
                 "",
                 :elixir,
                 name: "Empty Script"
               )
    end

    test "handles invalid configurations" do
      assert {:ok, script_id} =
               ScriptServer.load_script(
                 "def hello do end",
                 :elixir,
                 name: "Hello Script"
               )

      assert {:error, :invalid_script_config} =
               ScriptServer.update_script_config(
                 script_id,
                 "invalid_config"
               )
    end

    test "handles non-existent scripts" do
      assert {:error, :script_not_found} =
               ScriptServer.get_script_state("non_existent")

      assert {:error, :script_not_found} =
               ScriptServer.unload_script("non_existent")

      assert {:error, :script_not_found} =
               ScriptServer.update_script_config("non_existent", %{})
    end

    test "handles invalid script states" do
      # Load script
      assert {:ok, script_id} =
               ScriptServer.load_script(
                 "def hello do end",
                 :elixir,
                 name: "Hello Script"
               )

      # Try to pause idle script
      assert {:error, :invalid_script_state} =
               ScriptServer.pause_script(script_id)

      # Try to resume idle script
      assert {:error, :invalid_script_state} =
               ScriptServer.resume_script(script_id)

      # Try to stop idle script
      assert {:error, :invalid_script_state} =
               ScriptServer.stop_script(script_id)
    end
  end

  describe "script types" do
    test "handles different script types" do
      # Elixir script
      elixir_source = """
      def hello do
        "Hello from Elixir"
      end
      """

      assert {:ok, elixir_id} =
               ScriptServer.load_script(
                 elixir_source,
                 :elixir,
                 name: "Elixir Script"
               )

      # Lua script
      lua_source = """
      function hello()
        return "Hello from Lua"
      end
      """

      assert {:ok, lua_id} =
               ScriptServer.load_script(
                 lua_source,
                 :lua,
                 name: "Lua Script"
               )

      # Python script
      python_source = """
      def hello():
          return "Hello from Python"
      """

      assert {:ok, python_id} =
               ScriptServer.load_script(
                 python_source,
                 :python,
                 name: "Python Script"
               )

      # JavaScript script
      js_source = """
      function hello() {
        return "Hello from JavaScript";
      }
      """

      assert {:ok, js_id} =
               ScriptServer.load_script(
                 js_source,
                 :javascript,
                 name: "JavaScript Script"
               )

      # Verify script states
      assert {:ok, elixir_state} = ScriptServer.get_script_state(elixir_id)
      assert {:ok, lua_state} = ScriptServer.get_script_state(lua_id)
      assert {:ok, python_state} = ScriptServer.get_script_state(python_id)
      assert {:ok, js_state} = ScriptServer.get_script_state(js_id)

      assert elixir_state.type == :elixir
      assert lua_state.type == :lua
      assert python_state.type == :python
      assert js_state.type == :javascript
    end
  end
end
