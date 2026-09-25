defmodule Raxol.Performance.DevHints do
  @moduledoc """
  Performance hints system for development mode.

  Monitors telemetry events and provides actionable performance hints
  when operations are slower than expected or patterns indicate
  potential optimization opportunities.

  ## Features

  - Real-time performance monitoring
  - Actionable optimization hints
  - Pattern detection for common performance issues
  - Configurable thresholds
  - Integration with existing telemetry infrastructure

  ## Usage

  Automatically starts in development mode when telemetry is enabled.
  Hints are logged to the console with suggestions for optimization.

  ## Configuration

      config :raxol, Raxol.Performance.DevHints,
        enabled: Mix.env() == :dev,
        thresholds: %{
          terminal_parse: 100,  # microseconds
          buffer_write: 50,
          render_frame: 1000
        },
        hint_cooldown: 30_000  # milliseconds between same hints
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Core.Runtime.Log

  @mix_env Mix.env()

  @default_config %{
    enabled: @mix_env == :dev,
    thresholds: %{
      # Terminal operations (microseconds)
      terminal_parse: 100,
      terminal_write: 50,
      terminal_scroll: 200,
      terminal_clear: 100,

      # Buffer operations
      buffer_write: 50,
      buffer_read: 25,
      buffer_resize: 500,
      buffer_scroll: 100,

      # Rendering operations
      render_frame: 1000,
      render_component: 200,
      render_text: 100,

      # Network operations
      network_request: 5000,
      ssh_command: 2000,

      # Plugin operations
      plugin_load: 1000,
      plugin_execute: 500
    },
    # 30 seconds between same hints
    hint_cooldown: 30_000,
    max_hints_per_minute: 10,
    enable_pattern_detection: true
  }

  defstruct [
    :config,
    :recent_hints,
    :hint_counts,
    :operation_history,
    :pattern_detector,
    :start_time
  ]

  # Client API

  @doc """
  Starts the server, registered under its module name unless `:name` is
  given: the public API calls it by that name.
  """
  def start_link(opts \\ []) do
    opts |> Keyword.put_new(:name, __MODULE__) |> super()
  end

  @doc """
  Manually trigger a performance hint.
  """
  def hint(category, message, metadata \\ %{}) do
    if enabled?() do
      GenServer.cast(__MODULE__, {:manual_hint, category, message, metadata})
    end
  end

  @doc """
  Check if hints are enabled.
  """
  def enabled? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      _pid -> true
    end
  end

  @doc """
  Get current performance statistics.
  """
  def stats do
    if enabled?() do
      GenServer.call(__MODULE__, :stats)
    else
      %{enabled: false}
    end
  end

  # Server Implementation

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    config = get_config(opts)

    if config.enabled do
      Log.info("Attaching telemetry handlers")

      # Schedule periodic cleanup
      _ = :timer.send_interval(60_000, self(), {:cleanup_history})

      # Attach to telemetry events
      events = [
        [:raxol, :terminal, :parse],
        [:raxol, :terminal, :write],
        [:raxol, :terminal, :scroll],
        [:raxol, :terminal, :clear],
        [:raxol, :buffer, :write],
        [:raxol, :buffer, :read],
        [:raxol, :buffer, :resize],
        [:raxol, :buffer, :scroll],
        [:raxol, :render, :frame],
        [:raxol, :render, :component],
        [:raxol, :render, :text],
        [:raxol, :network, :request],
        [:raxol, :ssh, :command],
        [:raxol, :plugin, :load],
        [:raxol, :plugin, :execute]
      ]

      _ =
        :telemetry.attach_many(
          "raxol-dev-hints",
          events,
          &handle_telemetry_event/4,
          self()
        )

      state = %__MODULE__{
        config: config,
        recent_hints: %{},
        hint_counts: %{},
        operation_history: [],
        pattern_detector: init_pattern_detector(),
        start_time: System.monotonic_time(:millisecond)
      }

      Log.info("Performance hints enabled for development")

      {:ok, state}
    else
      :ignore
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:manual_hint, category, message, metadata}, state) do
    state = maybe_show_hint(state, category, message, metadata)
    {:noreply, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast(
        {:telemetry_event, event, measurements, metadata},
        state
      ) do
    state = record_operation(state, event, measurements, metadata)
    state = check_for_hints(state, event, measurements, metadata)

    {:noreply, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:stats, _from, state) do
    now = System.monotonic_time(:millisecond)
    uptime = now - state.start_time

    stats = %{
      enabled: true,
      uptime_ms: uptime,
      total_hints: Map.values(state.hint_counts) |> Enum.sum(),
      hint_categories: state.hint_counts,
      recent_operations: length(state.operation_history),
      config: state.config
    }

    {:reply, stats, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:cleanup_history}, state) do
    # Clean up old operation history
    # 1 minute ago
    cutoff = System.monotonic_time(:millisecond) - 60_000

    new_history =
      Enum.filter(state.operation_history, fn {timestamp, _} ->
        timestamp > cutoff
      end)

    # Schedule next cleanup
    Process.send_after(
      self(),
      {:cleanup_history},
      Raxol.Core.Defaults.cleanup_interval_ms()
    )

    {:noreply, %{state | operation_history: new_history}}
  end

  # Telemetry Event Handler

  def handle_telemetry_event(event, measurements, metadata, pid) do
    GenServer.cast(pid, {:telemetry_event, event, measurements, metadata})
  end

  # Private Functions

  defp get_config(opts) do
    app_config = Application.get_env(:raxol, __MODULE__, %{})

    @default_config
    |> Map.merge(app_config)
    |> Map.merge(Enum.into(opts, %{}))
  end

  defp record_operation(state, event, measurements, metadata) do
    timestamp = System.monotonic_time(:millisecond)

    operation =
      {timestamp,
       %{event: event, measurements: measurements, metadata: metadata}}

    new_history =
      [operation | state.operation_history]
      # Keep last 1000 operations
      |> Enum.take(1000)

    %{state | operation_history: new_history}
  end

  defp check_for_hints(state, event, measurements, metadata) do
    operation_key = event_to_operation_key(event)
    duration = Map.get(measurements, :duration, 0)
    threshold = get_threshold(state.config, operation_key)

    cond do
      # Check for slow operations
      duration > threshold ->
        hint_message =
          generate_slow_operation_hint(
            operation_key,
            duration,
            threshold,
            metadata
          )

        maybe_show_hint(state, :slow_operation, hint_message, %{
          operation: operation_key,
          duration: duration,
          threshold: threshold,
          metadata: metadata
        })

      # Check for error patterns
      Map.get(measurements, :error, false) ->
        hint_message = generate_error_hint(operation_key, metadata)

        maybe_show_hint(state, :error_pattern, hint_message, %{
          operation: operation_key,
          metadata: metadata
        })

      # Check for pattern-based hints
      state.config.enable_pattern_detection ->
        check_patterns(state, event, measurements, metadata)

      true ->
        state
    end
  end

  defp maybe_show_hint(state, category, message, metadata) do
    hint_key = {category, hash_hint_content(message, metadata)}
    now = System.monotonic_time(:millisecond)

    # Check cooldown
    last_shown = Map.get(state.recent_hints, hint_key, 0)
    cooldown_passed = now - last_shown > state.config.hint_cooldown

    # Check rate limiting
    current_minute = div(now, 60_000)
    minute_key = {category, current_minute}
    minute_count = Map.get(state.hint_counts, minute_key, 0)
    under_rate_limit = minute_count < state.config.max_hints_per_minute

    if cooldown_passed and under_rate_limit do
      show_hint(category, message, metadata)

      new_recent_hints = Map.put(state.recent_hints, hint_key, now)
      new_hint_counts = Map.update(state.hint_counts, minute_key, 1, &(&1 + 1))

      %{state | recent_hints: new_recent_hints, hint_counts: new_hint_counts}
    else
      state
    end
  end

  defp show_hint(category, message, metadata) do
    category_emoji =
      case category do
        :slow_operation -> "[SLOW]"
        :error_pattern -> "[FAIL]"
        :memory_usage -> "[BRAIN]"
        :pattern_detected -> "[SEARCH]"
        :optimization -> "[POWER]"
        _ -> "[TIP]"
      end

    Log.warning([
      IO.ANSI.yellow(),
      category_emoji,
      " Performance Hint [#{category}]: ",
      IO.ANSI.white(),
      message,
      IO.ANSI.reset()
    ])

    if map_size(metadata) > 0 do
      Log.debug("Hint metadata: #{inspect(metadata)}")
    end
  end

  defp generate_slow_operation_hint(operation, duration, threshold, _metadata) do
    duration_ms = duration / 1000
    threshold_ms = threshold / 1000
    slowdown = Float.round(duration / threshold, 1)

    base_message =
      "#{operation} took #{duration_ms}ms (#{slowdown}x slower than #{threshold_ms}ms threshold)"

    suggestion =
      case operation do
        :terminal_parse ->
          "Consider batching ANSI sequences or using a more efficient parser state machine."

        :buffer_write ->
          "Frequent buffer writes detected. Consider batching writes or using double buffering."

        :render_frame ->
          "Frame rendering is slow. Check if unnecessary re-renders are happening or consider dirty region tracking."

        :network_request ->
          "Network request is slow. Consider connection pooling, caching, or async operations."

        :plugin_load ->
          "Plugin loading is slow. Consider lazy loading or plugin precompilation."

        _ ->
          "Consider profiling this operation to identify bottlenecks."
      end

    "#{base_message} #{suggestion}"
  end

  defp generate_error_hint(operation, metadata) do
    error_kind = Map.get(metadata, :error_kind, "unknown")

    base_message = "Errors detected in #{operation} (#{error_kind})"

    suggestion =
      case operation do
        :network_request ->
          "Consider implementing retry logic, circuit breakers, or connection pooling."

        :terminal_parse ->
          "Invalid ANSI sequences detected. Consider input validation or error recovery."

        :plugin_execute ->
          "Plugin execution errors. Check plugin compatibility and error handling."

        _ ->
          "Frequent errors may indicate a need for better error handling or input validation."
      end

    "#{base_message}. #{suggestion}"
  end

  defp check_patterns(state, event, _measurements, _metadata) do
    # Pattern detection for common performance issues
    recent_ops = Enum.take(state.operation_history, 10)

    cond do
      # Detect rapid repeated operations
      detect_rapid_repeats(recent_ops, event) ->
        maybe_show_hint(
          state,
          :pattern_detected,
          "Rapid repeated #{event_to_operation_key(event)} operations detected. Consider batching or debouncing.",
          %{pattern: :rapid_repeats, event: event}
        )

      # Detect memory pressure patterns
      detect_memory_pressure(recent_ops) ->
        maybe_show_hint(
          state,
          :memory_usage,
          "Memory pressure detected. Consider implementing memory pooling or garbage collection optimization.",
          %{pattern: :memory_pressure}
        )

      true ->
        state
    end
  end

  defp detect_rapid_repeats(recent_ops, target_event) do
    matching_ops =
      Enum.count(recent_ops, fn {_timestamp, %{event: event}} ->
        event == target_event
      end)

    # 5 or more of the same operation in last 10
    matching_ops >= 5
  end

  defp detect_memory_pressure(recent_ops) do
    # Simple heuristic: many buffer operations with large data
    buffer_ops =
      Enum.count(recent_ops, fn {_timestamp,
                                 %{event: event, metadata: metadata}} ->
        String.contains?(to_string(event), "buffer") and
          Map.get(metadata, :data_size, 0) > 1000
      end)

    buffer_ops >= 3
  end

  defp event_to_operation_key(event) when is_list(event) do
    event
    # Remove :raxol prefix
    |> Enum.drop(1)
    |> Enum.join("_")
    |> String.to_atom()
  end

  defp get_threshold(config, operation_key) do
    # Default 1ms
    Map.get(config.thresholds, operation_key, 1000)
  end

  defp hash_hint_content(message, metadata) do
    content = "#{message}#{inspect(metadata)}"
    :crypto.hash(:sha256, content) |> Base.encode16() |> String.slice(0, 8)
  end

  defp init_pattern_detector do
    %{
      operation_windows: %{},
      memory_samples: [],
      error_patterns: %{}
    }
  end
end
