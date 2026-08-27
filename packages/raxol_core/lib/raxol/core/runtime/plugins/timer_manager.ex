defmodule Raxol.Core.Runtime.Plugins.TimerManager do
  @moduledoc """
  Handles timer management for plugin operations including periodic ticks and file event timers.

  This module has been enhanced to use the centralized TimerManager for consistent
  timer handling across the plugin system.
  """

  alias Raxol.Core.Utils.TimerManager

  @doc """
  Cancels an existing timer using the centralized TimerManager.
  """
  @spec cancel_existing_timer(map()) :: map()
  def cancel_existing_timer(state) do
    case state.file_event_timer do
      nil ->
        state

      timer_ref ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Cancelling existing file event timer",
          %{timer_ref: timer_ref}
        )

        TimerManager.safe_cancel(timer_ref)
        %{state | file_event_timer: nil}
    end
  end

  @doc """
  Cancels a periodic tick timer using the centralized TimerManager.
  """
  @spec cancel_periodic_tick(map()) :: {:ok, map()}
  def cancel_periodic_tick(state) do
    case state.tick_timer do
      nil ->
        {:ok, state}

      timer_ref ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Cancelling periodic tick timer",
          %{timer_ref: timer_ref}
        )

        TimerManager.safe_cancel(timer_ref)
        {:ok, %{state | tick_timer: nil}}
    end
  end

  @doc """
  Starts a periodic tick timer using the centralized TimerManager.
  """
  @spec start_periodic_tick(map(), pos_integer()) :: map()
  def start_periodic_tick(state, interval \\ 5000) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Starting periodic tick timer",
      %{interval: interval}
    )

    timer_ref = TimerManager.send_after(:tick, interval)
    %{state | tick_timer: timer_ref}
  end

  @doc """
  Schedules a file event timer using the centralized TimerManager.
  """
  @spec schedule_file_event_timer(map(), atom(), String.t(), pos_integer()) ::
          map()
  def schedule_file_event_timer(state, plugin_id, path, interval \\ 1000) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Scheduling file event timer",
      %{plugin_id: plugin_id, path: path, interval: interval}
    )

    # Cancel existing timer first
    new_state = cancel_existing_timer(state)

    # Schedule new timer using TimerManager
    timer_ref =
      TimerManager.send_after(
        {:reload_plugin_file_debounced, plugin_id, path},
        interval
      )

    %{new_state | file_event_timer: timer_ref}
  end
end
