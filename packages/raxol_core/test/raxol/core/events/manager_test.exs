defmodule Raxol.Core.Events.EventManagerTest do
  @moduledoc """
  Tests for the event manager, including initialization, handler registration,
  and event dispatching.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.Events.EventManager, as: EventManager

  setup do
    # Start the EventManager GenServer for tests
    pid =
      case EventManager.start_link(name: EventManager) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, pid}} ->
          # If already started, stop and restart to ensure clean state
          GenServer.stop(pid)
          {:ok, new_pid} = EventManager.start_link(name: EventManager)
          new_pid
      end

    # Clean up after tests
    on_exit(fn ->
      # Server may be mid-shutdown at teardown; swallow the stop's :exit.
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, manager: pid}
  end

  describe "init/0" do
    test "initializes event handlers registry" do
      # Re-init to ensure we have a clean state
      EventManager.init()

      # Verify handlers registry is empty
      assert EventManager.get_handlers() == %{}
    end
  end

  describe "register_handler/3" do
    test "registers a handler for an event type" do
      # Register a handler
      assert :ok =
               EventManager.register_handler(
                 :test_event,
                 __MODULE__,
                 :dummy_handler
               )

      # Verify handler was registered
      handlers = EventManager.get_handlers()
      assert Map.has_key?(handlers, :test_event)
      assert handlers[:test_event] == [{__MODULE__, :dummy_handler, 50}]
    end

    test "can register multiple handlers for same event type" do
      # Register first handler
      EventManager.register_handler(:test_event, __MODULE__, :dummy_handler)

      # Register second handler
      EventManager.register_handler(:test_event, __MODULE__, :another_handler)

      # Verify both handlers were registered
      handlers = EventManager.get_handlers()
      assert Map.has_key?(handlers, :test_event)

      event_handlers = Map.get(handlers, :test_event)
      assert length(event_handlers) == 2
      assert Enum.member?(event_handlers, {__MODULE__, :dummy_handler, 50})
      assert Enum.member?(event_handlers, {__MODULE__, :another_handler, 50})
    end

    test "doesn't register the same handler twice" do
      # Register same handler twice
      EventManager.register_handler(:test_event, __MODULE__, :dummy_handler)
      EventManager.register_handler(:test_event, __MODULE__, :dummy_handler)

      # Verify handler was registered only once
      handlers = EventManager.get_handlers()
      assert Map.has_key?(handlers, :test_event)

      assert Map.get(handlers, :test_event) == [
               {__MODULE__, :dummy_handler, 50}
             ]
    end
  end

  describe "unregister_handler/3" do
    test "unregisters a handler" do
      # Register a handler
      EventManager.register_handler(:test_event, __MODULE__, :dummy_handler)

      # Unregister the handler
      assert :ok =
               EventManager.unregister_handler(
                 :test_event,
                 __MODULE__,
                 :dummy_handler
               )

      # Verify handler was unregistered
      handlers = EventManager.get_handlers()

      # When all handlers are removed, the key may be removed entirely or set to empty list
      event_handlers = Map.get(handlers, :test_event, [])
      assert event_handlers == []
    end

    test "only unregisters the specified handler" do
      # Register two handlers
      EventManager.register_handler(:test_event, __MODULE__, :dummy_handler)
      EventManager.register_handler(:test_event, __MODULE__, :another_handler)

      # Unregister one handler
      EventManager.unregister_handler(:test_event, __MODULE__, :dummy_handler)

      # Verify only that handler was unregistered
      handlers = EventManager.get_handlers()
      assert Map.has_key?(handlers, :test_event)

      assert Map.get(handlers, :test_event) == [
               {__MODULE__, :another_handler, 50}
             ]
    end

    test "does nothing for unregistered handler" do
      # Unregister a non-existent handler
      assert :ok =
               EventManager.unregister_handler(
                 :test_event,
                 __MODULE__,
                 :nonexistent_handler
               )
    end
  end

  describe "dispatch/1" do
    test "dispatches event to registered handlers" do
      parent = self()
      receiver_name = :"test_receiver_#{System.unique_integer([:positive])}"

      test_pid =
        spawn(fn ->
          receive do
            msg -> send(parent, msg)
          end
        end)

      # Define handler module -- arity 2 because EventManager dispatches (event_type, event_data)
      defmodule DispatchTestHandler do
        def handle_test_event(event_type, event_data) do
          send(
            Process.whereis(:dispatch_test_receiver),
            {event_type, event_data}
          )
        end
      end

      Process.register(test_pid, :dispatch_test_receiver)

      EventManager.register_handler(
        :test_event,
        DispatchTestHandler,
        :handle_test_event
      )

      event = {:test_event, %{data: "test"}}
      EventManager.dispatch(event)

      assert_receive ^event, 100
    end

    test "dispatches atom events" do
      # Create a temporary process that will receive messages
      parent = self()

      test_pid =
        spawn(fn ->
          receive do
            msg -> send(parent, msg)
          end
        end)

      # Define test module with handler
      defmodule AtomEventHandler do
        def handle_atom_event(event) do
          send(Process.whereis(:test_receiver_172), event)
        end
      end

      # Register test process
      Process.register(test_pid, :test_receiver_172)

      # Register handler
      EventManager.register_handler(
        :atom_event,
        AtomEventHandler,
        :handle_atom_event
      )

      # Dispatch event
      event = :atom_event
      EventManager.dispatch(event)

      # Wait for message
      assert_receive ^event, 100
    end

    test "does nothing when no handlers are registered" do
      # Dispatch event with no handlers
      assert :ok = EventManager.dispatch({:unhandled_event, %{data: "test"}})
    end
  end

  describe "clear_handlers/0" do
    test "clears all handlers" do
      # Register some handlers
      EventManager.register_handler(:test_event, __MODULE__, :dummy_handler)

      EventManager.register_handler(
        :another_event,
        __MODULE__,
        :another_handler
      )

      # Verify handlers are registered
      handlers = EventManager.get_handlers()
      assert map_size(handlers) == 2

      # Clear handlers
      assert :ok = EventManager.clear_handlers()

      # Verify all handlers are cleared
      assert EventManager.get_handlers() == %{}
    end
  end

  # Dummy handler functions used in tests
  def dummy_handler(_), do: :ok
  def another_handler(_), do: :ok
end
