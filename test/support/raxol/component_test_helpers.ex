defmodule Raxol.ComponentTestHelpers do
  @moduledoc """
  Helper functions for testing Raxol components.

  Provides utilities for:
  - Simulating component lifecycles
  - Event sequence simulation
  - Rendering validation
  - Component state management
  """

  alias Raxol.Test.Unit

  @doc """
  Simulates a sequence of events on a component.

  ## Parameters

  * `component` - The component to simulate events on
  * `events` - List of events to simulate

  ## Returns

  The updated component after processing all events
  """
  def simulate_event_sequence(component, events) when is_list(events) do
    Enum.reduce(events, component, fn event, acc ->
      {updated, _commands} = Unit.simulate_event(acc, event)
      updated
    end)
  end

  @doc """
  Simulates a complete component lifecycle.

  ## Parameters

  * `component` - The component to simulate lifecycle on
  * `lifecycle_fn` - Function to execute during the mounted phase

  ## Returns

  Tuple of {final_component, lifecycle_events}
  """
  def simulate_lifecycle(component, lifecycle_fn) do
    # Mount the component
    mounted = mount_component(component)

    # Execute the lifecycle function
    result = lifecycle_fn.(mounted)

    # Unmount the component
    unmounted = unmount_component(result)

    # Return final state and lifecycle events. The event list is a single
    # marker: individual lifecycle events are not yet recorded.
    {unmounted, [:lifecycle_completed]}
  end

  @doc """
  Validates that a component renders correctly with different contexts.

  ## Parameters

  * `component` - The component to validate
  * `contexts` - List of rendering contexts to test

  ## Returns

  List of rendered elements
  """
  def validate_rendering(component, contexts) when is_list(contexts) do
    Enum.map(contexts, fn context ->
      component.module.render(component.state, context)
    end)
  end

  # Private helper functions

  defp mount_component(component) do
    case function_exported?(component.module, :mount, 1) do
      true ->
        {new_state, commands} = component.module.mount(component.state)

        # Process commands (similar to simulate_event)
        Enum.each(commands, fn command ->
          send(self(), {:commands, command})
        end)

        %{component | state: new_state}

      false ->
        component
    end
  end

  defp unmount_component(component) do
    case function_exported?(component.module, :unmount, 1) do
      true ->
        new_state = component.module.unmount(component.state)
        %{component | state: new_state}

      false ->
        component
    end
  end
end
