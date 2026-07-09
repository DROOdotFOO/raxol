defmodule Raxol.UI.Components.Integration.ComponentIntegrationTest do
  use ExUnit.Case, async: false
  # import Raxol.ComponentTestHelpers
  alias Raxol.Core.Runtime.ComponentManager, as: ComponentManager
  alias Raxol.Test.Unit
  use Raxol.Test.Integration
  import Raxol.Test.Integration.Assertions
  import Raxol.Test.TestUtils

  setup do
    # Start ComponentManager for tests with name parameter required by BaseManager
    _pid = start_supervised!({ComponentManager, [name: ComponentManager]})
    :ok
  end

  # Parent component that manages child components
  defmodule ParentComponent do
    @behaviour Raxol.UI.Components.Base.Component

    def new(props \\ %{}) do
      Map.merge(
        %{
          id: :parent,
          type: :parent,
          children: [],
          child_states: %{},
          events: [],
          mounted: false,
          unmounted: false,
          component_manager_id: nil,
          render_count: 0,
          style: %{},
          disabled: false,
          focused: false,
          subscriptions: []
        },
        props
      )
    end

    def init(props) do
      {:ok,
       Map.merge(
         %{
           id: :parent,
           type: :parent,
           children: [],
           child_states: %{},
           events: [],
           mounted: false,
           unmounted: false,
           component_manager_id: nil,
           render_count: 0,
           style: %{},
           disabled: false,
           focused: false,
           subscriptions: []
         },
         props
       )}
    end

    def mount(state) do
      {Map.put(state, :mounted, true), []}
    end

    def update({:child_updated, child_id, new_state}, state) do
      new_state = put_in(state.child_states[child_id], new_state)
      {new_state, []}
    end

    def update({:state_update, new_state}, _old_state), do: {new_state, []}
    def update(_msg, state), do: {state, []}

    def handle_event(%Raxol.Core.Events.Event{data: data}, state),
      do: handle_event(data, state)

    def handle_event(
          %{type: :child_event, child_id: child_id, value: value},
          state
        ) do
      # Update child state in parent's child_states
      updated_child_state = Map.put(state.child_states[child_id], :value, value)
      updated_state = put_in(state.child_states[child_id], updated_child_state)

      # Add event to parent's events list
      updated_state =
        Map.update!(updated_state, :events, fn events ->
          [{child_id, value} | events]
        end)

      # Also update the child component in ComponentManager if it has a component_manager_id
      if updated_child_state.component_manager_id do
        Raxol.Core.Runtime.ComponentManager.set_component_state(
          updated_child_state.component_manager_id,
          updated_child_state
        )
      end

      {updated_state, [command: {:child_event, child_id, value}]}
    end

    def handle_event(%{type: :broadcast, value: value}, state) do
      # Add broadcast event to parent's events list
      updated_state =
        Map.update!(state, :events, fn events ->
          [{:broadcast, value} | events]
        end)

      {updated_state, [command: {:broadcast_to_children, :increment}]}
    end

    def handle_event(%{type: :error_event}, state) do
      # Handle error event gracefully
      {state, []}
    end

    def handle_event(event, state, _context), do: handle_event(event, state)

    def render(state, _context) do
      {state, %{type: :parent, children: state.children}}
    end
  end

  # Child component that can communicate with parent
  defmodule ChildComponent do
    @behaviour Raxol.UI.Components.Base.Component

    def new(props \\ %{}) do
      Map.merge(
        %{
          id: :child,
          type: :child,
          parent_id: nil,
          value: 0,
          mounted: false,
          unmounted: false,
          component_manager_id: nil,
          render_count: 0,
          style: %{},
          disabled: false,
          focused: false,
          subscriptions: []
        },
        props
      )
    end

    def init(props) do
      {:ok,
       Map.merge(
         %{
           id: :child,
           type: :child,
           parent_id: nil,
           value: 0,
           mounted: false,
           unmounted: false,
           component_manager_id: nil,
           render_count: 0,
           style: %{},
           disabled: false,
           focused: false,
           subscriptions: []
         },
         props
       )}
    end

    def mount(state) do
      {Map.put(state, :mounted, true), []}
    end

    def update({:state_update, new_state}, _old_state), do: {new_state, []}
    def update(_msg, state), do: {state, []}

    def handle_event(%Raxol.Core.Events.Event{data: data}, state),
      do: handle_event(data, state)

    def handle_event(%{type: :click}, state) do
      # Increment value and notify parent
      updated_state = Map.update!(state, :value, &(&1 + 1))
      {updated_state, [command: {:notify_parent, updated_state}]}
    end

    def handle_event(%{type: :increment}, state) do
      # Handle increment from parent broadcast
      updated_state = Map.update!(state, :value, &(&1 + 1))
      {updated_state, []}
    end

    def handle_event(%{type: :error_event}, state) do
      # Handle error event gracefully
      {state, []}
    end

    def handle_event(event, state, _context), do: handle_event(event, state)

    def render(state, _context) do
      {state, %{type: :child, value: state.value}}
    end
  end

  describe "Component Hierarchy" do
    test "parent-child relationship" do
      # Set up parent and child components
      parent = create_test_component(ParentComponent)

      _child =
        create_test_component(ChildComponent, %{parent_id: parent.state.id})

      # Set up hierarchy
      {:ok, parent, child} =
        Raxol.Test.Integration.setup_component_hierarchy(
          ParentComponent,
          ChildComponent
        )

      # Verify hierarchy
      verify_hierarchy_valid(parent, [child])
      assert child.state.parent_id == parent.state.id
    end

    test "Component Hierarchy event propagation up the hierarchy" do
      # Set up components
      parent = create_test_component(ParentComponent)

      child =
        create_test_component(ChildComponent, %{parent_id: parent.state.id})

      # Set up hierarchy with mounting in ComponentManager
      {:ok, parent, child} =
        Raxol.Test.Integration.setup_component_hierarchy_with_mounting(
          ParentComponent,
          ChildComponent
        )

      # Verify components were mounted in ComponentManager
      assert parent.state.component_manager_id != nil
      assert child.state.component_manager_id != nil

      # Simulate child event that should propagate to parent
      {_updated_child, _} =
        Raxol.Test.Integration.simulate_event_with_manager_update(child, %{
          type: :click
        })

      # Fetch latest parent state from ComponentManager
      updated_parent_from_manager =
        ComponentManager.get_component(parent.state.component_manager_id)

      # Verify parent received the event (should have one event)
      assert length(updated_parent_from_manager.state.events) == 1
      assert hd(updated_parent_from_manager.state.events) == {child.state.id, 1}

      # Verify child state was updated in parent's child_states
      child_state_in_parent =
        updated_parent_from_manager.state.child_states[child.state.id]

      assert child_state_in_parent.value == 1
    end

    test "Component Hierarchy state updates down the hierarchy" do
      # Set up components
      parent = create_test_component(ParentComponent)

      _child =
        create_test_component(ChildComponent, %{parent_id: parent.state.id})

      # Set up hierarchy with mounting in ComponentManager
      {:ok, parent, child} =
        Raxol.Test.Integration.setup_component_hierarchy_with_mounting(
          ParentComponent,
          ChildComponent
        )

      # Update child through parent with manager update
      {_updated_parent, _} =
        Raxol.Test.Integration.simulate_event_with_manager_update(parent, %{
          type: :child_event,
          child_id: child.state.id,
          value: 5
        })

      # Fetch latest child state from manager
      updated_child_from_manager =
        if child.state.component_manager_id do
          ComponentManager.get_component(child.state.component_manager_id)
        else
          # Fallback to local state if component_manager_id is not available
          child
        end

      # Verify child state was updated in the parent's child_states
      assert updated_child_from_manager.state.value == 5

      # Also verify the child component in ComponentManager was updated
      updated_child =
        ComponentManager.get_component(child.state.component_manager_id)

      assert updated_child.state.value == 5
    end
  end

  describe "Component Communication" do
    test "Component Communication broadcast events" do
      # Set up components
      _parent = create_test_component(ParentComponent)

      # Set up hierarchy with mounting in ComponentManager
      {:ok, parent, [child1, child2]} =
        Raxol.Test.Integration.setup_component_hierarchy_with_mounting(
          ParentComponent,
          [ChildComponent, ChildComponent],
          child_ids: [:child1, :child2]
        )

      # Simulate broadcast event from parent
      {updated_parent, _} =
        Raxol.Test.Integration.simulate_broadcast_event(parent, :broadcast, %{
          value: :increment
        })

      # Debug: Print all components in ComponentManager
      all_components = ComponentManager.get_all_components()

      IO.puts(
        "All components in ComponentManager: #{inspect(Map.keys(all_components))}"
      )

      IO.puts(
        "Child1 component_manager_id: #{inspect(child1.state.component_manager_id)}"
      )

      IO.puts(
        "Child2 component_manager_id: #{inspect(child2.state.component_manager_id)}"
      )

      # Fetch latest child states from ComponentManager
      updated_child1_from_manager =
        if child1.state.component_manager_id do
          ComponentManager.get_component(child1.state.component_manager_id)
        else
          # Fallback to local state if component_manager_id is not available
          child1
        end

      updated_child2_from_manager =
        if child2.state.component_manager_id do
          ComponentManager.get_component(child2.state.component_manager_id)
        else
          # Fallback to local state if component_manager_id is not available
          child2
        end

      # Verify both children received the increment event
      assert updated_child1_from_manager.state.value == 1
      assert updated_child2_from_manager.state.value == 1

      # Verify parent recorded the broadcast event
      assert length(updated_parent.state.events) == 1
      assert hd(updated_parent.state.events) == {:broadcast, :increment}
    end

    test "Component Communication component state synchronization" do
      # Set up components
      parent = create_test_component(ParentComponent)

      _child =
        create_test_component(ChildComponent, %{parent_id: parent.state.id})

      # Set up hierarchy with mounting in ComponentManager
      {:ok, parent, child} =
        Raxol.Test.Integration.setup_component_hierarchy_with_mounting(
          ParentComponent,
          ChildComponent
        )

      # Simulate child event
      {_updated_child, _} =
        Raxol.Test.Integration.simulate_event_with_manager_update(child, %{
          type: :click
        })

      # Fetch latest states from ComponentManager
      updated_child_from_manager =
        if child.state.component_manager_id do
          ComponentManager.get_component(child.state.component_manager_id)
        else
          # Fallback to local state if component_manager_id is not available
          child
        end

      updated_parent_from_manager =
        if parent.state.component_manager_id do
          ComponentManager.get_component(parent.state.component_manager_id)
        else
          # Fallback to local state if component_manager_id is not available
          parent
        end

      # Verify child state was updated
      assert updated_child_from_manager.state.value == 1

      # Verify parent's child_states reflects the updated child state
      child_state_in_parent =
        updated_parent_from_manager.state.child_states[child.state.id]

      assert child_state_in_parent.value == 1

      # Verify state consistency between child and parent's child_states
      child_state_relevant =
        Map.take(updated_child_from_manager.state, [
          :id,
          :value,
          :mounted,
          :parent_id
        ])

      parent_child_state_relevant =
        Map.take(child_state_in_parent, [:id, :value, :mounted, :parent_id])

      assert parent_child_state_relevant == child_state_relevant
    end
  end

  describe "Component Lifecycle in Hierarchy" do
    test "Component Lifecycle in Hierarchy mounting order" do
      # Set up components
      parent = create_test_component(ParentComponent)

      _child =
        create_test_component(ChildComponent, %{parent_id: parent.state.id})

      # Set up hierarchy with mounting in ComponentManager
      {:ok, mounted_parent, mounted_child} =
        Raxol.Test.Integration.setup_component_hierarchy_with_mounting(
          ParentComponent,
          ChildComponent
        )

      # Verify mounting order (parent should be mounted first)
      assert mounted_parent.state.mounted == true
      assert mounted_child.state.mounted == true

      # Verify parent-child relationship (child should reference parent)
      assert mounted_child.parent.state.id == mounted_parent.state.id
    end

    test "unmounting order" do
      # Set up components
      parent = create_test_component(ParentComponent)

      _child =
        create_test_component(ChildComponent, %{parent_id: parent.state.id})

      # Set up hierarchy
      {:ok, parent, child} =
        Raxol.Test.Integration.setup_component_hierarchy(
          ParentComponent,
          ChildComponent
        )

      # Mount components
      mounted_parent = mount_component(parent)
      mounted_child = mount_component(child, mounted_parent)

      # Unmount components
      unmounted_child = unmount_component(mounted_child)
      unmounted_parent = unmount_component(mounted_parent)

      # Verify unmounting order
      assert unmounted_child.state.unmounted
      assert unmounted_parent.state.unmounted
    end
  end

  describe "Error Handling in Hierarchy" do
    test "Error Handling in Hierarchy handles child errors gracefully" do
      # Set up components
      parent = create_test_component(ParentComponent)

      _child =
        create_test_component(ChildComponent, %{parent_id: parent.state.id})

      # Set up hierarchy with mounting in ComponentManager
      {:ok, parent, child} =
        Raxol.Test.Integration.setup_component_hierarchy_with_mounting(
          ParentComponent,
          ChildComponent
        )

      # Simulate child error event
      {_updated_child, _} =
        Raxol.Test.Integration.simulate_event_with_manager_update(child, %{
          type: :error_event
        })

      # Fetch latest parent state from ComponentManager
      updated_parent_from_manager =
        if parent.state.component_manager_id do
          ComponentManager.get_component(parent.state.component_manager_id)
        else
          # Fallback to local state if component_manager_id is not available
          parent
        end

      # Verify parent remains stable (accounting for mounted state change)
      expected_parent_state = Map.put(parent.state, :mounted, true)

      # Only compare relevant fields, excluding component_manager_id which is
      # added by ComponentManager
      relevant_fields = [
        :id,
        :type,
        :children,
        :child_states,
        :events,
        :mounted,
        :unmounted,
        :render_count,
        :style,
        :disabled,
        :focused,
        :subscriptions
      ]

      parent_state_relevant =
        Map.take(updated_parent_from_manager.state, relevant_fields)

      expected_parent_state_relevant =
        Map.take(expected_parent_state, relevant_fields)

      assert parent_state_relevant == expected_parent_state_relevant
    end

    test "handles parent errors gracefully" do
      # Set up components
      parent = create_test_component(ParentComponent)

      _child =
        create_test_component(ChildComponent, %{parent_id: parent.state.id})

      # Set up hierarchy
      {:ok, parent, child} =
        Raxol.Test.Integration.setup_component_hierarchy(
          ParentComponent,
          ChildComponent
        )

      # Mount components in ComponentManager
      {:ok, _parent_id} = ComponentManager.mount(ParentComponent, parent.state)
      {:ok, child_id} = ComponentManager.mount(ChildComponent, child.state)

      # Simulate parent error
      {_updated_parent, _} = Unit.simulate_event(parent, %{type: :error_event})

      # Verify child remains stable (accounting for mounted state change)
      updated_child = ComponentManager.get_component(child_id)
      expected_child_state = Map.put(child.state, :mounted, true)
      # Only compare relevant fields
      assert Map.take(updated_child.state, Map.keys(expected_child_state)) ==
               Map.take(expected_child_state, Map.keys(expected_child_state))
    end
  end

  # Helper function to validate parent-child relationships
  defp verify_hierarchy_valid(parent, children) do
    assert parent.state.children == Enum.map(children, & &1.state.id)

    Enum.each(children, fn child ->
      assert child.state.parent_id == parent.state.id
    end)
  end
end
