defmodule Raxol.Terminal.Input.BufferTest do
  use ExUnit.Case, async: true

  # Every test here waits for the buffer process to finish by monitoring it.
  # ExUnit's DEFAULT `assert_receive` bound is 100ms, which on a loaded
  # runner is a coin flip for "a GenServer processed one keystroke and
  # exited": this file's "handles callback errors gracefully" test was seen
  # failing with "no matching message after 100ms" once in ten runs. The
  # message still has to ARRIVE -- this is a receive bound, not a ceiling on
  # how long the work may take -- so it is set generously and explicitly.
  @down_timeout_ms 5_000
  alias Raxol.Terminal.Input.Buffer

  setup do
    {:ok, pid} = Buffer.start_link()
    # Monitor the process to receive DOWN messages
    Process.monitor(pid)
    # Create a mutable state for collecting events
    events = :ets.new(:events, [:ordered_set, :public])
    counter = :atomics.new(1, [])
    %{pid: pid, events: events, counter: counter}
  end

  describe "input buffering" do
    test "processes complete sequences immediately", %{
      pid: pid,
      events: events,
      counter: counter
    } do
      Buffer.register_callback(pid, fn event ->
        idx = :atomics.add_get(counter, 1, 1)
        :ets.insert(events, {idx, event})
      end)

      Buffer.feed_input(pid, "a")
      assert_receive {:DOWN, _, :process, ^pid, :normal}, @down_timeout_ms

      # Get events from ETS after process termination
      collected_events =
        :ets.tab2list(events) |> Enum.map(fn {_, event} -> event end)

      assert [event] = collected_events
      assert event.key == "a"
      assert event.modifiers == []
    end

    test "buffers partial sequences", %{
      pid: pid,
      events: events,
      counter: counter
    } do
      Buffer.register_callback(pid, fn event ->
        idx = :atomics.add_get(counter, 1, 1)
        :ets.insert(events, {idx, event})
      end)

      # Feed partial escape sequence
      Buffer.feed_input(pid, "\e[")
      assert_receive {:DOWN, _, :process, ^pid, :normal}, @down_timeout_ms

      # Should not have processed the partial sequence
      collected_events =
        :ets.tab2list(events) |> Enum.map(fn {_, event} -> event end)

      assert [] = collected_events
    end

    test "handles multiple sequences in one input", %{
      pid: pid,
      events: events,
      counter: counter
    } do
      Buffer.register_callback(pid, fn event ->
        idx = :atomics.add_get(counter, 1, 1)
        :ets.insert(events, {idx, event})
      end)

      # Feed multiple sequences: "b" + mouse event + "a"
      input = "b\e[0;0;10;20Ma"
      Buffer.feed_input(pid, input)
      assert_receive {:DOWN, _, :process, ^pid, :normal}, @down_timeout_ms

      collected_events =
        :ets.tab2list(events) |> Enum.map(fn {_, event} -> event end)

      assert length(collected_events) == 3

      # Check first event (key "b")
      [event1 | rest] = collected_events
      assert event1.key == "b"
      assert event1.modifiers == []

      # Check second event (mouse event)
      [event2 | rest] = rest
      assert event2.button == :left
      assert event2.action == :press
      assert event2.x == 10
      assert event2.y == 20

      # Check third event (key "a")
      [event3] = rest
      assert event3.key == "a"
      assert event3.modifiers == []
    end
  end

  describe "callback handling" do
    test "calls callback for each complete event", %{
      pid: pid,
      events: events,
      counter: counter
    } do
      Buffer.register_callback(pid, fn event ->
        idx = :atomics.add_get(counter, 1, 1)
        :ets.insert(events, {idx, event})
      end)

      Buffer.feed_input(pid, "abc")
      assert_receive {:DOWN, _, :process, ^pid, :normal}, @down_timeout_ms

      collected_events =
        :ets.tab2list(events) |> Enum.map(fn {_, event} -> event end)

      assert length(collected_events) == 3

      # Check all events have correct keys and modifiers
      keys = Enum.map(collected_events, & &1.key)
      assert keys == ["a", "b", "c"]

      Enum.each(collected_events, fn event ->
        assert event.modifiers == []
      end)
    end

    test "handles callback errors gracefully", %{
      pid: pid,
      events: events,
      counter: _counter
    } do
      # Callback that raises an error
      Buffer.register_callback(pid, fn _event -> raise "Callback error" end)

      # Should not crash the buffer
      Buffer.feed_input(pid, "a")
      assert_receive {:DOWN, _, :process, ^pid, :normal}, @down_timeout_ms

      # No events should be stored due to callback error
      collected_events =
        :ets.tab2list(events) |> Enum.map(fn {_, event} -> event end)

      assert [] = collected_events
    end
  end

  describe "buffer management" do
    test "clears buffer", %{pid: pid, events: events, counter: counter} do
      Buffer.register_callback(pid, fn event ->
        idx = :atomics.add_get(counter, 1, 1)
        :ets.insert(events, {idx, event})
      end)

      Buffer.clear_buffer(pid)
      assert_receive {:DOWN, _, :process, ^pid, :normal}, @down_timeout_ms

      # Buffer should be cleared
      collected_events =
        :ets.tab2list(events) |> Enum.map(fn {_, event} -> event end)

      assert [] = collected_events
    end

    test "handles timeout for partial sequences", %{
      pid: pid,
      events: events,
      counter: counter
    } do
      Buffer.register_callback(pid, fn event ->
        idx = :atomics.add_get(counter, 1, 1)
        :ets.insert(events, {idx, event})
      end)

      # Feed partial sequence and wait for timeout
      Buffer.feed_input(pid, "\e")
      assert_receive {:DOWN, _, :process, ^pid, :normal}, @down_timeout_ms

      # Should not have processed the partial sequence
      collected_events =
        :ets.tab2list(events) |> Enum.map(fn {_, event} -> event end)

      assert [] = collected_events
    end
  end

  describe "sequence detection" do
    test "detects key sequences", %{pid: pid, events: events, counter: counter} do
      Buffer.register_callback(pid, fn event ->
        idx = :atomics.add_get(counter, 1, 1)
        :ets.insert(events, {idx, event})
      end)

      # Ctrl+Shift+A
      Buffer.feed_input(pid, "\e[1;2;5A")
      assert_receive {:DOWN, _, :process, ^pid, :normal}, @down_timeout_ms

      collected_events =
        :ets.tab2list(events) |> Enum.map(fn {_, event} -> event end)

      assert [event] = collected_events
      assert event.key == "A"
      assert event.modifiers == [:shift, :ctrl]
    end

    test "detects mouse sequences", %{
      pid: pid,
      events: events,
      counter: counter
    } do
      Buffer.register_callback(pid, fn event ->
        idx = :atomics.add_get(counter, 1, 1)
        :ets.insert(events, {idx, event})
      end)

      # Left mouse press at (10,20)
      Buffer.feed_input(pid, "\e[0;0;10;20M")
      assert_receive {:DOWN, _, :process, ^pid, :normal}, @down_timeout_ms

      collected_events =
        :ets.tab2list(events) |> Enum.map(fn {_, event} -> event end)

      assert [event] = collected_events
      assert event.button == :left
      assert event.action == :press
      assert event.x == 10
      assert event.y == 20
    end

    test "handles invalid sequences", %{
      pid: pid,
      events: events,
      counter: counter
    } do
      Buffer.register_callback(pid, fn event ->
        idx = :atomics.add_get(counter, 1, 1)
        :ets.insert(events, {idx, event})
      end)

      Buffer.feed_input(pid, "\e[invalid")
      assert_receive {:DOWN, _, :process, ^pid, :normal}, @down_timeout_ms

      # Should not process invalid sequences
      collected_events =
        :ets.tab2list(events) |> Enum.map(fn {_, event} -> event end)

      assert [] = collected_events
    end
  end
end
