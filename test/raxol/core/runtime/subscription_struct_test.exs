defmodule Raxol.Core.Runtime.SubscriptionStructTest do
  @moduledoc """
  Tests for the struct and constructor functions of Raxol.Core.Runtime.Subscription.
  Covers new/2, interval/3, events/1, file_watch/2, custom/2, and basic start/stop
  for interval type using self() as context pid.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Subscription

  describe "new/2" do
    test "creates a subscription struct with given type and data" do
      sub = Subscription.new(:interval, %{interval: 500, message: :ping})

      assert %Subscription{type: :interval, data: %{interval: 500, message: :ping}} = sub
    end

    test "creates a subscription with arbitrary type and data" do
      sub = Subscription.new(:custom, %{module: SomeModule, args: %{}})

      assert %Subscription{type: :custom} = sub
      assert sub.data.module == SomeModule
    end

    test "creates a subscription with nil data" do
      sub = Subscription.new(:events, nil)

      assert %Subscription{type: :events, data: nil} = sub
    end
  end

  describe "interval/3" do
    test "creates an interval subscription with default options" do
      sub = Subscription.interval(1000, :tick)

      assert %Subscription{type: :interval} = sub
      assert sub.data.interval == 1000
      assert sub.data.message == :tick
      assert sub.data.start_immediately == false
      assert sub.data.jitter == 0
    end

    test "creates an interval subscription with start_immediately option" do
      sub = Subscription.interval(200, :update, start_immediately: true)

      assert %Subscription{type: :interval} = sub
      assert sub.data.start_immediately == true
      assert sub.data.jitter == 0
    end

    test "creates an interval subscription with jitter option" do
      sub = Subscription.interval(500, :poll, jitter: 50)

      assert %Subscription{type: :interval} = sub
      assert sub.data.jitter == 50
      assert sub.data.start_immediately == false
    end

    test "creates an interval subscription with all options" do
      sub = Subscription.interval(100, :refresh, start_immediately: true, jitter: 25)

      assert %Subscription{type: :interval} = sub
      assert sub.data.interval == 100
      assert sub.data.message == :refresh
      assert sub.data.start_immediately == true
      assert sub.data.jitter == 25
    end

    test "accepts any term as message" do
      sub_atom = Subscription.interval(100, :tick)
      assert sub_atom.data.message == :tick

      sub_tuple = Subscription.interval(100, {:update, :counter})
      assert sub_tuple.data.message == {:update, :counter}

      sub_string = Subscription.interval(100, "heartbeat")
      assert sub_string.data.message == "heartbeat"

      sub_int = Subscription.interval(100, 42)
      assert sub_int.data.message == 42
    end

    test "returns error for zero interval" do
      assert {:error, :invalid_interval} = Subscription.interval(0, :tick)
    end

    test "returns error for negative interval" do
      assert {:error, :invalid_interval} = Subscription.interval(-100, :tick)
    end

    test "returns error for non-integer interval" do
      assert {:error, :invalid_interval} = Subscription.interval(1.5, :tick)
    end

    test "returns error for string interval" do
      assert {:error, :invalid_interval} = Subscription.interval("1000", :tick)
    end

    test "returns error for nil interval" do
      assert {:error, :invalid_interval} = Subscription.interval(nil, :tick)
    end

    test "accepts minimum valid interval of 1" do
      sub = Subscription.interval(1, :tick)

      assert %Subscription{type: :interval} = sub
      assert sub.data.interval == 1
    end
  end

  describe "events/1" do
    test "creates an events subscription from a list of event types" do
      events = [:key_press, :mouse_click, :window_resize]
      sub = Subscription.events(events)

      assert %Subscription{type: :events, data: ^events} = sub
    end

    test "creates an events subscription with a single-element list" do
      sub = Subscription.events([:focus_change])

      assert %Subscription{type: :events, data: [:focus_change]} = sub
    end

    test "creates an events subscription with an empty list" do
      sub = Subscription.events([])

      assert %Subscription{type: :events, data: []} = sub
    end

    test "returns error for atom instead of list" do
      assert {:error, :invalid_events} = Subscription.events(:key_press)
    end

    test "returns error for string instead of list" do
      assert {:error, :invalid_events} = Subscription.events("key_press")
    end

    test "returns error for tuple instead of list" do
      assert {:error, :invalid_events} = Subscription.events({:key_press, :mouse_click})
    end

    test "returns error for nil" do
      assert {:error, :invalid_events} = Subscription.events(nil)
    end
  end

  describe "file_watch/2" do
    test "creates a file watch subscription with default events" do
      sub = Subscription.file_watch("/tmp/config.json")

      assert %Subscription{type: :file_watch} = sub
      assert sub.data.path == "/tmp/config.json"
      assert sub.data.events == [:modify]
    end

    test "creates a file watch subscription with custom events" do
      events = [:modify, :delete, :create]
      sub = Subscription.file_watch("/tmp/data.txt", events)

      assert %Subscription{type: :file_watch} = sub
      assert sub.data.path == "/tmp/data.txt"
      assert sub.data.events == events
    end

    test "creates a file watch subscription with all event types" do
      events = [:modify, :delete, :create, :rename, :attrib]
      sub = Subscription.file_watch("/tmp/watched", events)

      assert %Subscription{type: :file_watch} = sub
      assert sub.data.events == events
    end

    test "creates a file watch subscription with empty event list" do
      sub = Subscription.file_watch("/tmp/file.txt", [])

      assert %Subscription{type: :file_watch} = sub
      assert sub.data.events == []
    end

    test "returns error when events is an atom" do
      assert {:error, :invalid_file_watch_args} =
               Subscription.file_watch("/tmp/file.txt", :modify)
    end

    test "returns error when events is a string" do
      assert {:error, :invalid_file_watch_args} =
               Subscription.file_watch("/tmp/file.txt", "modify")
    end

    test "returns error when events is nil" do
      assert {:error, :invalid_file_watch_args} =
               Subscription.file_watch("/tmp/file.txt", nil)
    end
  end

  describe "custom/2" do
    test "creates a custom subscription with module and args" do
      sub = Subscription.custom(MyEventSource, %{config: :value})

      assert %Subscription{type: :custom} = sub
      assert sub.data.module == MyEventSource
      assert sub.data.args == %{config: :value}
    end

    test "creates a custom subscription with empty args map" do
      sub = Subscription.custom(SomeModule, %{})

      assert %Subscription{type: :custom} = sub
      assert sub.data.module == SomeModule
      assert sub.data.args == %{}
    end

    test "returns error when module is a string" do
      assert {:error, :invalid_module} = Subscription.custom("NotAModule", %{})
    end

    test "returns error when module is an integer" do
      assert {:error, :invalid_module} = Subscription.custom(42, %{})
    end

    test "returns error when args is a keyword list" do
      assert {:error, :invalid_args} = Subscription.custom(MyModule, config: :value)
    end

    test "returns error when args is a string" do
      assert {:error, :invalid_args} = Subscription.custom(MyModule, "args")
    end

    test "returns error when args is nil" do
      assert {:error, :invalid_args} = Subscription.custom(MyModule, nil)
    end
  end

  describe "start/2 with interval type" do
    test "starts an interval and receives timer messages" do
      sub = Subscription.interval(50, :tick)
      context = %{pid: self()}

      assert {:ok, {:interval, _timer_ref}} = Subscription.start(sub, context)

      assert_receive {:subscription, :tick}, 2_000
    end

    test "start_immediately sends message right away" do
      sub = Subscription.interval(5000, :immediate_tick, start_immediately: true)
      context = %{pid: self()}

      assert {:ok, {:interval, timer_ref}} = Subscription.start(sub, context)

      # The immediate message arrives long before the 5 s interval would fire.
      assert_receive {:subscription, :immediate_tick}, 2_000

      # Clean up the timer
      Subscription.stop({:interval, timer_ref})
    end

    test "returns error when context has no pid" do
      sub = Subscription.interval(100, :tick)
      context = %{other: :data}

      assert {:error, :invalid_context} = Subscription.start(sub, context)
    end
  end

  describe "stop/1 with interval type" do
    test "stops an interval subscription" do
      sub = Subscription.interval(50, :tick)
      context = %{pid: self()}

      {:ok, sub_id} = Subscription.start(sub, context)

      assert :ok = Subscription.stop(sub_id)

      # Drain any messages that were already in flight
      receive do
        {:subscription, :tick} -> :ok
      after
        0 -> :ok
      end

      # After stopping, no more messages should arrive
      refute_receive {:subscription, :tick}, 150
    end

    test "returns error for invalid subscription id" do
      assert {:error, :invalid_subscription} = Subscription.stop(:bogus)
    end
  end
end
