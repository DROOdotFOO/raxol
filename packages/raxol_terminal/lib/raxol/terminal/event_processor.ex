defmodule Raxol.Terminal.EventProcessor do
  @moduledoc """
  Optimized event processing pipeline for terminal events.

  This module provides high-performance event processing with:
  - Batch event processing for improved throughput
  - Event priority handling
  - Optimized memory usage with pre-compiled handlers
  - Event filtering and debouncing
  - Performance monitoring integration
  """

  alias Raxol.Core.Events.Event
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Events.Handler

  # Pre-compiled event handlers for maximum performance
  @event_handlers %{
    window: &Handler.handle_window_event/2,
    mode: &Handler.handle_mode_event/2,
    focus: &Handler.handle_focus_event/2,
    clipboard: &Handler.handle_clipboard_event/2,
    selection: &Handler.handle_selection_event/2,
    paste: &Handler.handle_paste_event/2,
    cursor: &Handler.handle_cursor_event/2,
    scroll: &Handler.handle_scroll_event/2,
    keyboard: &Handler.handle_keyboard_event/2,
    mouse: &Handler.handle_mouse_event/2
  }

  # Event priority levels for processing order
  @event_priorities %{
    # Highest priority - user input
    keyboard: 1,
    # Highest priority - user input
    mouse: 1,
    # High priority - visual feedback
    cursor: 2,
    # High priority - visual feedback
    scroll: 2,
    # Medium priority
    selection: 3,
    # Medium priority
    paste: 3,
    # Medium priority
    clipboard: 3,
    # Low priority
    focus: 4,
    # Low priority
    window: 4,
    # Lowest priority
    mode: 5
  }

  # Debounce intervals (in milliseconds) for event types
  @debounce_intervals %{
    # ~60fps for smooth scrolling
    scroll: 16,
    # Avoid excessive redraws during window resize
    resize: 100,
    # ~120fps for responsive mouse tracking
    mouse: 8
  }

  @doc """
  Processes a single terminal event with optimized performance.

  ## Parameters
    * `event` - The event to process
    * `emulator` - The current terminal emulator state

  ## Returns
    * `{updated_emulator, output}` - The updated emulator state and any output
  """
  @spec process_event(Event.t(), Emulator.t()) :: {Emulator.t(), any()}
  def process_event(%Event{type: type, data: data} = event, emulator) do
    # Fast path for known event types
    case Map.fetch(@event_handlers, type) do
      {:ok, handler} ->
        start_time = System.monotonic_time(:microsecond)
        result = handler.(data, emulator)
        end_time = System.monotonic_time(:microsecond)

        # Record performance metrics for monitoring
        record_event_processing_time(type, end_time - start_time)

        result

      :error ->
        handle_unknown_event(event, emulator)
    end
  end

  @doc """
  Processes multiple events in batch for improved performance.

  ## Parameters
    * `events` - List of events to process
    * `emulator` - The current terminal emulator state

  ## Returns
    * `{updated_emulator, outputs}` - The updated emulator state and list of outputs
  """
  @spec process_events_batch([Event.t()], Emulator.t()) ::
          {Emulator.t(), [any()]}
  def process_events_batch([], emulator), do: {emulator, []}

  def process_events_batch(events, emulator) when is_list(events) do
    # Sort events by priority for optimal processing order
    sorted_events = sort_events_by_priority(events)

    # Filter out events that should be debounced
    filtered_events = apply_debouncing(sorted_events)

    # Process events with accumulated state
    {final_emulator, outputs} =
      Enum.reduce(filtered_events, {emulator, []}, fn event, {acc_emulator, acc_outputs} ->
        {updated_emulator, output} = process_event(event, acc_emulator)
        {updated_emulator, [output | acc_outputs]}
      end)

    {final_emulator, Enum.reverse(outputs)}
  end

  @doc """
  Processes high-priority events immediately, queues others.

  ## Parameters
    * `event` - The event to process
    * `emulator` - The current terminal emulator state
    * `options` - Processing options

  ## Returns
    * `{:immediate, updated_emulator, output}` - Processed immediately
    * `{:queued, emulator}` - Queued for later processing
  """
  @spec process_event_with_priority(Event.t(), Emulator.t(), keyword()) ::
          {:immediate, Emulator.t(), any()} | {:queued, Emulator.t()}
  def process_event_with_priority(
        %Event{type: type} = event,
        emulator,
        options \\ []
      ) do
    priority = Map.get(@event_priorities, type, 5)
    immediate_threshold = Keyword.get(options, :immediate_threshold, 2)

    case priority <= immediate_threshold do
      true ->
        {updated_emulator, output} = process_event(event, emulator)
        {:immediate, updated_emulator, output}

      false ->
        # Queue for batch processing
        {:queued, emulator}
    end
  end

  @doc """
  Optimized event filtering to reduce processing overhead.
  """
  @spec filter_redundant_events([Event.t()]) :: [Event.t()]
  def filter_redundant_events(events) when is_list(events) do
    # Group events by type and keep only the most recent for certain types
    events
    |> Enum.group_by(fn %Event{type: type} -> type end)
    |> Enum.flat_map(fn {type, type_events} ->
      case should_deduplicate_event_type(type) do
        # Keep only the latest
        true -> [List.last(type_events)]
        # Keep all events
        false -> type_events
      end
    end)
    |> Enum.sort_by(fn %Event{timestamp: timestamp} -> timestamp end)
  end

  # Private helper functions

  defp handle_unknown_event(%Event{type: type, data: data}, emulator) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Unknown terminal event type: #{inspect(type)} with data: #{inspect(data)}",
      %{event_type: type, data_size: byte_size(inspect(data))}
    )

    {emulator, nil}
  end

  defp sort_events_by_priority(events) do
    Enum.sort_by(events, fn %Event{type: type} ->
      Map.get(@event_priorities, type, 5)
    end)
  end

  defp apply_debouncing(events) do
    # Simple debouncing implementation - in production, this would be more sophisticated
    events
    |> Enum.group_by(fn %Event{type: type} -> type end)
    |> Enum.flat_map(fn {type, type_events} ->
      case Map.get(@debounce_intervals, type) do
        nil -> type_events
        _interval -> debounce_events_of_type(type_events)
      end
    end)
    |> Enum.sort_by(fn %Event{timestamp: timestamp} -> timestamp end)
  end

  defp debounce_events_of_type(events) when length(events) <= 1, do: events

  defp debounce_events_of_type(events) do
    # For demonstration - keep first and last event, drop middle ones
    case events do
      [first | rest] ->
        last = List.last(rest)

        case first == last do
          true -> [first]
          false -> [first, last]
        end

      [] ->
        []
    end
  end

  defp should_deduplicate_event_type(type) do
    # Event types that can be deduplicated (keep only latest)
    type in [:scroll, :cursor, :focus]
  end

  defp record_event_processing_time(event_type, duration_microseconds) do
    # Send metrics to performance monitoring system
    case Application.get_env(:raxol, :enable_performance_metrics, false) do
      true ->
        :telemetry.execute(
          [:raxol, :terminal, :event_processing],
          %{duration: duration_microseconds},
          %{event_type: event_type}
        )

      false ->
        :ok
    end
  end
end
