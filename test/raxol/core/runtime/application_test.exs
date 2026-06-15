defmodule Raxol.Core.Runtime.ApplicationTest do
  @moduledoc """
  Tests for the application runtime system, including behavior implementation,
  default implementations, and helper functions.
  """
  # Must be false due to process monitoring and subscriptions
  use ExUnit.Case, async: false

  # Test implementation of Application behavior
  defmodule TestApp do
    use Raxol.Core.Runtime.Application
    require Raxol.View.Elements

    @impl Raxol.Core.Runtime.Application
    def init(_context), do: %{count: 0, initialized: true}

    @impl Raxol.Core.Runtime.Application
    def update({:add, amount}, model) do
      {%{model | count: model.count + amount},
       [{:command, :operation_complete}]}
    end

    @impl Raxol.Core.Runtime.Application
    def update(message, state) do
      new_state =
        case message do
          :increment -> Map.update!(state, :count, &(&1 + 1))
          :decrement -> Map.update!(state, :count, &(&1 - 1))
          _ -> state
        end

      {new_state, []}
    end

    @impl Raxol.Core.Runtime.Application
    def view(state) do
      Raxol.Core.Renderer.View.panel(
        title: "Counter",
        children: [
          Raxol.Core.Renderer.View.row(
            children: [
              Raxol.View.Components.button(label: "-", on_click: :decrement),
              Raxol.Core.Renderer.View.text("Count: #{state.count}"),
              Raxol.View.Components.button(label: "+", on_click: :increment)
            ]
          )
        ]
      )
    end

    @impl Raxol.Core.Runtime.Application
    def subscribe(model) do
      interval = if model.count > 10, do: 100, else: 1000

      [
        subscribe_interval(interval, :tick),
        subscribe_to_events([:key_press, :mouse_click])
      ]
    end

    @impl Raxol.Core.Runtime.Application
    def handle_event(_), do: :ok

    @impl Raxol.Core.Runtime.Application
    def handle_message(_, _), do: :ok

    @impl Raxol.Core.Runtime.Application
    def handle_tick(_), do: :ok

    @impl Raxol.Core.Runtime.Application
    def terminate(_, _), do: :ok

    @impl Raxol.Core.Runtime.Application
    def subscriptions(_), do: []
  end

  # Test implementation with minimal overrides
  defmodule MinimalTestApp do
    use Raxol.Core.Runtime.Application

    # Only override init
    @impl Raxol.Core.Runtime.Application
    def init(_) do
      %{minimal: true}
    end

    # Override view to ensure correct call to text/1
    @impl Raxol.Core.Runtime.Application
    def view(_state) do
      Raxol.Core.Renderer.View.text("Default view")
    end

    # Implement required optional callbacks
    @impl Raxol.Core.Runtime.Application
    def handle_event(_), do: nil
    @impl Raxol.Core.Runtime.Application
    def handle_message(_, model), do: {model, []}
    @impl Raxol.Core.Runtime.Application
    def handle_tick(model), do: {model, []}
    @impl Raxol.Core.Runtime.Application
    def subscriptions(_), do: []
    @impl Raxol.Core.Runtime.Application
    def terminate(_, _), do: :ok
  end

  setup do
    # Initialize any required dependencies
    Raxol.Core.Events.EventManager.init()

    on_exit(fn ->
      # Clean up any enabled features
      [
        :keyboard_shortcuts,
        :events,
        :focus_management,
        :accessibility,
        :hints
      ]
      |> Enum.each(fn feature ->
        if Raxol.Core.UXRefinement.feature_enabled?(feature) do
          Raxol.Core.UXRefinement.disable_feature(feature)
        end
      end)

      # Clean up EventManager
      if Process.whereis(Raxol.Core.Events.EventManager),
        do: Raxol.Core.Events.EventManager.cleanup()
    end)

    :ok
  end

  describe "behavior implementation" do
    test ~c"init/1 sets up initial state" do
      result = TestApp.init(%{})
      assert result == %{count: 0, initialized: true}
    end

    test ~c"update/2 modifies state based on message" do
      model = %{count: 5, initialized: true}

      # Test increment
      {new_model, commands} = TestApp.update(:increment, model)
      assert new_model.count == 6
      assert commands == []

      # Test decrement
      {new_model, commands} = TestApp.update(:decrement, model)
      assert new_model.count == 4
      assert commands == []

      # Test command generation
      {new_model, commands} = TestApp.update({:add, 10}, model)
      assert new_model.count == 15
      assert commands == [{:command, :operation_complete}]
    end

    test ~c"view/1 renders the current state" do
      model = %{count: 42, initialized: true}
      result = TestApp.view(model)

      # Test that view generates correct structure
      assert is_map(result)
      assert Map.has_key?(result, :type)
      assert result[:type] == :box

      # Convert to string and check content
      string_result = inspect(result)
      assert string_result =~ "Count: 42"
      assert string_result =~ "button"
    end

    test ~c"subscribe/1 creates subscriptions based on state" do
      # State with low count
      model = %{count: 5, initialized: true}
      subscriptions = TestApp.subscribe(model)

      assert length(subscriptions) == 2
      # Check interval subscription
      [interval_sub, _events_sub] = subscriptions
      assert interval_sub.data.interval == 1000
      assert interval_sub.data.message == :tick

      # State with high count
      model = %{count: 15, initialized: true}
      subscriptions = TestApp.subscribe(model)

      [interval_sub, _] = subscriptions
      assert interval_sub.data.interval == 100
    end
  end

  describe "default implementations" do
    test ~c"minimal app has functioning defaults" do
      # Init
      model = MinimalTestApp.init(%{})
      assert model == %{minimal: true}

      # Update returns unchanged state with no commands
      {new_model, commands} = MinimalTestApp.update(:any_message, model)
      assert new_model == model
      assert commands == []

      # View returns a default view
      view = MinimalTestApp.view(model)
      assert is_map(view)
      assert Map.has_key?(view, :type)
      assert view[:type] == :text
      string_view = inspect(view)
      assert string_view =~ "Default view"

      # Subscribe returns empty list
      assert MinimalTestApp.subscribe(model) == []
    end
  end

  describe "helper functions" do
    test ~c"subscribe_to_events/1 creates event subscription" do
      events = [:event1, :event2]
      subscription = TestApp.subscribe_to_events(events)

      assert is_struct(subscription)

      assert Map.has_key?(subscription, :type),
             "Expected subscription to be a struct or map with :type key, got: #{inspect(subscription)}"

      assert subscription.type == :events
      assert subscription.data == events
    end

    test ~c"subscribe_interval/2 creates interval subscription" do
      subscription = TestApp.subscribe_interval(500, :tick)

      assert is_struct(subscription)

      assert Map.has_key?(subscription, :type),
             "Expected subscription to be a struct or map with :type key, got: #{inspect(subscription)}"

      assert subscription.type == :interval
      assert subscription.data.interval == 500
      assert subscription.data.message == :tick
    end
  end
end
