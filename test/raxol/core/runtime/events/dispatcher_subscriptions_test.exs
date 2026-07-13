defmodule Raxol.Core.Runtime.Events.DispatcherSubscriptionsTest do
  @moduledoc """
  Subscriptions are a function of the model, so they must be re-derived after
  every update: newly-declared ones start, no-longer-declared ones stop, and
  unchanged ones keep running untouched.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Events.Dispatcher
  alias Raxol.Core.Runtime.Events.Dispatcher.State
  alias Raxol.Core.Runtime.Subscription

  defmodule TickWhenRunningApp do
    @moduledoc false
    # Subscriptions depend on state: a tick only while :running.
    def subscribe(%{running: true}), do: [Subscription.interval(50, :tick)]
    def subscribe(_model), do: []

    def update(%Event{type: :resize, data: %{width: w}}, model) do
      {%{model | running: w > 0}, []}
    end

    def update(_message, model), do: {model, []}
  end

  defp base_state(model) do
    %State{
      runtime_pid: self(),
      app_module: TickWhenRunningApp,
      model: model,
      width: 80,
      height: 24,
      rendering_engine: self()
    }
  end

  defp resize(w), do: %Event{type: :resize, data: %{width: w, height: 24}}

  test "a subscription declared only by the updated model gets started" do
    state = base_state(%{running: false})
    assert state.active_subscriptions == %{}

    {:ok, new_state, _} = Dispatcher.process_system_event(resize(100), state)

    assert new_state.model.running
    assert map_size(new_state.active_subscriptions) == 1

    assert [%Subscription{type: :interval}] =
             Map.keys(new_state.active_subscriptions)
  end

  test "a subscription no longer declared gets stopped" do
    {:ok, running, _} =
      Dispatcher.process_system_event(
        resize(100),
        base_state(%{running: false})
      )

    assert map_size(running.active_subscriptions) == 1

    {:ok, stopped, _} = Dispatcher.process_system_event(resize(0), running)

    refute stopped.model.running
    assert stopped.active_subscriptions == %{}
  end

  test "an unchanged subscription is left running, not torn down and restarted" do
    {:ok, running, _} =
      Dispatcher.process_system_event(
        resize(100),
        base_state(%{running: false})
      )

    before = running.active_subscriptions
    assert map_size(before) == 1

    # Still :running, so the same subscription is still declared.
    {:ok, again, _} = Dispatcher.process_system_event(resize(200), running)

    assert again.model.running
    # Same subscription id -- the timer was not restarted.
    assert again.active_subscriptions == before
  end
end
