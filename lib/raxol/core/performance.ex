defmodule Raxol.Core.Performance do
  @moduledoc """
  Performance monitoring facade for Raxol.Core.

  Provides a simple interface for performance initialization and statistics
  gathering. This module serves as the entry point for performance monitoring
  used by the Core module.

  For detailed performance analysis, see the modules in `Raxol.Performance.*`:
  - `Raxol.Performance.Profiler` - Detailed profiling
  - `Raxol.Performance.MetricsCollector` - Metrics collection
  - `Raxol.Performance.Analyzer` - Performance analysis
  - `Raxol.Performance.JankDetector` - Frame timing issues
  """

  @table __MODULE__

  @typedoc "Performance statistics map"
  @type stats :: %{
          uptime_ms: number(),
          frame_count: non_neg_integer(),
          avg_frame_time_ms: float(),
          fps: float(),
          memory_mb: float(),
          samples: non_neg_integer(),
          initialized: boolean()
        }

  @doc """
  Initializes the performance monitoring system.

  ## Options

  - `:enabled` - Whether to enable performance monitoring (default: true)
  - `:max_samples` - Maximum number of samples to keep (default: 100)

  ## Returns

  - `:ok` on success
  """
  @spec init(keyword()) :: :ok
  def init(options \\ []) do
    # Create ETS table if it doesn't exist
    _ =
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      end

    :ets.insert(@table, {:start_time, System.monotonic_time(:millisecond)})
    :ets.insert(@table, {:max_samples, Keyword.get(options, :max_samples, 100)})
    :ets.insert(@table, {:frame_count, 0})
    :ets.insert(@table, {:total_render_time, 0})
    :ets.insert(@table, {:samples, []})

    :ok
  end

  @doc """
  Gets current performance statistics.

  ## Returns

  - `{:ok, stats}` where stats is a map containing:
    - `:uptime_ms` - Time since initialization in milliseconds
    - `:frame_count` - Total frames rendered
    - `:avg_frame_time_ms` - Average frame render time
    - `:fps` - Estimated frames per second
    - `:memory_mb` - Current memory usage in MB
  """
  @spec get_stats() :: {:ok, stats()}
  def get_stats do
    stats =
      if :ets.whereis(@table) != :undefined do
        calculate_stats()
      else
        default_stats()
      end

    {:ok, stats}
  end

  @doc """
  Records a frame render event.

  ## Parameters

  - `render_time_us` - Render time in microseconds
  """
  @spec record_frame(non_neg_integer()) :: :ok
  def record_frame(render_time_us) do
    if :ets.whereis(@table) != :undefined do
      render_time_ms = render_time_us / 1000

      # Update frame count
      :ets.update_counter(@table, :frame_count, 1, {:frame_count, 0})

      # Update total render time
      current_total = get_value(:total_render_time, 0)
      :ets.insert(@table, {:total_render_time, current_total + render_time_ms})

      # Update samples (keep last N)
      max_samples = get_value(:max_samples, 100)
      samples = get_value(:samples, [])

      new_samples =
        [render_time_ms | samples]
        |> Enum.take(max_samples)

      :ets.insert(@table, {:samples, new_samples})
    end

    :ok
  end

  @doc """
  Resets performance statistics.
  """
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {:start_time, System.monotonic_time(:millisecond)})
      :ets.insert(@table, {:frame_count, 0})
      :ets.insert(@table, {:total_render_time, 0})
      :ets.insert(@table, {:samples, []})
    end

    :ok
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp get_value(key, default) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  defp calculate_stats do
    now = System.monotonic_time(:millisecond)
    start_time = get_value(:start_time, now)
    uptime_ms = now - start_time
    frame_count = get_value(:frame_count, 0)
    total_render_time = get_value(:total_render_time, 0)

    avg_frame_time =
      if frame_count > 0 do
        total_render_time / frame_count
      else
        0.0
      end

    fps =
      if uptime_ms > 0 do
        frame_count / (uptime_ms / 1000)
      else
        0.0
      end

    memory_info = :erlang.memory()
    memory_mb = memory_info[:total] / (1024 * 1024)

    %{
      uptime_ms: uptime_ms,
      frame_count: frame_count,
      avg_frame_time_ms: Float.round(avg_frame_time, 2),
      fps: Float.round(fps, 1),
      memory_mb: Float.round(memory_mb, 2),
      samples: length(get_value(:samples, [])),
      initialized: true
    }
  end

  defp default_stats do
    memory_info = :erlang.memory()
    memory_mb = memory_info[:total] / (1024 * 1024)

    %{
      uptime_ms: 0,
      frame_count: 0,
      avg_frame_time_ms: 0.0,
      fps: 0.0,
      memory_mb: Float.round(memory_mb, 2),
      samples: 0,
      initialized: false
    }
  end
end
