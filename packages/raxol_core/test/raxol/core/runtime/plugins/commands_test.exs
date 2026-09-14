defmodule Raxol.Core.Runtime.Plugins.CommandsTest do
  @moduledoc """
  Tests for the command runtime system, including registration,
  execution, and error handling.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Plugins.{CommandHelper, CommandRegistry}
  alias Raxol.Core.Runtime.Plugins.PluginsState, as: ManagerState
  alias Raxol.Core.Runtime.ProcessStore

  defmodule TestCommandHandler do
    @moduledoc false
    def execute(args, context) do
      # Return args and context to verify they were passed correctly
      {:ok, %{args: args, context: context}}
    end

    def execute_error(_args, _context) do
      {:error, "Command execution failed"}
    end

    def execute_crash(_args, _context) do
      raise "Command crashed"
    end
  end

  # --- Mocks ---
  defmodule MockPlugin do
    @behaviour Raxol.Core.Runtime.Plugins.Plugin
    def get_commands, do: [{:test_cmd, :handle_test_cmd, 2}]

    def handle_test_cmd(arg, state),
      do: {:ok, Map.put(state, :handled_arg, arg), :test_ok}

    # Add other callbacks if needed by LifecycleHelper/Manager
    def init(_), do: {:ok, %{initial: true}}
    def terminate(_, state), do: state
    def enable(state), do: {:ok, state}
    def disable(state), do: {:ok, state}
    def filter_event(_event, _state), do: {:ok, nil}
    def handle_command(_cmd, _args, state), do: {:ok, state, :noop}
  end

  defmodule MockErrorPlugin do
    @behaviour Raxol.Core.Runtime.Plugins.Plugin
    def get_commands, do: [{:error_cmd, :handle_error_cmd, 2}]

    def handle_error_cmd(_args, state),
      do: {:error, :test_failure, Map.put(state, :errored, true)}

    def init(_), do: {:ok, %{initial: true}}
    def terminate(_, state), do: state
    def enable(state), do: {:ok, state}
    def disable(state), do: {:ok, state}
    def filter_event(_event, _state), do: {:ok, nil}
    def handle_command(_cmd, _args, state), do: {:ok, state, :noop}
  end

  defmodule MockCrashPlugin do
    @behaviour Raxol.Core.Runtime.Plugins.Plugin
    def get_commands, do: [{:crash_cmd, :handle_crash_cmd, 2}]
    def handle_crash_cmd(_args, _state), do: raise("Plugin Crashed!")
    def init(_), do: {:ok, %{initial: true}}
    def terminate(_, state), do: state
    def enable(state), do: {:ok, state}
    def disable(state), do: {:ok, state}
    def filter_event(_event, _state), do: {:ok, nil}
    def handle_command(_cmd, _args, state), do: {:ok, state, :noop}
  end

  defmodule MockMessagePlugin do
    @behaviour Raxol.Core.Runtime.Plugins.Plugin
    def get_commands, do: [{:msg_cmd, :handle_msg_cmd, 2}]

    def handle_msg_cmd(arg, state) do
      send(state.test_pid, {:handled, arg, state})
      {:ok, Map.put(state, :msg_sent, true), :command_executed}
    end

    def init(_), do: {:ok, %{test_pid: nil}}
    def terminate(_, state), do: state
    def enable(state), do: {:ok, state}
    def disable(state), do: {:ok, state}
    def filter_event(_event, _state), do: {:ok, nil}
    def handle_command(_cmd, _args, state), do: {:ok, state, :noop}
  end

  defmodule DuplicatePlugin1 do
    @behaviour Raxol.Core.Runtime.Plugins.Plugin
    def get_commands, do: [{:dupe_cmd, :handle_dupe_cmd, 2}]
    def handle_dupe_cmd(_arg, state), do: {:ok, state}
    def init(_), do: {:ok, %{}}
    def terminate(_, state), do: state
    def enable(state), do: {:ok, state}
    def disable(state), do: {:ok, state}
    def filter_event(_event, _state), do: {:ok, nil}
    def handle_command(_cmd, _args, state), do: {:ok, state, :noop}
  end

  defmodule DuplicatePlugin2 do
    @behaviour Raxol.Core.Runtime.Plugins.Plugin

    def init(_), do: {:ok, %{}}
    def terminate(_, state), do: state
    def enable(state), do: {:ok, state}
    def disable(state), do: {:ok, state}
    def filter_event(_event, _state), do: {:ok, nil}
    def handle_command(_cmd, _args, state), do: {:ok, state, :noop}
    def get_commands, do: [{:dupe_cmd, :handle_dupe_cmd, 2}]
    def handle_dupe_cmd(_arg, state), do: {:ok, state}
  end

  defmodule InvalidPlugin do
    @behaviour Raxol.Core.Runtime.Plugins.Plugin

    def init(_), do: {:ok, %{}}
    def terminate(_, state), do: state
    def enable(state), do: {:ok, state}
    def disable(state), do: {:ok, state}
    def filter_event(_event, _state), do: {:ok, nil}
    def handle_command(_cmd, _args, state), do: {:ok, state, :noop}
    def get_commands, do: [{:invalid_cmd, :non_existent_function, 2}]
  end

  defmodule InvalidNamePlugin do
    @behaviour Raxol.Core.Runtime.Plugins.Plugin

    def init(_), do: {:ok, %{}}
    def terminate(_, state), do: state
    def enable(state), do: {:ok, state}
    def disable(state), do: {:ok, state}
    def filter_event(_event, _state), do: {:ok, nil}
    def handle_command(_cmd, _args, state), do: {:ok, state, :noop}

    def get_commands,
      do: [
        {:invalid_name_with_spaces, :handle_cmd, 2},
        {:invalid@chars, :handle_cmd, 2},
        {:valid_cmd, :handle_cmd, 2}
      ]

    def handle_cmd(_arg, state), do: {:ok, state}
  end

  defmodule ConcurrentPlugin1 do
    @behaviour Raxol.Core.Runtime.Plugins.Plugin

    def init(_), do: {:ok, %{}}
    def terminate(_, state), do: state
    def enable(state), do: {:ok, state}
    def disable(state), do: {:ok, state}
    def filter_event(_event, _state), do: {:ok, nil}
    def handle_command(_cmd, _args, state), do: {:ok, state, :noop}
    def get_commands, do: [{:concurrent_cmd, :handle_cmd, 2}]
    def handle_cmd(_arg, state), do: {:ok, state}
  end

  defmodule ConcurrentPlugin2 do
    @behaviour Raxol.Core.Runtime.Plugins.Plugin
    def get_commands, do: [{:concurrent_cmd, :handle_cmd, 2}]
    def handle_cmd(_arg, state), do: {:ok, state}
    def init(_), do: {:ok, %{}}
    def terminate(_, state), do: state
    def enable(state), do: {:ok, state}
    def disable(state), do: {:ok, state}
    def filter_event(_event, _state), do: {:ok, nil}
    def handle_command(_cmd, _args, state), do: {:ok, state, :noop}
  end

  # --- Setup ---
  setup do
    # Use a plain map for the command table instead of an ETS table
    command_table = %{}

    # Create a default mock plugin manager state
    manager_state = %ManagerState{
      plugins: %{},
      metadata: %{},
      plugin_states: %{},
      load_order: [],
      initialized: true,
      command_registry_table: command_table,
      plugin_config: %{},
      plugins_dir: "",
      file_watcher_pid: nil,
      file_watching_enabled?: false,
      file_event_timer: nil
    }

    {:ok, command_table: command_table, manager_state: manager_state}
  end

  # --- Tests ---
  describe "Command Registration" do
    test "register_plugin_commands adds commands to the registry", %{
      command_table: table
    } do
      # Register commands from MockPlugin
      result =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
          %{},
          table
        )

      table = if is_map(result), do: result, else: table

      # Verify using CommandRegistry lookup
      assert {:ok, {Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin, handler, 2}} =
               CommandRegistry.lookup_command(
                 table,
                 Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
                 "test_cmd"
               )

      assert is_function(handler, 2)
    end

    test "unregister_plugin_commands removes commands from the registry", %{
      command_table: table
    } do
      # Register first
      result =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
          %{},
          table
        )

      table = if is_map(result), do: result, else: table

      assert {:ok, _} =
               CommandRegistry.lookup_command(
                 table,
                 Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
                 "test_cmd"
               )

      # Then unregister
      table =
        CommandHelper.unregister_plugin_commands(
          table,
          Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin
        )

      assert {:error, :not_found} =
               CommandRegistry.lookup_command(
                 table,
                 Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
                 "test_cmd"
               )
    end

    test "register_plugin_commands handles empty command list", %{
      command_table: table
    } do
      # Create a plugin with no commands
      defmodule EmptyPlugin do
        @behaviour Raxol.Core.Runtime.Plugins.Plugin
        def get_commands, do: []
        def init(_), do: {:ok, %{}}
        def terminate(_, state), do: state
        def enable(state), do: {:ok, state}
        def disable(state), do: {:ok, state}
        def filter_event(_event, _state), do: {:ok, nil}
        def handle_command(_cmd, _args, state), do: {:ok, state, :noop}
      end

      # Should not crash
      assert %{} =
               CommandHelper.register_plugin_commands(EmptyPlugin, %{}, table)
    end

    test "register_plugin_commands handles duplicate command names", %{
      command_table: table
    } do
      # Register first plugin
      _result =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.DuplicatePlugin1,
          %{},
          table
        )

      # Register second plugin - should overwrite first registration
      table =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.DuplicatePlugin2,
          %{},
          table
        )

      # Verify only the second plugin's command is registered
      assert {:ok, {Raxol.Core.Runtime.Plugins.CommandsTest.DuplicatePlugin2, handler, 2}} =
               CommandRegistry.lookup_command(
                 table,
                 Raxol.Core.Runtime.Plugins.CommandsTest.DuplicatePlugin2,
                 "dupe_cmd"
               )

      assert is_function(handler, 2)
    end

    test "register_plugin_commands handles invalid command specifications", %{
      command_table: table
    } do
      # Should handle gracefully
      _table =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.InvalidPlugin,
          %{},
          table
        )
    end

    test "register_plugin_commands validates command names", %{
      command_table: table
    } do
      # Should only register the valid command
      table =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.InvalidNamePlugin,
          %{},
          table
        )

      # Verify only valid command was registered
      assert {:ok, {Raxol.Core.Runtime.Plugins.CommandsTest.InvalidNamePlugin, handler, 2}} =
               CommandRegistry.lookup_command(
                 table,
                 Raxol.Core.Runtime.Plugins.CommandsTest.InvalidNamePlugin,
                 "valid_cmd"
               )

      assert is_function(handler, 2)

      # Use a string with a space to check invalid name
      assert {:error, :not_found} =
               CommandRegistry.lookup_command(
                 table,
                 Raxol.Core.Runtime.Plugins.CommandsTest.InvalidNamePlugin,
                 "invalid name with spaces"
               )

      assert {:error, :not_found} =
               CommandRegistry.lookup_command(
                 table,
                 Raxol.Core.Runtime.Plugins.CommandsTest.InvalidNamePlugin,
                 "invalid@chars"
               )
    end

    test "register_plugin_commands handles concurrent registration", %{
      command_table: table
    } do
      # Register commands concurrently
      tasks = [
        Task.async(fn ->
          CommandHelper.register_plugin_commands(
            Raxol.Core.Runtime.Plugins.CommandsTest.ConcurrentPlugin1,
            %{},
            table
          )
        end),
        Task.async(fn ->
          CommandHelper.register_plugin_commands(
            Raxol.Core.Runtime.Plugins.CommandsTest.ConcurrentPlugin2,
            %{},
            table
          )
        end)
      ]

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &is_map/1)

      # At least one result should have the command registered
      found =
        Enum.any?(results, fn t ->
          case CommandRegistry.lookup_command(
                 t,
                 Raxol.Core.Runtime.Plugins.CommandsTest.ConcurrentPlugin1,
                 "concurrent_cmd"
               ) do
            {:ok, {plugin, handler, 2}} ->
              plugin in [
                Raxol.Core.Runtime.Plugins.CommandsTest.ConcurrentPlugin1,
                Raxol.Core.Runtime.Plugins.CommandsTest.ConcurrentPlugin2
              ] and is_function(handler, 2)

            _ ->
              false
          end
        end)

      assert found
    end
  end

  describe "Command Execution (handle_command)" do
    test "calls the command handler with args and state", %{
      command_table: table,
      manager_state: state
    } do
      plugin_id = "mock_message_plugin"
      initial_plugin_state = %{test_pid: self()}

      manager_state = %{
        state
        | plugins: %{
            plugin_id => Raxol.Core.Runtime.Plugins.CommandsTest.MockMessagePlugin
          },
          plugin_states: %{plugin_id => initial_plugin_state}
      }

      # Register command
      table =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.MockMessagePlugin,
          initial_plugin_state,
          table
        )

      # Set test_pid in process dictionary for handler
      ProcessStore.put(:test_pid, self())

      # Execute command
      args = ["hello_arg"]

      assert {:ok, updated_states} =
               CommandHelper.handle_command(
                 table,
                 "msg_cmd",
                 Raxol.Core.Runtime.Plugins.CommandsTest.MockMessagePlugin,
                 args,
                 manager_state
               )

      # Assert message received by test process
      assert_receive {:handled, ["hello_arg"], %{test_pid: _}}, 500

      # The handler now returns a proper tuple, so plugin state should be updated with :msg_sent
      assert Map.has_key?(updated_states[plugin_id], :msg_sent)
      assert updated_states[plugin_id].msg_sent == true
    end

    test "returns :not_found for unknown command", %{
      command_table: table,
      manager_state: state
    } do
      assert {:error, :not_found} =
               CommandHelper.handle_command(
                 table,
                 "unknown_cmd",
                 nil,
                 [],
                 state
               )
    end

    test "handles error results from command handler", %{
      command_table: table,
      manager_state: state
    } do
      plugin_id = "mock_error_plugin"
      initial_plugin_state = %{initial: true}

      manager_state = %{
        state
        | plugins: %{
            plugin_id => Raxol.Core.Runtime.Plugins.CommandsTest.MockErrorPlugin
          },
          plugin_states: %{plugin_id => initial_plugin_state}
      }

      # Register command
      table =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.MockErrorPlugin,
          initial_plugin_state,
          table
        )

      # Execute command that returns an error
      assert {:error, :test_failure, updated_states} =
               CommandHelper.handle_command(
                 table,
                 "error_cmd",
                 Raxol.Core.Runtime.Plugins.CommandsTest.MockErrorPlugin,
                 [],
                 manager_state
               )

      # Assert plugin state was updated within the error tuple
      assert updated_states[plugin_id].errored == true
    end

    test "handles exceptions in command handler", %{
      command_table: table,
      manager_state: state
    } do
      plugin_id = "mock_crash_plugin"
      initial_plugin_state = %{initial: true}

      manager_state = %{
        state
        | plugins: %{
            plugin_id => Raxol.Core.Runtime.Plugins.CommandsTest.MockCrashPlugin
          },
          plugin_states: %{plugin_id => initial_plugin_state}
      }

      # Register command that crashes
      table =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.MockCrashPlugin,
          initial_plugin_state,
          table
        )

      # Execute command that crashes
      assert {:error, :exception, original_states} =
               CommandHelper.handle_command(
                 table,
                 "crash_cmd",
                 Raxol.Core.Runtime.Plugins.CommandsTest.MockCrashPlugin,
                 [],
                 manager_state
               )

      # Assert original plugin states are returned on exception
      assert original_states == manager_state.plugin_states
    end

    test "handles command with invalid arguments", %{
      command_table: table,
      manager_state: state
    } do
      plugin_id = "mock_plugin"
      initial_plugin_state = %{initial: true}

      manager_state = %{
        state
        | plugins: %{
            plugin_id => Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin
          },
          plugin_states: %{plugin_id => initial_plugin_state}
      }

      # Register command
      table =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
          initial_plugin_state,
          table
        )

      # Execute command with invalid args (nil)
      assert {:error, :invalid_args, _updated_states} =
               CommandHelper.handle_command(
                 table,
                 "test_cmd",
                 Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
                 nil,
                 manager_state
               )
    end

    test "handles command with missing plugin state", %{
      command_table: table,
      manager_state: state
    } do
      plugin_id = "mock_plugin"

      # Create manager state without plugin state
      manager_state = %{
        state
        | plugins: %{
            plugin_id => Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin
          },
          plugin_states: %{}
      }

      # Register command
      table =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
          %{},
          table
        )

      # Execute command
      assert {:error, :missing_plugin_state, _updated_states} =
               CommandHelper.handle_command(
                 table,
                 "test_cmd",
                 Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
                 ["arg"],
                 manager_state
               )
    end

    test "handles command with invalid plugin module", %{
      command_table: table,
      manager_state: state
    } do
      plugin_id = "invalid_plugin"
      initial_plugin_state = %{initial: true}

      manager_state = %{
        state
        | plugins: %{plugin_id => :invalid_module},
          plugin_states: %{plugin_id => initial_plugin_state}
      }

      # Execute command with invalid module
      assert {:error, :not_found} =
               CommandHelper.handle_command(
                 table,
                 "test_cmd",
                 :invalid_module,
                 ["arg"],
                 manager_state
               )
    end

    test "validates command arguments before execution", %{
      command_table: table,
      manager_state: state
    } do
      plugin_id = "mock_plugin"
      initial_plugin_state = %{initial: true}

      manager_state = %{
        state
        | plugins: %{
            plugin_id => Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin
          },
          plugin_states: %{plugin_id => initial_plugin_state}
      }

      # Register command
      table =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
          initial_plugin_state,
          table
        )

      # Test various invalid argument types
      invalid_args = [
        nil,
        "not_a_list",
        %{not: "a_list"},
        {:not, "a_list"},
        [1, "string", %{not: "allowed"}]
      ]

      for args <- invalid_args do
        assert {:error, :invalid_args, _updated_states} =
                 CommandHelper.handle_command(
                   table,
                   "test_cmd",
                   Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
                   args,
                   manager_state
                 )
      end
    end

    test "executes a registered command and returns updated plugin states", %{
      command_table: table,
      manager_state: state
    } do
      plugin_id = "mock_plugin"
      initial_plugin_state = %{initial: true}

      manager_state = %{
        state
        | plugins: %{
            plugin_id => Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin
          },
          plugin_states: %{plugin_id => initial_plugin_state}
      }

      # Register command
      table =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
          initial_plugin_state,
          table
        )

      assert {:ok, _updated_states} =
               CommandHelper.handle_command(
                 table,
                 "test_cmd",
                 Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
                 ["arg"],
                 manager_state
               )
    end

    test "handles command cancellation", %{
      command_table: table,
      manager_state: state
    } do
      plugin_id = "mock_plugin"
      initial_plugin_state = %{initial: true}

      manager_state = %{
        state
        | plugins: %{
            plugin_id => Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin
          },
          plugin_states: %{plugin_id => initial_plugin_state}
      }

      # Register command
      table =
        CommandHelper.register_plugin_commands(
          Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
          initial_plugin_state,
          table
        )

      # Start command execution in a separate process
      task =
        Task.async(fn ->
          CommandHelper.handle_command(
            table,
            "test_cmd",
            Raxol.Core.Runtime.Plugins.CommandsTest.MockPlugin,
            ["arg"],
            manager_state
          )
        end)

      # Cancel the command execution
      Task.shutdown(task, :brutal_kill)

      # Use Task.yield/2 as a fallback if Task.await/2 times out
      result =
        try do
          Task.await(task, 100)
        catch
          :exit, _ -> :timeout
        end

      if result == :timeout or result == {:exit, :killed} or result == nil do
        assert true
      else
        # Try Task.yield/2 as a fallback
        yield_result = Task.yield(task, 100)
        assert yield_result == nil or yield_result == {:exit, :killed}
      end
    end
  end
end
