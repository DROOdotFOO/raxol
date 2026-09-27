defmodule Raxol.Core.Runtime.Events.DispatcherSubscriptionsTest do
  @moduledoc """
  Subscriptions are a function of the model, so they must be re-derived after
  every update: newly-declared ones start, no-longer-declared ones stop, and
  unchanged ones keep running untouched.
  """
  # async: false -- the Subscription.events/1 tests use, and one stops, the
  # globally named EventManager.
  use ExUnit.Case, async: false

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Events.EventManager
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

  defmodule EventsApp do
    @moduledoc false
    # Declares one Subscription.events/1 per list in :declared while
    # :listening, and reports every message update/2 sees to the test process.
    def subscribe(%{listening: true, declared: declared}),
      do: Enum.map(declared, &Subscription.events/1)

    def subscribe(_model), do: []

    def update(%Event{type: :resize, data: %{width: 0}}, model) do
      {%{model | listening: false}, []}
    end

    def update(message, model) do
      send(model.test_pid, {:update, message})
      {model, []}
    end
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

  describe "Subscription.events/1" do
    setup context do
      # Supervised by the application; a sync test elsewhere may have stopped it.
      if is_nil(Process.whereis(EventManager)),
        do: start_supervised!(EventManager)

      type = :"dispatcher_sub_test_#{System.unique_integer([:positive])}"

      declared =
        if context[:overlapping],
          do: [[type], [type, :"#{type}_other"]],
          else: [[type]]

      initial_state = %{
        app_module: EventsApp,
        model: %{test_pid: self(), declared: declared, listening: true},
        width: 80,
        height: 24,
        debug_mode: false,
        plugin_manager: nil,
        command_registry_table: nil
      }

      dispatcher =
        start_supervised!(%{
          id: Dispatcher,
          start: {Dispatcher, :start_link, [self(), initial_state, [name: nil]]}
        })

      %{dispatcher: dispatcher, type: type}
    end

    test "delivers an EventManager event to update/2 as {:event, type, data}",
         %{type: type} do
      :ok = EventManager.dispatch(type, %{n: 1})
      assert_receive {:update, {:event, ^type, %{n: 1}}}, 1_000

      :ok = EventManager.notify(type, %{n: 2})
      assert_receive {:update, {:event, ^type, %{n: 2}}}, 1_000
    end

    test "stops delivering once the model no longer declares it",
         %{dispatcher: dispatcher, type: type} do
      :ok = EventManager.dispatch(type, %{n: 1})
      assert_receive {:update, {:event, ^type, %{n: 1}}}, 1_000

      # Synchronous: the unsubscribe has reached EventManager on return.
      :ok = GenServer.call(dispatcher, {:dispatch, resize(0)})

      :ok = EventManager.dispatch(type, %{n: 2})
      refute_receive {:update, {:event, ^type, _}}, 100
    end

    @tag :overlapping
    test "an event type declared by two subscriptions reaches update/2 once",
         %{dispatcher: dispatcher, type: type} do
      :ok = EventManager.dispatch(type, %{n: 1})
      assert_receive {:update, {:event, ^type, %{n: 1}}}, 1_000

      # Any second copy was queued behind the first; let it be handled.
      _ = :sys.get_state(dispatcher)
      refute_received {:update, {:event, ^type, _}}
    end

    test "an event queued behind the update that drops its subscription is not delivered",
         %{dispatcher: dispatcher, type: type} do
      :ok = :sys.suspend(dispatcher)
      :ok = GenServer.cast(dispatcher, {:dispatch, resize(0)})
      :ok = EventManager.dispatch(type, %{n: 1})
      # EventManager has sent the event once it answers a later call.
      _ = EventManager.get_handlers()
      :ok = :sys.resume(dispatcher)

      _ = :sys.get_state(dispatcher)
      refute_received {:update, {:event, ^type, _}}
    end

    test "an {:event, type, data} message for a type no subscription lists is not delivered",
         %{dispatcher: dispatcher, type: type} do
      forged = :"#{type}_forged"
      send(dispatcher, {:event, forged, %{forged: true}})

      _ = :sys.get_state(dispatcher)
      refute_received {:update, {:event, ^forged, _}}
    end

    test "dropping the subscription while EventManager is down leaves the Dispatcher running",
         %{dispatcher: dispatcher} do
      _ = stop_supervised(EventManager)
      :ok = EventManager.cleanup()
      assert is_nil(Process.whereis(EventManager))

      assert :ok = GenServer.call(dispatcher, {:dispatch, resize(0)})
      assert Process.alive?(dispatcher)
    end
  end
end
