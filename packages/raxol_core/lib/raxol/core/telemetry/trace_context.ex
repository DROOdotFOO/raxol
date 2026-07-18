defmodule Raxol.Core.Telemetry.TraceContext do
  @moduledoc """
  Trace context management for request correlation across telemetry events.

  Provides trace_id and span_id generation and propagation for debugging
  and observability. Trace context flows through the process dictionary
  for automatic inclusion in telemetry events.

  ## Usage

      # Start a new trace for a request/operation
      TraceContext.start_trace()

      # Or with a custom trace_id (for distributed tracing)
      TraceContext.start_trace(trace_id: "abc123")

      # Start a child span within a trace
      TraceContext.start_span("render_component")

      # Get current context for logging/telemetry
      ctx = TraceContext.current()
      # => %{trace_id: "abc123", span_id: "def456", parent_span_id: nil}

      # End the current span
      TraceContext.end_span()

  ## Process Dictionary Keys

  - `:raxol_trace_id` - Current trace identifier
  - `:raxol_span_id` - Current span identifier
  - `:raxol_parent_span_id` - Parent span for nested operations
  - `:raxol_span_stack` - Stack of span IDs for nesting
  - `:raxol_causation_id` - Id of the event/span that caused the current work

  ## Causation vs parent span

  `parent_span_id` reflects synchronous nesting (a span starts inside
  another). `causation_id` reflects asynchronous handoff (an event
  caused this work to happen, possibly across processes or messages).
  Both can hold values simultaneously and serve different debugging
  needs.

  ## Integration

  The TelemetryAdapter automatically includes trace context in all events
  when available. No manual instrumentation needed for basic tracing.
  """

  @type trace_id :: String.t()
  @type span_id :: String.t()
  @type causation_id :: String.t()

  @type context :: %{
          trace_id: trace_id() | nil,
          span_id: span_id() | nil,
          parent_span_id: span_id() | nil,
          causation_id: causation_id() | nil
        }

  @doc """
  Starts a new trace, optionally with a provided trace_id.

  ## Options

    * `:trace_id` - Use existing trace_id (for distributed tracing)
    * `:span_name` - Name for the root span (default: "root")

  ## Examples

      TraceContext.start_trace()
      TraceContext.start_trace(trace_id: "external-123")
  """
  @spec start_trace(keyword()) :: context()
  def start_trace(opts \\ []) do
    trace_id = Keyword.get(opts, :trace_id, generate_id())
    span_id = generate_id()

    Process.put(:raxol_trace_id, trace_id)
    Process.put(:raxol_span_id, span_id)
    Process.put(:raxol_parent_span_id, nil)
    Process.put(:raxol_span_stack, [])

    current()
  end

  @doc """
  Starts a child span within the current trace.

  Returns the new context with the child span active.
  The parent span is preserved on a stack for proper nesting.

  ## Examples

      TraceContext.start_span("database_query")
      # ... do work ...
      TraceContext.end_span()
  """
  @spec start_span(String.t()) :: context()
  def start_span(name) when is_binary(name) do
    current_span = Process.get(:raxol_span_id)
    span_stack = Process.get(:raxol_span_stack, [])
    new_span_id = generate_id()

    # Push current span onto stack
    if current_span do
      Process.put(:raxol_span_stack, [current_span | span_stack])
    end

    Process.put(:raxol_span_id, new_span_id)
    Process.put(:raxol_parent_span_id, current_span)

    current()
  end

  @doc """
  Ends the current span and restores the parent span.
  """
  @spec end_span() :: context()
  def end_span do
    span_stack = Process.get(:raxol_span_stack, [])

    case span_stack do
      [parent | rest] ->
        Process.put(:raxol_span_id, parent)
        Process.put(:raxol_span_stack, rest)

        # Get grandparent from remaining stack
        grandparent =
          case rest do
            [gp | _] -> gp
            [] -> nil
          end

        Process.put(:raxol_parent_span_id, grandparent)

      [] ->
        # No parent, clear span but keep trace
        Process.put(:raxol_parent_span_id, Process.get(:raxol_span_id))
    end

    current()
  end

  @doc """
  Returns the current trace context, or empty context if none active.

  ## Examples

      ctx = TraceContext.current()
      %{trace_id: "abc", span_id: "def", parent_span_id: nil}
  """
  @spec current() :: context()
  def current do
    %{
      trace_id: Process.get(:raxol_trace_id),
      span_id: Process.get(:raxol_span_id),
      parent_span_id: Process.get(:raxol_parent_span_id),
      causation_id: Process.get(:raxol_causation_id)
    }
  end

  @doc """
  Sets the causation id for the current process.

  Use this when handing work off across messages or processes: the
  sender's `span_id` becomes the receiver's `causation_id`, forming a
  chain independent of synchronous span nesting.

  Passing `nil` clears the causation id.
  """
  @spec set_causation(causation_id() | nil) :: context()
  def set_causation(nil) do
    Process.delete(:raxol_causation_id)
    current()
  end

  def set_causation(id) when is_binary(id) do
    Process.put(:raxol_causation_id, id)
    current()
  end

  @doc """
  Clears the current trace context.

  Call this when a request/operation completes to clean up.
  """
  @spec clear() :: :ok
  def clear do
    Process.delete(:raxol_trace_id)
    Process.delete(:raxol_span_id)
    Process.delete(:raxol_parent_span_id)
    Process.delete(:raxol_span_stack)
    Process.delete(:raxol_causation_id)
    :ok
  end

  @doc """
  Checks if there is an active trace context.
  """
  @spec active?() :: boolean()
  def active? do
    Process.get(:raxol_trace_id) != nil
  end

  @doc """
  Executes a function within a new span.

  Automatically starts the span before execution and ends it after,
  even if the function raises an exception.

  ## Examples

      result = TraceContext.with_span("render", fn ->
        render_component()
      end)
  """
  @spec with_span(String.t(), (-> result)) :: result when result: term()
  def with_span(name, fun) when is_binary(name) and is_function(fun, 0) do
    _ = start_span(name)

    try do
      fun.()
    after
      _ = end_span()
    end
  end

  @doc """
  Executes a function within a new trace.

  Creates a new trace context, executes the function, and clears
  the context after completion.

  ## Examples

      result = TraceContext.with_trace(fn ->
        # All telemetry events here will have trace_id
        process_request()
      end)
  """
  @spec with_trace((-> result)) :: result when result: term()
  def with_trace(fun) when is_function(fun, 0) do
    _ = start_trace()

    try do
      fun.()
    after
      _ = clear()
    end
  end

  @doc """
  Formats the current context as a string for logging.

  ## Examples

      TraceContext.format()
      # => "[trace:abc123 span:def456]"
  """
  @spec format() :: String.t()
  def format do
    case current() do
      %{trace_id: nil} ->
        ""

      %{trace_id: trace_id, span_id: span_id} when is_binary(trace_id) ->
        trace_short = String.slice(trace_id, 0..7)
        span_short = if span_id, do: String.slice(span_id, 0..7), else: "none"
        "[trace:#{trace_short} span:#{span_short}]"
    end
  end

  @doc """
  Returns context as a map suitable for HTTP headers or metadata.

  ## Examples

      headers = TraceContext.to_headers()
      # => %{"x-trace-id" => "abc123", "x-span-id" => "def456"}
  """
  @spec to_headers() :: %{optional(String.t()) => String.t()}
  def to_headers do
    ctx = current()

    %{}
    |> maybe_put("x-trace-id", ctx.trace_id)
    |> maybe_put("x-span-id", ctx.span_id)
    |> maybe_put("x-parent-span-id", ctx.parent_span_id)
    |> maybe_put("x-causation-id", ctx.causation_id)
  end

  @doc """
  Creates context from HTTP headers (for distributed tracing).

  ## Examples

      TraceContext.from_headers(%{"x-trace-id" => "abc123"})
  """
  @spec from_headers(map()) :: context()
  def from_headers(headers) when is_map(headers) do
    trace_id = Map.get(headers, "x-trace-id")
    parent_span_id = Map.get(headers, "x-span-id")
    causation_id = Map.get(headers, "x-causation-id")

    _ =
      if trace_id do
        _ = start_trace(trace_id: trace_id)

        if parent_span_id do
          Process.put(:raxol_parent_span_id, parent_span_id)
        end

        if causation_id do
          Process.put(:raxol_causation_id, causation_id)
        end
      end

    current()
  end

  @doc """
  Converts the current context to telemetry metadata.

  Returns `extra` unchanged when no trace is active; otherwise merges
  `trace_id`/`span_id`/`parent_span_id` into it.

  ## Examples

      metadata = TraceContext.to_metadata(%{component: :button})
      :telemetry.execute([:raxol, :render], measurements, metadata)
  """
  @spec to_metadata(map()) :: map()
  def to_metadata(extra \\ %{}) do
    case current() do
      %{trace_id: nil} ->
        extra

      ctx ->
        Map.merge(extra, %{
          trace_id: ctx.trace_id,
          span_id: ctx.span_id,
          parent_span_id: ctx.parent_span_id
        })
    end
  end

  @doc """
  Executes a telemetry event with the current trace context injected
  into its metadata.

  ## Examples

      TraceContext.execute([:raxol, :render, :stop], %{duration: 1234}, %{component: :button})
  """
  @spec execute([atom()], map(), map()) :: :ok
  def execute(event, measurements, metadata \\ %{}) when is_list(event) do
    :telemetry.execute(event, measurements, to_metadata(metadata))
  end

  @doc """
  Wraps a function with telemetry span instrumentation.

  Emits `event_prefix ++ [:start]`, then `[:stop]` on success or
  `[:exception]` on failure (re-raising), each carrying the current
  trace context. The span is started before the function and ended
  after, even on exception.

  ## Examples

      result = TraceContext.span([:raxol, :render], %{component: :button}, fn ->
        render_component()
      end)
  """
  @spec span([atom()], map(), (-> result)) :: result when result: any()
  def span(event_prefix, metadata, fun)
      when is_list(event_prefix) and is_function(fun, 0) do
    span_name = event_prefix |> List.last() |> to_string()
    _ = start_span(span_name)
    start_time = System.monotonic_time()
    enriched = to_metadata(metadata)

    _ = execute(event_prefix ++ [:start], %{system_time: System.system_time()}, enriched)

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time
      _ = execute(event_prefix ++ [:stop], %{duration: duration}, Map.put(enriched, :result, :ok))
      result
    rescue
      exception ->
        duration = System.monotonic_time() - start_time

        _ =
          execute(
            event_prefix ++ [:exception],
            %{duration: duration},
            Map.merge(enriched, %{exception: exception, stacktrace: __STACKTRACE__})
          )

        reraise exception, __STACKTRACE__
    after
      _ = end_span()
    end
  end

  # Private functions

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end

  @spec maybe_put(
          %{optional(String.t()) => String.t()},
          String.t(),
          String.t() | nil
        ) :: %{optional(String.t()) => String.t()}
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
