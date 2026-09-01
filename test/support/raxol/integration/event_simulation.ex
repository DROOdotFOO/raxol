defmodule Raxol.Test.Integration.EventSimulation do
  @moduledoc """
  Handles event simulation for integration testing.

  This module provides functions for:
  - Simulating user actions (clicks, typing, key presses)
  - Processing events with commands
  - Broadcasting events between components
  - Managing event propagation in component hierarchies
  """

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.ComponentManager
  import ExUnit.Assertions

  @doc """
  Simulates a user action on a component.

  Handles various types of user interactions and ensures proper event propagation.
  """
  def simulate_user_action(component, action) do
    event = action_to_event(action)
    dispatch_simulated_event(component, event)
  end

  defp action_to_event({:click, pos}), do: Event.mouse(:left, pos)

  defp action_to_event({:type, text}),
    do: text |> String.to_charlist() |> Enum.map(&Event.key({:char, &1}))

  defp action_to_event({:key, key}), do: Event.key(key)
  defp action_to_event({:resize, {w, h}}), do: Event.window(w, h, :resize)

  defp action_to_event(action),
    do: raise("Unsupported action: #{inspect(action)}")

  defp dispatch_simulated_event(component, events) when is_list(events) do
    Enum.each(events, &process_event_with_commands(component, &1))
  end

  defp dispatch_simulated_event(component, event) do
    process_event_with_commands(component, event)
  end

  @doc """
  Simulates an event on a component and updates the ComponentManager state.

  This is the integration-style version that ensures state changes are reflected
  in the ComponentManager, not just the local struct.
  """
  def simulate_event_with_manager_update(component, event) do
    # First, simulate the event locally to get the new state
    {updated_component, commands} =
      Raxol.Test.Unit.simulate_event(component, event)

    # Update manager if component has component_manager_id
    do_manager_update(updated_component, commands)
  end

  defp do_manager_update(
         %{state: %{component_manager_id: component_id}} = updated_component,
         commands
       ) do
    # Update the component in ComponentManager with the new state using set_component_state
    case ComponentManager.set_component_state(
           component_id,
           updated_component.state
         ) do
      :ok ->
        # Process commands for parent notification
        Enum.each(commands, &process_command(&1, updated_component))
        {updated_component, commands}

      {:error, reason} ->
        # Log error but continue with local update
        IO.puts(
          "Warning: Failed to update component in manager: #{inspect(reason)}"
        )

        {updated_component, commands}
    end
  end

  defp do_manager_update(updated_component, commands) do
    # No component_manager_id, just return local update
    {updated_component, commands}
  end

  defp process_command(
         {:command, {:notify_parent, updated_child_state}},
         _updated_component
       ) do
    parent_id = updated_child_state.parent_id
    child_id = updated_child_state.id
    value = updated_child_state.value

    # Find parent in ComponentManager
    parent_component = find_parent_component(parent_id)
    handle_parent_notification(parent_component, child_id, value)
  end

  defp process_command(_, _), do: :ok

  defp find_parent_component(nil), do: nil

  defp find_parent_component(parent_id) do
    ComponentManager.get_all_components()
    |> Enum.find_value(fn
      {_id, %{state: %{id: ^parent_id}} = comp} -> comp
      _ -> nil
    end)
  end

  defp handle_parent_notification(nil, _child_id, _value), do: :ok

  defp handle_parent_notification(parent_component, child_id, value) do
    # Simulate :child_event on parent
    {updated_parent, _parent_cmds} =
      Raxol.Test.Unit.simulate_event(parent_component, %{
        type: :child_event,
        child_id: child_id,
        value: value
      })

    # Update parent in ComponentManager if it has a component_manager_id
    update_parent_in_manager(updated_parent)
  end

  defp update_parent_in_manager(%{state: %{component_manager_id: id} = state}) do
    ComponentManager.set_component_state(id, state)
  end

  defp update_parent_in_manager(_), do: :ok

  @doc """
  Simulates a broadcast event from parent to children.

  This handles the case where a parent component needs to send events to all its children.
  """
  def simulate_broadcast_event(parent, event_type, event_data \\ %{}) do
    # First, simulate the event on the parent
    event = Map.merge(%{type: event_type}, event_data)

    {updated_parent, commands} =
      simulate_event_with_manager_update(parent, event)

    # Process broadcast commands
    Enum.each(commands, &process_broadcast_command(&1, updated_parent))

    {updated_parent, commands}
  end

  defp process_broadcast_command(
         {:command, {:broadcast_to_children, :increment}},
         updated_parent
       ) do
    # Broadcast increment to all children
    Enum.each(updated_parent.state.children, fn child_id ->
      # Find the child component by searching through all components in ComponentManager
      # This is a test helper approach since we don't have get_component_by_id
      child_component = find_child_component_by_id_in_manager(child_id)

      simulate_child_increment(child_component)
    end)
  end

  defp process_broadcast_command(_, _), do: :ok

  defp simulate_child_increment(nil), do: :ok

  defp simulate_child_increment(child_component) do
    # Simulate the increment event on the child
    increment_event = %{type: :increment}

    {_updated_child, _child_commands} =
      simulate_event_with_manager_update(child_component, increment_event)
  end

  @doc """
  Verifies that a component properly handles a system event.
  """
  def assert_handles_system_event(component, event) do
    # Capture initial state
    initial_state = component.state

    # Dispatch event
    {updated_component, commands} = dispatch_event(component, event)

    # Verify component remained stable
    assert updated_component.state != nil,
           "Component state was corrupted after system event"

    # Return result for additional assertions
    {updated_component, initial_state, commands}
  end

  # Private helper functions

  defp process_event_with_commands(component, event) do
    {updated_component, commands} = dispatch_event(component, event)

    # Process commands
    Enum.each(commands, &process_dispatch_command(&1, component))

    updated_component
  end

  defp process_dispatch_command({:dispatch_to_parent, parent_event}, component) do
    # Find parent component and dispatch event to it
    handle_parent_dispatch(component, parent_event)
  end

  defp process_dispatch_command(command, _component) do
    # Command types this helper does not simulate.
    IO.puts("Unhandled command: #{inspect(command)}")
  end

  defp handle_parent_dispatch(%{parent_id: parent_id}, parent_event) do
    # Parent references do not exist in this helper, so the dispatch is only
    # reported. Reaching a real parent would require the test context.
    IO.puts("Would dispatch #{inspect(parent_event)} to parent #{parent_id}")
  end

  defp handle_parent_dispatch(_component, _parent_event), do: :ok

  defp dispatch_event(component, event, routing_info \\ %{}) do
    do_dispatch_event(
      function_exported?(component.module, :handle_event, 3),
      component,
      event,
      routing_info
    )
  end

  defp do_dispatch_event(false, component, _event, _routing_info),
    do: {component, []}

  defp do_dispatch_event(true, component, event, routing_info) do
    context =
      %{
        parent: Map.get(routing_info, :parent),
        child: Map.get(routing_info, :child)
      }
      |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
      |> Enum.into(%{})

    result = component.module.handle_event(event, component.state, context)
    handle_event_result(result, component)
  end

  defp handle_event_result({:update, new_state, commands}, component) do
    {put_in(component.state, new_state), commands}
  end

  defp handle_event_result({:handled, new_state}, component) do
    {put_in(component.state, new_state), []}
  end

  defp handle_event_result(:passthrough, component) do
    {component, []}
  end

  defp handle_event_result({new_state, commands}, component) do
    # Legacy format for backward compatibility
    {put_in(component.state, new_state), commands}
  end

  defp handle_event_result(_, component) do
    # Unknown return format, assume no change
    {component, []}
  end

  # Helper function to find a child component by ID in ComponentManager
  defp find_child_component_by_id_in_manager(child_id) do
    # Linear scan of every component in ComponentManager. A test helper:
    # production code resolves children through a real lookup, not a scan.
    ComponentManager.get_all_components()
    |> Enum.find_value(fn
      {_manager_id, %{state: %{id: ^child_id}} = component} -> component
      _ -> nil
    end)
  end
end
