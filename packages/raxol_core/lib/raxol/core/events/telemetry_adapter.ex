defmodule Raxol.Core.Events.TelemetryAdapter do
  @moduledoc """
  Adapter to migrate from EventManager to :telemetry.

  This module provides a compatibility layer to gradually migrate the event system
  from the custom EventManager to the standard :telemetry library.

  ## Trace Context

  All events automatically include trace context (trace_id, span_id) when available.
  Use `Raxol.Core.Telemetry.TraceContext` to start traces and spans.

  ## Example

      alias Raxol.Core.Telemetry.TraceContext

      # Start a trace for a request
      TraceContext.start_trace()

      # All events will now include trace_id
      TelemetryAdapter.dispatch(:my_event, %{value: 42})
      # => Emits event with metadata: %{trace_id: "abc123", span_id: "def456", ...}
  """

  alias Raxol.Core.Telemetry.TraceContext

  @doc """
  Dispatches an event using telemetry.

  Converts EventManager dispatch calls to telemetry execute calls.
  Automatically includes trace context when available.
  """
  def dispatch(event_name, data \\ %{})
      when is_atom(event_name) or is_tuple(event_name) do
    telemetry_event = normalize_event_name(event_name)
    measurements = extract_measurements(data)
    metadata = extract_metadata(data) |> add_trace_context()

    :telemetry.execute(telemetry_event, measurements, metadata)
    :ok
  end

  @doc """
  Registers a handler using telemetry.

  Converts EventManager handler registration to telemetry attach.
  """
  def register_handler(handler_id, event_pattern, handler_fun, config \\ []) do
    telemetry_events = pattern_to_telemetry_events(event_pattern)

    :telemetry.attach_many(
      handler_id,
      telemetry_events,
      handler_fun,
      config
    )
  end

  @doc """
  Unregisters a handler using telemetry.
  """
  def unregister_handler(handler_id) do
    :telemetry.detach(handler_id)
  end

  # Private functions

  @spec normalize_event_name(String.t() | atom()) :: any()
  defp normalize_event_name(event_name) when is_atom(event_name) do
    [:raxol, :events, event_name]
  end

  @spec normalize_event_name(any()) :: any()
  defp normalize_event_name({category, event})
       when is_atom(category) and is_atom(event) do
    [:raxol, :events, category, event]
  end

  @spec normalize_event_name(String.t() | atom()) :: any()
  defp normalize_event_name(event_name) when is_tuple(event_name) do
    [:raxol, :events | Tuple.to_list(event_name)]
  end

  @spec extract_measurements(any()) :: any()
  defp extract_measurements(%{measurements: measurements}), do: measurements
  @spec extract_measurements(any()) :: any()
  defp extract_measurements(%{value: value}), do: %{value: value}
  @spec extract_measurements(any()) :: any()
  defp extract_measurements(%{count: count}), do: %{count: count}
  @spec extract_measurements(any()) :: any()
  defp extract_measurements(%{duration: duration}), do: %{duration: duration}
  @spec extract_measurements(any()) :: any()
  defp extract_measurements(_), do: %{}

  @spec extract_metadata(any()) :: any()
  defp extract_metadata(%{metadata: metadata}), do: metadata

  @spec extract_metadata(any()) :: any()
  defp extract_metadata(data) when is_map(data) do
    data
    |> Map.delete(:measurements)
    |> Map.delete(:value)
    |> Map.delete(:count)
    |> Map.delete(:duration)
  end

  @spec extract_metadata(any()) :: any()
  defp extract_metadata(_), do: %{}

  @spec pattern_to_telemetry_events(any()) :: any()
  defp pattern_to_telemetry_events(:all), do: [[:raxol, :events, :_]]

  @spec pattern_to_telemetry_events(any()) :: any()
  defp pattern_to_telemetry_events(pattern) when is_atom(pattern) do
    [[:raxol, :events, pattern]]
  end

  @spec pattern_to_telemetry_events(any()) :: any()
  defp pattern_to_telemetry_events(patterns) when is_list(patterns) do
    Enum.map(patterns, fn pattern ->
      [:raxol, :events | List.wrap(pattern)]
    end)
  end

  @spec pattern_to_telemetry_events(any()) :: any()
  defp pattern_to_telemetry_events(pattern), do: [[:raxol, :events, pattern]]

  @spec add_trace_context(map()) :: map()
  defp add_trace_context(metadata) when is_map(metadata) do
    case TraceContext.current() do
      %{trace_id: nil} ->
        metadata

      %{
        trace_id: trace_id,
        span_id: span_id,
        parent_span_id: parent_span_id,
        causation_id: causation_id
      } ->
        metadata
        |> Map.put(:trace_id, trace_id)
        |> Map.put(:span_id, span_id)
        |> maybe_put_parent_span(parent_span_id)
        |> maybe_put_causation(causation_id)
    end
  end

  defp maybe_put_causation(metadata, nil), do: metadata

  defp maybe_put_causation(metadata, id),
    do: Map.put(metadata, :causation_id, id)

  @spec maybe_put_parent_span(
          %{
            :span_id => nil | binary(),
            :trace_id => binary(),
            optional(any()) => any()
          },
          binary() | nil
        ) :: %{
          :span_id => nil | binary(),
          :trace_id => binary(),
          optional(any()) => any()
        }
  defp maybe_put_parent_span(metadata, nil), do: metadata

  defp maybe_put_parent_span(metadata, parent),
    do: Map.put(metadata, :parent_span_id, parent)
end
