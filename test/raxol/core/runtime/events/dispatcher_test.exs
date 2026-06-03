defmodule Raxol.Core.Runtime.Events.DispatcherTest do
  use ExUnit.Case, async: false
  # Use Mox instead
  import Mox
  # Added for stub logging
  require Raxol.Core.Runtime.Log

  # Mox mocks definition
  defmock(ApplicationMock, for: Raxol.Core.Runtime.Application)

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Command
  alias Raxol.Core.Runtime.Events.Dispatcher

  # Simple Mock GenServer for PluginManager
  defmodule Mock.PluginManager do
    use GenServer

    def start_link(_opts) do
      # Accept :runtime_pid for compatibility, ignore it
      GenServer.start_link(__MODULE__, nil)
    end

    def init(_), do: {:ok, nil}
    # Allow call for filter_event
    def handle_call({:filter_event, event}, _from, state),
      do: {:reply, {:ok, event}, state}

    # Default reply
    def handle_call(_msg, _from, state), do: {:reply, :ok, state}
  end

  setup do
    # Ensure UserPreferences is started for tests
    prefs_opts = [name: Raxol.Core.UserPreferences, test_mode?: true]

    case Raxol.Core.UserPreferences.start_link(prefs_opts) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Ensure Registry is started
    case Registry.start_link(keys: :duplicate, name: :raxol_event_subscriptions) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  describe "GenServer Callbacks" do
    test ~c"handle_cast :dispatch dispatches event and updates state" do
      # Attempt to resize RenderingEngine buffer to minimize log output on failure
      # This is a temporary measure to help diagnose the actual test failure.
      # It assumes RenderingEngine is running and registered by this name.
      _ =
        GenServer.cast(
          Raxol.Core.Runtime.Rendering.Engine,
          {:update_size, %{width: 1, height: 1}}
        )

      # Start Mock Plugin Manager for this test
      {:ok, mock_pm_pid} = Mock.PluginManager.start_link([])

      # Start Test Command Module for this test
      {:ok, _test_command_agent} =
        Raxol.Core.Runtime.TestCommandModule.start_link()

      # Define initial state for this test
      initial_state = %{
        # Use ApplicationMock
        app_module: ApplicationMock,
        # This model is expected to be initialized by ApplicationMock.init
        model: %{count: 0},
        runtime_pid: self(),
        width: 80,
        height: 24,
        focused: true,
        debug_mode: false,
        # Use per-test PID
        plugin_manager: mock_pm_pid,
        command_registry_table: Raxol.Core.Runtime.TestCommandModule,
        # Use real PubSub
        pubsub_server: Phoenix.PubSub,
        # Ensure RenderingEngine is included
        rendering_engine: Raxol.Core.Runtime.Rendering.Engine,
        # Add missing key
        initial_commands: []
      }

      # Mox expectations
      Mox.expect(ApplicationMock, :init, fn _opts -> {:ok, %{count: 0}} end)

      event = %Event{
        type: :key,
        data: %{key: :enter, state: :pressed, modifiers: []}
      }

      # Fix: handle_event only takes one argument (the event)
      Mox.expect(ApplicationMock, :handle_event, fn ^event ->
        event
      end)

      # Fix: update takes message and model, returns {model, commands}
      # Events now arrive as raw %Event{} structs
      Mox.expect(ApplicationMock, :update, fn %Event{
                                                type: :key,
                                                data: %{key: :enter}
                                              },
                                              model ->
        {%{model | count: model.count + 1},
         [%Command{type: :system, data: {:test_cmd, []}}]}
      end)

      # Use real PubSub - no mocking needed

      # Use real UserPreferences - no mocking needed

      # Start Dispatcher for this test with test command module
      {:ok, dispatcher} =
        Dispatcher.start_link(self(), initial_state,
          command_module: Raxol.Core.Runtime.TestCommandModule
        )

      # Allow the dispatcher process to use the ApplicationMock
      Mox.allow(ApplicationMock, self(), dispatcher)

      :ok = GenServer.cast(dispatcher, {:dispatch, event})

      # Assertions (e.g., state change, messages sent)
      assert_receive :render_needed, 100
      current_state = :sys.get_state(dispatcher)
      assert current_state.model.count == 1

      # Verify commands were executed
      executed_commands =
        Raxol.Core.Runtime.TestCommandModule.get_executed_commands()

      assert length(executed_commands) == 1
      [{command, _context}] = executed_commands
      assert command.type == :system
      assert command.data == {:test_cmd, []}

      # Test-specific teardown
      on_exit(fn ->
        # Verify all Mox expectations
        Mox.verify!()
        # Stop processes gracefully, ignoring if already dead
        try do
          GenServer.stop(mock_pm_pid)
        catch
          :exit, _ -> :ok
        end

        try do
          Raxol.Core.Runtime.TestCommandModule.stop()
        catch
          :exit, _ -> :ok
        end
      end)
    end

    test ~c"handle_call :dispatch (ADR-0013 PR-C) mirrors cast: applies same state transition" do
      # Mirror of the cast test above; only the invocation method differs.
      # Sending {:dispatch, event} via GenServer.call must produce the
      # same model change and command execution as via cast.
      {:ok, mock_pm_pid} = Mock.PluginManager.start_link([])

      {:ok, _test_command_agent} =
        Raxol.Core.Runtime.TestCommandModule.start_link()

      initial_state = %{
        app_module: ApplicationMock,
        model: %{count: 0},
        runtime_pid: self(),
        width: 80,
        height: 24,
        focused: true,
        debug_mode: false,
        plugin_manager: mock_pm_pid,
        command_registry_table: Raxol.Core.Runtime.TestCommandModule,
        pubsub_server: Phoenix.PubSub,
        rendering_engine: Raxol.Core.Runtime.Rendering.Engine,
        initial_commands: []
      }

      Mox.expect(ApplicationMock, :init, fn _opts -> {:ok, %{count: 0}} end)

      event = %Event{
        type: :key,
        data: %{key: :enter, state: :pressed, modifiers: []}
      }

      Mox.expect(ApplicationMock, :handle_event, fn ^event -> event end)

      Mox.expect(ApplicationMock, :update, fn %Event{
                                                type: :key,
                                                data: %{key: :enter}
                                              },
                                              model ->
        {%{model | count: model.count + 1},
         [%Command{type: :system, data: {:test_cmd, []}}]}
      end)

      {:ok, dispatcher} =
        Dispatcher.start_link(self(), initial_state,
          command_module: Raxol.Core.Runtime.TestCommandModule
        )

      Mox.allow(ApplicationMock, self(), dispatcher)

      # The call path -- backpressure helper escalates here when the
      # dispatcher mailbox is hot. The reply must be :ok and the
      # state must transition identically to the cast path.
      assert :ok = GenServer.call(dispatcher, {:dispatch, event})

      current_state = :sys.get_state(dispatcher)
      assert current_state.model.count == 1

      executed_commands =
        Raxol.Core.Runtime.TestCommandModule.get_executed_commands()

      assert length(executed_commands) == 1
      [{command, _context}] = executed_commands
      assert command.type == :system
      assert command.data == {:test_cmd, []}

      on_exit(fn ->
        Mox.verify!()

        try do
          GenServer.stop(mock_pm_pid)
        catch
          :exit, _ -> :ok
        end

        try do
          Raxol.Core.Runtime.TestCommandModule.stop()
        catch
          :exit, _ -> :ok
        end
      end)
    end

    test ~c"handle_cast :dispatch handles application update errors" do
      # Start Mock Plugin Manager for this test
      {:ok, mock_pm_pid} = Mock.PluginManager.start_link([])

      # Start Test Command Module for this test
      {:ok, _test_command_agent} =
        Raxol.Core.Runtime.TestCommandModule.start_link()

      # Define initial state for this test
      initial_state = %{
        app_module: ApplicationMock,
        model: %{count: 0},
        runtime_pid: self(),
        width: 80,
        height: 24,
        focused: true,
        debug_mode: false,
        plugin_manager: mock_pm_pid,
        command_registry_table: Raxol.Core.Runtime.TestCommandModule,
        pubsub_server: Phoenix.PubSub,
        rendering_engine: Raxol.Core.Runtime.Rendering.Engine,
        initial_commands: []
      }

      # Mox expectations
      Mox.expect(ApplicationMock, :init, fn _opts -> {:ok, %{count: 0}} end)

      event = %Event{
        type: :key,
        data: %{key: :enter, state: :pressed, modifiers: []}
      }

      # Expect handle_event to be called with correct signature
      Mox.expect(ApplicationMock, :handle_event, fn ^event ->
        {:key_press, :enter, []}
      end)

      # Expect update to fail with correct signature
      Mox.expect(ApplicationMock, :update, fn {:key_press, :enter, []},
                                              _model ->
        {:error, :simulated_error}
      end)

      # Use real PubSub - no mocking needed

      # Use real UserPreferences - no mocking needed

      # Start Dispatcher for this test with test command module
      {:ok, dispatcher} =
        Dispatcher.start_link(self(), initial_state,
          command_module: Raxol.Core.Runtime.TestCommandModule
        )

      # Allow the dispatcher process to use the ApplicationMock
      Mox.allow(ApplicationMock, self(), dispatcher)

      :ok = GenServer.cast(dispatcher, {:dispatch, event})

      # Assertions: No render needed, state unchanged
      refute_receive :render_needed, 100
      current_state_after_error = :sys.get_state(dispatcher)
      assert current_state_after_error.model.count == 0

      # Verify no commands were executed due to error
      executed_commands =
        Raxol.Core.Runtime.TestCommandModule.get_executed_commands()

      assert executed_commands == []

      # Test-specific teardown
      on_exit(fn ->
        Mox.verify!()
        # Stop processes gracefully, ignoring if already dead
        try do
          GenServer.stop(mock_pm_pid)
        catch
          :exit, _ -> :ok
        end

        try do
          Raxol.Core.Runtime.TestCommandModule.stop()
        catch
          :exit, _ -> :ok
        end
      end)
    end
  end
end
