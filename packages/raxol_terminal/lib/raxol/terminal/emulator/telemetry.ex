defmodule Raxol.Terminal.Emulator.Telemetry do
  alias Raxol.Core.Runtime.Log
  alias Raxol.Core.Telemetry.TraceContext, as: Context

  @moduledoc """
  Telemetry instrumentation for the terminal emulator.

  Provides comprehensive error tracking and performance monitoring
  for terminal emulation operations.

  All events include trace_id and span_id for request correlation.
  Use `Raxol.Core.Telemetry.TraceContext` to manage trace context.
  """
  @emulator_events [
    [:raxol, :emulator, :input, :start],
    [:raxol, :emulator, :input, :stop],
    [:raxol, :emulator, :input, :exception],
    [:raxol, :emulator, :sequence, :start],
    [:raxol, :emulator, :sequence, :stop],
    [:raxol, :emulator, :sequence, :exception],
    [:raxol, :emulator, :resize, :start],
    [:raxol, :emulator, :resize, :stop],
    [:raxol, :emulator, :resize, :exception],
    [:raxol, :emulator, :error, :recorded],
    [:raxol, :emulator, :recovery, :attempted],
    [:raxol, :emulator, :recovery, :succeeded],
    [:raxol, :emulator, :recovery, :failed],
    [:raxol, :emulator, :health, :check],
    [:raxol, :emulator, :checkpoint, :created],
    [:raxol, :emulator, :checkpoint, :restored]
  ]

  @doc """
  Lists all emulator telemetry events.
  """
  def events, do: @emulator_events

  @doc """
  Attaches default telemetry handlers for logging.
  """
  def attach_default_handlers do
    handlers = [
      {[:raxol, :emulator, :input, :exception], &handle_input_exception/4},
      {[:raxol, :emulator, :sequence, :exception], &handle_sequence_exception/4},
      {[:raxol, :emulator, :resize, :exception], &handle_resize_exception/4},
      {[:raxol, :emulator, :error, :recorded], &handle_error_recorded/4},
      {[:raxol, :emulator, :recovery, :failed], &handle_recovery_failed/4},
      {[:raxol, :emulator, :health, :check], &handle_health_check/4}
    ]

    Enum.each(handlers, fn {event, handler} ->
      handler_id = "#{__MODULE__}-#{Enum.join(event, "-")}"

      :telemetry.attach(
        handler_id,
        event,
        handler,
        nil
      )
    end)
  end

  @doc """
  Executes a function with telemetry instrumentation.

  Automatically includes trace_id and span_id for request correlation.
  """
  def span(event_prefix, metadata, fun) do
    # Use Context.span for automatic trace context injection
    Context.span(event_prefix, metadata, fun)
  end

  @doc """
  Records an error event with trace context.
  """
  def record_error(error_type, reason, metadata \\ %{}) do
    Context.execute(
      [:raxol, :emulator, :error, :recorded],
      %{count: 1},
      Map.merge(metadata, %{
        error_type: error_type,
        reason: reason,
        timestamp: DateTime.utc_now()
      })
    )
  end

  @doc """
  Records a recovery attempt with trace context.
  """
  def record_recovery_attempt(metadata \\ %{}) do
    Context.execute(
      [:raxol, :emulator, :recovery, :attempted],
      %{count: 1},
      Map.put(metadata, :timestamp, DateTime.utc_now())
    )
  end

  @doc """
  Records a successful recovery with trace context.
  """
  def record_recovery_success(metadata \\ %{}) do
    Context.execute(
      [:raxol, :emulator, :recovery, :succeeded],
      %{count: 1},
      Map.put(metadata, :timestamp, DateTime.utc_now())
    )
  end

  @doc """
  Records a failed recovery with trace context.
  """
  def record_recovery_failure(reason, metadata \\ %{}) do
    Context.execute(
      [:raxol, :emulator, :recovery, :failed],
      %{count: 1},
      Map.merge(metadata, %{
        reason: reason,
        timestamp: DateTime.utc_now()
      })
    )
  end

  @doc """
  Records a health check with trace context.
  """
  def record_health_check(status, metadata \\ %{}) do
    Context.execute(
      [:raxol, :emulator, :health, :check],
      %{status: status_to_number(status)},
      Map.merge(metadata, %{
        status: status,
        timestamp: DateTime.utc_now()
      })
    )
  end

  @doc """
  Records checkpoint creation with trace context.
  """
  def record_checkpoint_created(metadata \\ %{}) do
    Context.execute(
      [:raxol, :emulator, :checkpoint, :created],
      %{count: 1},
      Map.put(metadata, :timestamp, DateTime.utc_now())
    )
  end

  @doc """
  Records checkpoint restoration with trace context.
  """
  def record_checkpoint_restored(metadata \\ %{}) do
    Context.execute(
      [:raxol, :emulator, :checkpoint, :restored],
      %{count: 1},
      Map.put(metadata, :timestamp, DateTime.utc_now())
    )
  end

  # Private handler functions

  defp handle_input_exception(_event, measurements, metadata, _config) do
    Log.error("""
    Emulator input processing exception:
      Trace: #{format_trace(metadata)}
      Duration: #{format_duration(measurements[:duration])}
      Exception: #{inspect(metadata[:exception])}
      Metadata: #{inspect(Map.drop(metadata, [:exception, :stacktrace, :trace_id, :span_id, :parent_span_id]))}
    """)
  end

  defp handle_sequence_exception(_event, measurements, metadata, _config) do
    Log.error("""
    Emulator sequence handling exception:
      Trace: #{format_trace(metadata)}
      Duration: #{format_duration(measurements[:duration])}
      Exception: #{inspect(metadata[:exception])}
      Sequence: #{inspect(metadata[:sequence])}
    """)
  end

  defp handle_resize_exception(_event, measurements, metadata, _config) do
    Log.error("""
    Emulator resize exception:
      Trace: #{format_trace(metadata)}
      Duration: #{format_duration(measurements[:duration])}
      Exception: #{inspect(metadata[:exception])}
      Dimensions: #{metadata[:width]}x#{metadata[:height]}
    """)
  end

  defp handle_error_recorded(_event, _measurements, metadata, _config) do
    Log.warning("""
    Emulator error recorded:
      Trace: #{format_trace(metadata)}
      Type: #{metadata[:error_type]}
      Reason: #{inspect(metadata[:reason])}
      Timestamp: #{metadata[:timestamp]}
    """)
  end

  defp handle_recovery_failed(_event, _measurements, metadata, _config) do
    Log.error("""
    Emulator recovery failed:
      Trace: #{format_trace(metadata)}
      Reason: #{inspect(metadata[:reason])}
      Timestamp: #{metadata[:timestamp]}
    """)
  end

  defp handle_health_check(_event, measurements, metadata, _config) do
    log_health_check(metadata[:status], measurements, metadata)
  end

  defp format_duration(nil), do: "N/A"

  defp format_duration(duration) when is_integer(duration) do
    "#{System.convert_time_unit(duration, :native, :microsecond)} us"
  end

  defp format_trace(metadata) do
    trace_id = Map.get(metadata, :trace_id, "none")
    span_id = Map.get(metadata, :span_id, "none")
    "#{trace_id}/#{span_id}"
  end

  defp status_to_number(:healthy), do: 0
  defp status_to_number(:degraded), do: 1
  defp status_to_number(:critical), do: 2
  defp status_to_number(:fallback), do: 3
  defp status_to_number(_), do: -1

  # Helper function for pattern matching instead of if statement
  defp log_health_check(:healthy, _measurements, _metadata), do: :ok

  defp log_health_check(status, measurements, _metadata) do
    Log.info("""
    Emulator health check:
      Status: #{status}
      Value: #{measurements[:status]}
    """)
  end
end
