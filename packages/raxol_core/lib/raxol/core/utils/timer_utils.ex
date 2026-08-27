defmodule Raxol.Core.Utils.TimerUtils do
  @moduledoc """
  Consolidated timer utilities for standardized timer management across Raxol.

  Provides a unified interface for common timer patterns:
  - Periodic timers (cleanup, health checks, optimization)
  - Delayed execution timers
  - Debounced timers
  - Timer cancellation and management

  This consolidates the 84+ timer patterns found across the codebase.
  """

  @type timer_ref :: reference() | nil
  @type timer_type :: :periodic | :delayed | :debounced
  @type timer_opts :: [
          interval: pos_integer(),
          message: term(),
          debounce_key: term()
        ]

  @doc """
  Starts a periodic timer that sends messages at regular intervals.

  ## Examples

      # Health check every 30 seconds
      timer_ref = TimerUtils.start_periodic(self(), :perform_health_check, 30_000)

      # Performance monitoring every 5 seconds
      timer_ref = TimerUtils.start_periodic(self(), :monitor_performance, 5_000)
  """
  def start_periodic(pid, message, interval)
      when is_pid(pid) and interval > 0 do
    Raxol.Core.Runtime.Log.debug(
      "Starting periodic timer",
      %{pid: pid, message: message, interval: interval}
    )

    Process.send_after(pid, message, interval)
  end

  @doc """
  Starts a delayed timer that sends a message after a specified delay.

  ## Examples

      # Cleanup after 60 seconds
      timer_ref = TimerUtils.start_delayed(self(), :cleanup_timer, 60_000)

      # Flush data after 1 second
      timer_ref = TimerUtils.start_delayed(self(), :flush, 1_000)
  """
  def start_delayed(pid, message, delay) when is_pid(pid) and delay > 0 do
    Raxol.Core.Runtime.Log.debug(
      "Starting delayed timer",
      %{pid: pid, message: message, delay: delay}
    )

    Process.send_after(pid, message, delay)
  end

  @doc """
  Cancels a timer if it exists and is valid.

  ## Examples

      timer_ref = TimerUtils.start_delayed(self(), :cleanup, 5000)
      :ok = TimerUtils.cancel_timer(timer_ref)
  """
  def cancel_timer(nil), do: :ok

  def cancel_timer(timer_ref) when is_reference(timer_ref) do
    case Process.cancel_timer(timer_ref) do
      time_left when is_integer(time_left) ->
        Raxol.Core.Runtime.Log.debug(
          "Cancelled timer",
          %{timer_ref: timer_ref, time_left: time_left}
        )

        :ok

      false ->
        Raxol.Core.Runtime.Log.debug(
          "Timer already expired or invalid",
          %{timer_ref: timer_ref}
        )

        :ok
    end
  end

  def cancel_timer(_invalid), do: :ok

  @doc """
  Cancels an existing timer and starts a new one (common pattern for debouncing).

  ## Examples

      # Debounced file reload - cancel previous and start new
      timer_ref = TimerUtils.restart_timer(old_timer, self(), {:reload_file, path}, 1000)
  """
  def restart_timer(old_timer, pid, message, delay) do
    cancel_timer(old_timer)
    start_delayed(pid, message, delay)
  end

  @doc """
  Creates a debounced timer that cancels the previous timer of the same key.
  Useful for file watching, input handling, etc.

  State should have a timers map: %{timers: %{}}

  ## Examples

      # In GenServer state
      new_state = TimerUtils.debounce_timer(
        state,
        :file_reload,
        self(),
        {:reload_file, path},
        1000
      )
  """
  def debounce_timer(state, key, pid, message, delay) do
    timers = Map.get(state, :timers, %{})

    # Cancel existing timer for this key
    case Map.get(timers, key) do
      nil -> :ok
      old_timer -> cancel_timer(old_timer)
    end

    # Start new timer
    new_timer = start_delayed(pid, message, delay)
    new_timers = Map.put(timers, key, new_timer)

    Map.put(state, :timers, new_timers)
  end

  @doc """
  Cancels all timers in a state's timers map.

  ## Examples

      # In terminate/2 callback
      TimerUtils.cancel_all_timers(state)
  """
  def cancel_all_timers(%{timers: timers}) when is_map(timers) do
    timers
    |> Map.values()
    |> Enum.each(&cancel_timer/1)

    :ok
  end

  def cancel_all_timers(_state), do: :ok

  @doc """
  Standard timer intervals used across the application.
  """
  def intervals do
    %{
      # Performance and monitoring
      performance_sample: 5_000,
      health_check: 30_000,
      optimization: 30_000,

      # Cleanup and maintenance
      cleanup: 60_000,
      flush: 1_000,

      # Rendering and UI
      # ~60fps
      render_tick: 16,
      animation_frame: 16,

      # File operations
      file_debounce: 1_000,
      file_reload: 500,

      # Networking
      connection_timeout: 10_000,
      retry_delay: 5_000
    }
  end

  @doc """
  Gets a standard interval by name.

  ## Examples

      interval = TimerUtils.get_interval(:health_check)  # 30_000
      timer_ref = TimerUtils.start_periodic(self(), :health_check, interval)
  """
  def get_interval(name) do
    intervals()
    # Default to 5 seconds
    |> Map.get(name, 5_000)
  end

  @doc """
  Helper for common periodic timer patterns with state management.

  ## Examples

      # Start health check timer and update state
      new_state = TimerUtils.start_periodic_with_state(
        state,
        :health_timer,
        self(),
        :perform_health_check,
        :health_check
      )
  """
  def start_periodic_with_state(state, timer_key, pid, message, interval_name) do
    interval = get_interval(interval_name)
    timer_ref = start_periodic(pid, message, interval)

    timers = Map.get(state, :timers, %{})
    new_timers = Map.put(timers, timer_key, timer_ref)

    Map.put(state, :timers, new_timers)
  end
end
