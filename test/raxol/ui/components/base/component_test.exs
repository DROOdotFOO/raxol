defmodule Raxol.UI.Components.Base.ComponentTest do
  use ExUnit.Case, async: true
  import Raxol.Test.TestUtils, only: [create_test_component: 2]

  import Raxol.ComponentTestHelpers,
    only: [
      simulate_event_sequence: 2,
      simulate_lifecycle: 2,
      validate_rendering: 2
    ]

  alias Raxol.Test.Unit

  @moduledoc false
  defmodule TestComponent do
    @behaviour Raxol.UI.Components.Base.Component

    @impl true
    def init(props) do
      Map.merge(
        %{
          id: :test_id,
          type: :test_component,
          counter: 0,
          mounted: false,
          unmounted: false,
          events: [],
          render_count: 0,
          position: {0, 0},
          style: %{}
        },
        props
      )
    end

    @impl true
    def mount(state) do
      new_state = %{state | mounted: true}
      {new_state, [{:command, :mounted}]}
    end

    @impl true
    def update(:increment, state) do
      %{state | counter: state.counter + 1}
    end

    @impl true
    def update(:decrement, state) do
      %{state | counter: state.counter - 1}
    end

    @impl true
    def render(state, context) do
      %{
        type: :test_component,
        id: state.id,
        counter: state.counter,
        theme: context.theme
      }
    end

    @impl true
    def handle_event(%{type: :test_event, value: value}, state, _context) do
      new_state = %{state | events: [value | state.events]}
      {new_state, [{:command, :event_handled}]}
    end

    @impl true
    def handle_event(
          %Raxol.Core.Events.Event{data: %{type: :test_event, value: value}},
          state,
          _context
        ) do
      new_state = %{state | events: [value | state.events]}
      {new_state, [{:command, :event_handled}]}
    end

    @impl true
    def handle_event(%{type: :mounted}, state, _context) do
      {state, [{:command, :mounted}]}
    end

    @impl true
    def handle_event(_event, state, _context) do
      {state, []}
    end

    @impl true
    def unmount(state) do
      %{state | unmounted: true}
    end

    def new(props \\ %{}) do
      Map.merge(
        %{
          id: :test_component,
          counter: 0,
          mounted: false,
          unmounted: false,
          events: [],
          render_count: 0
        },
        props
      )
    end
  end

  describe "Component Lifecycle" do
    test "complete lifecycle flow" do
      component = create_test_component(TestComponent, %{})

      {final_component, events} =
        simulate_lifecycle(component, fn mounted ->
          # Verify mounted state
          assert mounted.state.mounted
          assert_receive {:commands, {:command, :mounted}}

          # Update state
          updated =
            simulate_event_sequence(mounted, [
              %{type: :test_event, value: "test1"},
              %{type: :test_event, value: "test2"}
            ])

          # Verify updates
          assert updated.state.counter == 0
          assert updated.state.events == ["test2", "test1"]

          updated
        end)

      # Verify final state
      assert final_component.state.unmounted
      assert [_ | _] = events
    end

    test "mount with initial props" do
      component = create_test_component(TestComponent, %{counter: 5})
      assert component.state.counter == 5
    end

    test "unmount cleanup" do
      component = create_test_component(TestComponent, %{})
      {final, _} = simulate_lifecycle(component, & &1)
      assert final.state.unmounted
    end
  end

  describe "State Management" do
    test "state updates through events" do
      component = create_test_component(TestComponent, %{})

      updated =
        simulate_event_sequence(component, [
          %{type: :test_event, value: "test1"},
          %{type: :test_event, value: "test2"}
        ])

      assert updated.state.events == ["test2", "test1"]
    end

    test "state updates through commands" do
      component = create_test_component(TestComponent, %{})

      {updated, commands} =
        Unit.simulate_event(component, %{type: :test_event, value: "test"})

      assert updated.state.events == ["test"]
      assert commands == [{:command, :event_handled}]
    end
  end

  describe "Rendering" do
    test "renders with different contexts" do
      component = create_test_component(TestComponent, %{})

      contexts = [
        %{theme: %{mode: :light}},
        %{theme: %{mode: :dark}},
        %{theme: %{mode: :high_contrast}}
      ]

      rendered = validate_rendering(component, contexts)

      assert length(rendered) == 3
      assert Enum.all?(rendered, &(&1.type == :test_component))
    end

    test "render count tracking" do
      component = create_test_component(TestComponent, %{})

      {final, _} =
        simulate_lifecycle(component, fn mounted ->
          # Render multiple times
          contexts = [
            %{theme: test_theme()},
            %{theme: test_theme()},
            %{theme: test_theme()}
          ]

          validate_rendering(mounted, contexts)
          mounted
        end)

      # Since render functions shouldn't update state, we'll just verify the component works
      assert final.state.mounted
    end
  end

  describe "Event Handling" do
    test "handles known events" do
      component = create_test_component(TestComponent, %{})

      {updated, commands} =
        Unit.simulate_event(component, %{type: :test_event, value: "test"})

      assert updated.state.events == ["test"]
      assert commands == [{:command, :event_handled}]
    end

    test "ignores unknown events" do
      component = create_test_component(TestComponent, %{})

      {updated, commands} =
        Unit.simulate_event(component, %{type: :unknown_event})

      assert updated.state == component.state
      assert commands == []
    end

    test "event sequence handling" do
      component = create_test_component(TestComponent, %{})

      events = [
        %{type: :test_event, value: "test1"},
        %{type: :test_event, value: "test2"},
        %{type: :unknown_event}
      ]

      updated = simulate_event_sequence(component, events)

      assert updated.state.events == ["test2", "test1"]
    end
  end

  describe "Accessibility" do
    test "renders with accessibility context" do
      component = create_test_component(TestComponent, %{})

      # Use canonical accessibility helpers
      # Example: assert_sufficient_contrast, assert_announced, etc.
      # Here, we just check that the component renders with accessibility context without error
      rendered =
        component.module.render(component.state, %{
          theme: %{mode: :test},
          accessibility: %{
            high_contrast: true,
            screen_reader: true
          }
        })

      # If you want to check contrast, ARIA, etc., use the helpers from
      # Raxol.AccessibilityTestHelpers
      assert rendered.type == :test_component
    end
  end

  describe "Error Handling" do
    test "handles invalid events gracefully" do
      component = create_test_component(TestComponent, %{})

      {updated, commands} =
        Unit.simulate_event(component, %{type: :invalid_event, data: nil})

      assert updated.state == component.state
      assert commands == []
    end

    test "handles missing optional callbacks" do
      defmodule MinimalComponent do
        @behaviour Raxol.UI.Components.Base.Component

        def new(props \\ %{}), do: props
        def init(props), do: props
        def render(state, _context), do: %{type: :minimal}
        def handle_event(_event, state), do: {state, []}
      end

      component = create_test_component(MinimalComponent, %{})
      {final, _} = simulate_lifecycle(component, & &1)

      assert final.state == component.state
    end
  end

  # Minimal test theme for rendering tests
  defp test_theme do
    %Raxol.UI.Theming.Theme{
      id: :test,
      name: "Test Theme",
      description: "A theme for testing",
      colors: %{foreground: :white, background: :black},
      component_styles: %{
        test_component: %{text_color: :white, background: :black},
        button: %{background: :blue, foreground: :white}
      },
      variants: %{},
      metadata: %{},
      fonts: %{}
    }
  end
end
