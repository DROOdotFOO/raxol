defmodule Raxol.Core.Runtime.ComponentManagerTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Events.EventManager
  alias Raxol.Core.Runtime.ComponentManager

  alias Raxol.Test.ComponentManagerTestMocks.Raxol.Core.Runtime.ComponentManagerTest.TestComponent

  setup do
    # Start ComponentManager with clean state
    start_supervised!({ComponentManager, [name: ComponentManager]})

    # Set runtime_pid to self() so we can receive component_updated messages
    ComponentManager.set_runtime_pid(self())

    :ok
  end

  describe "component lifecycle" do
    test ~c"mount registers a component" do
      {:ok, component_id} = ComponentManager.mount(TestComponent)

      # Verify component was registered
      component_data = ComponentManager.get_component(component_id)
      assert component_data.module == TestComponent
      assert component_data.state.counter == 0

      # Verify it was added to render queue
      render_queue = ComponentManager.get_render_queue()
      assert component_id in render_queue
    end

    test ~c"mount with props" do
      props = %{initial_value: 100}
      {:ok, component_id} = ComponentManager.mount(TestComponent, props)

      component_data = ComponentManager.get_component(component_id)
      assert component_data.props == props
      assert component_data.state.initial_value == 100
    end

    test ~c"unmount removes a component" do
      {:ok, component_id} = ComponentManager.mount(TestComponent)

      # Verify component was registered
      assert ComponentManager.get_component(component_id) != nil

      # Unmount component
      {:ok, _final_state} = ComponentManager.unmount(component_id)

      # Verify component was removed
      assert ComponentManager.get_component(component_id) == nil
    end

    test ~c"unmount returns error for unknown component" do
      assert {:error, :not_found} =
               ComponentManager.unmount("unknown_component")
    end

    test ~c"unmount cleans up component resources" do
      # Mount component with subscriptions
      {:ok, component_id} = ComponentManager.mount(TestComponent)

      # Add a subscription
      {:ok, _} = ComponentManager.update(component_id, :add_subscription)

      # Verify subscription was added
      component_data = ComponentManager.get_component(component_id)
      assert component_data.state.subscriptions != nil

      # Unmount component
      {:ok, _final_state} = ComponentManager.unmount(component_id)

      # Verify component and its resources were cleaned up
      assert ComponentManager.get_component(component_id) == nil
      # Verify no orphaned subscriptions remain
      assert ComponentManager.get_render_queue() == []
    end

    test ~c"mount handles invalid component module" do
      assert {:error, :invalid_component} = ComponentManager.mount(nil)

      assert {:error, :invalid_component} =
               ComponentManager.mount("not_a_module")
    end

    test ~c"mount handles component init failure" do
      defmodule BadComponent do
        def init(_props), do: {:error, :init_failed}
      end

      assert {:error, :init_failed} = ComponentManager.mount(BadComponent)
    end
  end

  describe "component updates" do
    test ~c"update modifies component state" do
      {:ok, component_id} = ComponentManager.mount(TestComponent)

      # Get initial state
      initial_data = ComponentManager.get_component(component_id)
      assert initial_data.state.counter == 0

      # Update component
      {:ok, updated_state} = ComponentManager.update(component_id, :increment)
      assert updated_state.counter == 1

      # Verify state was updated in manager
      updated_data = ComponentManager.get_component(component_id)
      assert updated_data.state.counter == 1
    end

    test ~c"update queues component for render" do
      {:ok, component_id} = ComponentManager.mount(TestComponent)

      # Clear render queue
      ComponentManager.get_render_queue()

      # Update component
      {:ok, _} = ComponentManager.update(component_id, :increment)

      # Verify component is in render queue
      render_queue = ComponentManager.get_render_queue()
      assert component_id in render_queue
    end

    test ~c"update returns error for unknown component" do
      assert {:error, :not_found} =
               ComponentManager.update("unknown_component", :increment)
    end

    test ~c"update handles component errors gracefully" do
      defmodule ErrorComponent do
        def init(_props), do: {:ok, %{error_count: 0}}
        def mount(state), do: {state, []}
        def update(:trigger_error, _state), do: raise("Test error")
        def update(_msg, state), do: {state, []}
      end

      {:ok, component_id} = ComponentManager.mount(ErrorComponent)

      # Attempt to trigger an error
      assert {:error, :component_error} =
               ComponentManager.update(component_id, :trigger_error)

      # Verify component remains in a valid state
      component_data = ComponentManager.get_component(component_id)
      assert component_data != nil
      assert component_data.state.error_count == 0
    end

    test ~c"update handles invalid return values" do
      defmodule InvalidReturnComponent do
        def init(_props), do: {:ok, %{}}
        def mount(state), do: {state, []}
        def update(_msg, _state), do: :invalid_return
      end

      {:ok, component_id} = ComponentManager.mount(InvalidReturnComponent)

      # Attempt update with invalid return
      assert {:error, :invalid_component_return} =
               ComponentManager.update(component_id, :any_message)

      # Verify component remains in a valid state
      component_data = ComponentManager.get_component(component_id)
      assert component_data != nil
    end
  end

  describe "event dispatch" do
    test ~c"dispatch_event sends events to components" do
      {:ok, component_id} = ComponentManager.mount(TestComponent)

      # Dispatch event
      ComponentManager.dispatch_event({:test_event, "test_value"})

      # Wait for event processing
      assert_receive {:component_updated, ^component_id}, 100

      # Verify component state was updated
      component_data = ComponentManager.get_component(component_id)
      assert component_data.state.event_value == "test_value"

      # Verify it was queued for render
      render_queue = ComponentManager.get_render_queue()
      assert component_id in render_queue
    end
  end

  describe "render queue management" do
    test ~c"get_render_queue returns and clears the queue" do
      # Mount multiple components
      {:ok, component_id1} = ComponentManager.mount(TestComponent)
      {:ok, component_id2} = ComponentManager.mount(TestComponent)

      # Update components to add to render queue
      ComponentManager.update(component_id1, :increment)
      ComponentManager.update(component_id2, :increment)

      # Get render queue
      render_queue = ComponentManager.get_render_queue()

      # Verify both components are in the queue
      assert Enum.sort([component_id1, component_id2]) ==
               Enum.sort(render_queue)

      # Verify queue was cleared
      assert ComponentManager.get_render_queue() == []
    end
  end

  describe "command processing" do
    test ~c"handles component commands (e.g., scheduled messages)" do
      # Use standard mount
      {:ok, component_id} = ComponentManager.mount(TestComponent)

      # Manually schedule the message that mount_with_commands would have
      timer_id = System.unique_integer([:positive])

      Process.send_after(
        ComponentManager,
        {:update, component_id, :delayed_message, timer_id},
        50
      )

      # Wait for delayed message to be processed
      # Increased timeout to account for CI timing variability (macOS in particular)
      assert_receive {:component_updated, ^component_id}, 500

      # Verify the component received the delayed message via update
      final_component_data = ComponentManager.get_component(component_id)
      assert final_component_data.state.last_message == :delayed_message
    end

    test ~c"handles broadcast commands" do
      # Mount multiple components
      {:ok, component_id1} = ComponentManager.mount(TestComponent)
      {:ok, component_id2} = ComponentManager.mount(TestComponent)

      # Update component 1 to trigger the broadcast command
      {:ok, _} = ComponentManager.update(component_id1, :trigger_broadcast)

      # Wait for broadcasting to complete
      assert_receive {:component_updated, ^component_id2}, 500

      # Verify both components received the broadcast via update
      component1 = ComponentManager.get_component(component_id1)
      component2 = ComponentManager.get_component(component_id2)

      # Component 1's last message should be the trigger, not the broadcast
      assert component1.state.last_message == :trigger_broadcast
      assert component2.state.last_message == :broadcast_message
    end
  end

  # Reports every {:event, type, data} it receives to the test process, and
  # returns {:subscribe, types} / {:unsubscribe, types} messages (and
  # {:subscribe_to, types} events) as the matching component commands.
  defmodule EventProbe do
    def init(props), do: props

    def mount(%{subscribe_on_mount: types} = state),
      do: {state, [{:command, {:subscribe, types}}]}

    def mount(state), do: {state, []}

    def unmount(state), do: state

    def update({:event, _type, _data} = event, state) do
      send(state.test_pid, {:component_event, state.name, event})
      {state, []}
    end

    def update({op, types}, state) when op in [:subscribe, :unsubscribe],
      do: {state, [{:command, {op, types}}]}

    def update(_message, state), do: {state, []}

    def handle_event({:subscribe_to, types}, state, _context),
      do: {state, [{:command, {:subscribe, types}}]}

    def handle_event(_event, state, _context), do: {state, []}
  end

  describe "event subscriptions" do
    setup do
      # Supervised by the application; a sync test elsewhere may have stopped it.
      if is_nil(Process.whereis(EventManager)),
        do: start_supervised!(EventManager)

      %{type: :"component_sub_test_#{System.unique_integer([:positive])}"}
    end

    test "a subscribed component receives EventManager events as {:event, type, data}",
         %{type: type} do
      a = mount_probe(:a)
      assert {:ok, _} = ComponentManager.update(a, {:subscribe, [type]})

      :ok = EventManager.dispatch(type, %{n: 1})
      settle()
      assert_received {:component_event, :a, {:event, ^type, %{n: 1}}}

      :ok = EventManager.notify(type, %{n: 2})
      settle()
      assert_received {:component_event, :a, {:event, ^type, %{n: 2}}}
    end

    test "a subscription made in mount/1 delivers events", %{type: type} do
      mount_probe(:a, %{subscribe_on_mount: [type]})

      :ok = EventManager.dispatch(type, %{n: 1})
      settle()
      assert_received {:component_event, :a, {:event, ^type, %{n: 1}}}
    end

    test "a subscription made in handle_event/3 delivers events until unmount",
         %{type: type} do
      a = mount_probe(:a)
      ComponentManager.dispatch_event({:subscribe_to, [type]})
      # The cast has subscribed once the manager answers a later call.
      _ = :sys.get_state(ComponentManager)

      :ok = EventManager.dispatch(type, %{n: 1})
      settle()
      assert_received {:component_event, :a, {:event, ^type, %{n: 1}}}

      assert {:ok, _} = ComponentManager.unmount(a)
      assert event_manager_sends(type) == 0
    end

    test "components with overlapping subscriptions each receive an event once",
         %{type: type} do
      other = :"#{type}_other"
      a = mount_probe(:a)
      b = mount_probe(:b)
      assert {:ok, _} = ComponentManager.update(a, {:subscribe, [type, other]})
      assert {:ok, _} = ComponentManager.update(b, {:subscribe, [type]})

      # One EventManager subscription per type, however many components list it.
      assert event_manager_sends(type) == 1
      settle()
      assert_received {:component_event, :a, {:event, ^type, _}}
      assert_received {:component_event, :b, {:event, ^type, _}}
      refute_received {:component_event, _, {:event, ^type, _}}

      :ok = EventManager.dispatch(other, %{n: 1})
      settle()
      assert_received {:component_event, :a, {:event, ^other, %{n: 1}}}
      refute_received {:component_event, _, {:event, ^other, _}}
    end

    test "a component that subscribes to a type twice receives each event once",
         %{type: type} do
      a = mount_probe(:a)
      assert {:ok, _} = ComponentManager.update(a, {:subscribe, [type]})
      assert {:ok, _} = ComponentManager.update(a, {:subscribe, [type, type]})

      assert event_manager_sends(type) == 1
      settle()
      assert_received {:component_event, :a, {:event, ^type, _}}
      refute_received {:component_event, :a, {:event, ^type, _}}
    end

    test "unsubscribing by type stops delivery, and the last one out releases the type",
         %{type: type} do
      a = mount_probe(:a)
      b = mount_probe(:b)
      assert {:ok, _} = ComponentManager.update(a, {:subscribe, [type]})
      assert {:ok, _} = ComponentManager.update(b, {:subscribe, [type]})

      assert {:ok, _} = ComponentManager.update(a, {:unsubscribe, [type]})
      :ok = EventManager.dispatch(type, %{n: 1})
      settle()
      assert_received {:component_event, :b, {:event, ^type, %{n: 1}}}
      refute_received {:component_event, :a, {:event, ^type, _}}

      assert {:ok, _} = ComponentManager.update(b, {:unsubscribe, [type]})
      assert event_manager_sends(type) == 0
      settle()
      refute_received {:component_event, _, {:event, ^type, _}}
    end

    test "unmounting a component stops delivery to it and releases its types",
         %{type: type} do
      a = mount_probe(:a)
      b = mount_probe(:b)
      assert {:ok, _} = ComponentManager.update(a, {:subscribe, [type]})
      assert {:ok, _} = ComponentManager.update(b, {:subscribe, [type]})

      assert {:ok, _} = ComponentManager.unmount(a)
      :ok = EventManager.dispatch(type, %{n: 1})
      settle()
      assert_received {:component_event, :b, {:event, ^type, %{n: 1}}}
      refute_received {:component_event, :a, {:event, ^type, _}}

      assert {:ok, _} = ComponentManager.unmount(b)
      assert event_manager_sends(type) == 0
    end

    test "an {:event, type, data} message for a type no component lists is not delivered",
         %{type: type} do
      a = mount_probe(:a)
      assert {:ok, _} = ComponentManager.update(a, {:subscribe, [type]})

      forged = :"#{type}_forged"
      send(Process.whereis(ComponentManager), {:event, forged, %{forged: true}})
      settle()
      refute_received {:component_event, _, {:event, ^forged, _}}

      # The manager is still serving its subscribers.
      :ok = EventManager.dispatch(type, %{n: 1})
      settle()
      assert_received {:component_event, :a, {:event, ^type, %{n: 1}}}
    end

    test "subscribing while EventManager is down leaves the manager serving and the component unsubscribed",
         %{type: type} do
      manager = Process.whereis(ComponentManager)
      a = mount_probe(:a)
      stop_event_manager()

      assert {:ok, _} = ComponentManager.update(a, {:subscribe, [type]})
      assert Process.whereis(ComponentManager) == manager
      assert {:ok, _} = ComponentManager.update(a, :ping)

      # Nothing was recorded for the failed subscription, so subscribing again
      # once EventManager is back starts a real one.
      start_supervised!(EventManager)
      assert {:ok, _} = ComponentManager.update(a, {:subscribe, [type]})
      :ok = EventManager.dispatch(type, %{n: 1})
      settle()
      assert_received {:component_event, :a, {:event, ^type, %{n: 1}}}
    end

    test "unsubscribing and unmounting while EventManager is down leave the manager serving",
         %{type: type} do
      manager = Process.whereis(ComponentManager)
      a = mount_probe(:a)
      b = mount_probe(:b)
      assert {:ok, _} = ComponentManager.update(a, {:subscribe, [type]})
      assert {:ok, _} = ComponentManager.update(b, {:subscribe, [type]})
      stop_event_manager()

      assert {:ok, _} = ComponentManager.update(a, {:unsubscribe, [type]})
      assert {:ok, _} = ComponentManager.unmount(b)
      assert Process.whereis(ComponentManager) == manager
      assert {:ok, _} = ComponentManager.update(a, :ping)
    end
  end

  defp mount_probe(name, props \\ %{}) do
    {:ok, id} =
      ComponentManager.mount(
        EventProbe,
        Map.merge(%{test_pid: self(), name: name}, props)
      )

    id
  end

  # EventManager.dispatch/2 and notify/3 cast. Once EventManager answers a
  # later call it has sent the event to every subscriber, and once
  # ComponentManager answers one it has handled that message, so every
  # component the event reached has reported it to the test process.
  defp settle do
    _ = EventManager.get_handlers()
    _ = :sys.get_state(ComponentManager)
    :ok
  end

  # Dispatches an event of `type` and counts the copies EventManager sends to
  # ComponentManager: one per EventManager subscription listing the type.
  defp event_manager_sends(type) do
    manager = Process.whereis(ComponentManager)
    :ok = :sys.suspend(manager)
    :ok = EventManager.dispatch(type, %{counted: true})
    _ = EventManager.get_handlers()
    {:messages, messages} = Process.info(manager, :messages)
    :ok = :sys.resume(manager)
    Enum.count(messages, &match?({:event, ^type, _}, &1))
  end

  defp stop_event_manager do
    _ = stop_supervised(EventManager)
    :ok = EventManager.cleanup()
    assert is_nil(Process.whereis(EventManager))
  end
end
