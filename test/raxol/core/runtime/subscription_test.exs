defmodule Raxol.Core.Runtime.SubscriptionTest do
  @moduledoc """
  Tests for the subscription runtime system, including creation,
  validation, and management.
  """
  # Must be false due to process monitoring and timers
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Raxol.Core.Runtime.Subscription

  describe "new/2" do
    test ~c"creates a new subscription with given type and data" do
      sub = Subscription.new(:interval, %{interval: 1000, message: :tick})

      assert %Subscription{
               type: :interval,
               data: %{interval: 1000, message: :tick}
             } = sub
    end
  end

  describe "interval/2" do
    test ~c"creates an interval subscription with default options" do
      sub = Subscription.interval(1000, :tick)
      assert %Subscription{type: :interval} = sub

      assert %{
               interval: 1000,
               message: :tick,
               start_immediately: false,
               jitter: 0
             } = sub.data
    end

    test ~c"creates an interval subscription with custom options" do
      sub =
        Subscription.interval(1000, :tick, start_immediately: true, jitter: 100)

      assert %Subscription{type: :interval} = sub

      assert %{
               interval: 1000,
               message: :tick,
               start_immediately: true,
               jitter: 100
             } = sub.data
    end

    test ~c"validates interval is positive" do
      assert {:error, :invalid_interval} = Subscription.interval(0, :tick)
      assert {:error, :invalid_interval} = Subscription.interval(-1000, :tick)
    end

    test ~c"handles very large intervals" do
      sub = Subscription.interval(1_000_000_000, :tick)
      assert %Subscription{type: :interval} = sub
      assert %{interval: 1_000_000_000} = sub.data
    end

    test ~c"handles very small intervals" do
      sub = Subscription.interval(1, :tick)
      assert %Subscription{type: :interval} = sub
      assert %{interval: 1} = sub.data
    end
  end

  describe "events/1" do
    test ~c"creates an events subscription" do
      events = [:key_press, :mouse_click]
      sub = Subscription.events(events)
      assert %Subscription{type: :events, data: ^events} = sub
    end

    test ~c"requires event types to be a list" do
      assert {:error, :invalid_events} = Subscription.events(:key_press)
    end
  end

  describe "file_watch/2" do
    setup do
      test_file =
        Path.join(
          System.tmp_dir!(),
          "test_subscription_#{:rand.uniform(1000)}.txt"
        )

      File.write!(test_file, "test content")

      on_exit(fn ->
        File.rm(test_file)
      end)

      {:ok, test_file: test_file}
    end

    test "creates a file watch subscription with default events", %{
      test_file: test_file
    } do
      sub = Subscription.file_watch(test_file)
      assert %Subscription{type: :file_watch} = sub
      assert %{path: ^test_file, events: [:modify]} = sub.data
    end

    test "creates a file watch subscription with custom events", %{
      test_file: test_file
    } do
      events = [:modify, :delete, :create]
      sub = Subscription.file_watch(test_file, events)
      assert %Subscription{type: :file_watch} = sub
      assert %{path: ^test_file, events: ^events} = sub.data
    end

    test ~c"requires events to be a list" do
      assert {:error, :invalid_file_watch_args} =
               Subscription.file_watch("test.txt", :modify)
    end
  end

  describe "custom/2" do
    test ~c"creates a custom subscription" do
      module = MyEventSource
      args = %{config: :value}
      sub = Subscription.custom(module, args)
      assert %Subscription{type: :custom} = sub
      assert %{module: ^module, args: ^args} = sub.data
    end

    test ~c"validates module is an atom" do
      assert {:error, :invalid_module} =
               Subscription.custom("not_a_module", %{})
    end

    test ~c"validates args is a map" do
      assert {:error, :invalid_args} =
               Subscription.custom(MyEventSource, "not_a_map")
    end
  end

  describe "start/2" do
    setup do
      setup_event_manager()
    end

    test "starts an interval subscription", %{context: context} do
      sub = Subscription.interval(50, :tick, start_immediately: true)
      assert {:ok, {:interval, timer_ref}} = Subscription.start(sub, context)

      on_exit(fn ->
        ref = elem(timer_ref, 1)
        if Process.read_timer(ref), do: Process.cancel_timer(ref)
      end)

      # The immediate tick is sent before start/2 returns; the timer's tick
      # arrives whenever the scheduler gets to it, so it is waited for with a
      # hang bound rather than a deadline.
      assert_received {:subscription, :tick}
      assert_receive {:subscription, :tick}, 1_000
    end

    test "starts an events subscription", %{context: context} do
      sub = Subscription.events([:test_event])
      assert {:ok, {:events, _id}} = Subscription.start(sub, context)
    end

    test "starts a file watch subscription", %{context: context} do
      test_file =
        Path.join(
          System.tmp_dir!(),
          "test_subscription_#{:rand.uniform(1000)}.txt"
        )

      File.write!(test_file, "test content")

      on_exit(fn ->
        File.rm(test_file)
      end)

      sub = Subscription.file_watch(test_file)
      assert {:ok, {:file_watch, pid}} = Subscription.start(sub, context)
      assert is_pid(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)
    end

    test "handles invalid subscription type", %{context: context} do
      sub = %Subscription{type: :invalid, data: %{}}

      assert {:error, :invalid_subscription_type} =
               Subscription.start(sub, context)
    end

    test "handles missing context pid", %{context: context} do
      sub = Subscription.interval(50, :tick)
      invalid_context = Map.delete(context, :pid)

      assert {:error, :invalid_context} =
               Subscription.start(sub, invalid_context)
    end

    test "handles invalid file path for file watch", %{context: context} do
      sub = Subscription.file_watch("/nonexistent/path/file.txt")
      assert {:error, :invalid_file_path} = Subscription.start(sub, context)
    end
  end

  describe "stop/1" do
    setup do
      setup_event_manager()
    end

    test "stops an interval subscription", %{context: context} do
      sub = Subscription.interval(50, :tick)
      {:ok, sub_id} = Subscription.start(sub, context)
      assert :ok = Subscription.stop(sub_id)
    end

    test ~c"returns error for invalid subscription id" do
      assert {:error, :invalid_subscription} = Subscription.stop(:invalid)
    end

    test "stops an events subscription", %{context: context} do
      sub = Subscription.events([:test_event])
      {:ok, sub_id} = Subscription.start(sub, context)
      assert :ok = Subscription.stop(sub_id)
    end

    test "stops a file watch subscription", %{context: context} do
      test_file =
        Path.join(
          System.tmp_dir!(),
          "test_subscription_#{:rand.uniform(1000)}.txt"
        )

      File.write!(test_file, "test content")

      on_exit(fn ->
        File.rm(test_file)
      end)

      sub = Subscription.file_watch(test_file)
      {:ok, sub_id} = Subscription.start(sub, context)
      assert :ok = Subscription.stop(sub_id)
    end

    test "handles stopping already stopped subscription", %{context: context} do
      sub = Subscription.interval(50, :tick)
      {:ok, sub_id} = Subscription.start(sub, context)
      assert :ok = Subscription.stop(sub_id)
      # The Erlang timer module returns :ok for already cancelled timers
      assert :ok = Subscription.stop(sub_id)
    end
  end

  # Private helper to set up EventManager for subscription tests
  defp setup_event_manager do
    # Start EventManager for event subscriptions
    case Raxol.Core.Events.EventManager.start_link(
           name: Raxol.Core.Events.EventManager
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    context = %{pid: self()}

    on_exit(fn ->
      # Only cleanup if EventManager is still running
      case Process.whereis(Raxol.Core.Events.EventManager) do
        nil -> :ok
        _pid -> Raxol.Core.Events.EventManager.cleanup()
      end
    end)

    {:ok, context: context}
  end
end
