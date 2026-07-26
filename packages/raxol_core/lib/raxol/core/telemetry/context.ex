defmodule Raxol.Core.Telemetry.Context do
  @moduledoc """
  Trace context propagation for telemetry events.

  > #### Deprecated {: .warning}
  >
  > Use `Raxol.Core.Telemetry.TraceContext` instead. It provides the same
  > `span/3`, `execute/3`, and `to_metadata/1` telemetry surface (with
  > binary span names) plus causation tracking and header propagation.
  > This module is retained for backward compatibility and will be
  > removed in the next major release.

  Provides request correlation across components using trace_id and span_id.
  Following OpenTelemetry-compatible patterns for distributed tracing.

  ## Design

  Trace context is stored in the process dictionary and automatically
  propagated to child processes. This allows correlating all telemetry
  events within a single request/operation.

  ## Usage

      # Start a new trace (e.g., at request entry point)
      Context.start_trace()

      # Start a child span within a trace
      Context.start_span(:render)

      # Get current context for telemetry metadata
      metadata = Context.to_metadata()
      :telemetry.execute([:raxol, :render, :stop], measurements, metadata)

      # End current span
      Context.end_span()

      # Wrap a function with span instrumentation
      Context.with_span(:database_query, fn ->
        # ... work ...
      end)

  ## Context Structure

      %{
        trace_id: "abc123def456",      # Unique per request/trace
        span_id: "span789",            # Unique per operation within trace
        parent_span_id: "span456",     # Parent span (for nesting)
        baggage: %{}                   # Additional context to propagate
      }
  """

  @trace_key :raxol_trace_context
  @span_stack_key :raxol_span_stack

  @type trace_id :: String.t()
  @type span_id :: String.t()
  @type t :: %{
          trace_id: trace_id(),
          span_id: span_id(),
          parent_span_id: span_id() | nil,
          baggage: map()
        }

  # ============================================================================
  # Trace Management
  # ============================================================================

  @doc """
  Starts a new trace with a unique trace_id.

  Call this at the entry point of a request or operation.
  Returns the trace context.

  ## Examples

      context = Context.start_trace()
      # => %{trace_id: "abc123...", span_id: "def456...", ...}

      # With custom trace_id (e.g., from incoming request header)
      context = Context.start_trace(trace_id: "incoming-trace-id")
  """
  @spec start_trace(keyword()) :: t()
  def start_trace(opts \\ []) do
    trace_id = Keyword.get(opts, :trace_id, generate_id())
    span_id = generate_id()

    context = %{
      trace_id: trace_id,
      span_id: span_id,
      parent_span_id: nil,
      baggage: Keyword.get(opts, :baggage, %{})
    }

    Process.put(@trace_key, context)
    Process.put(@span_stack_key, [])

    context
  end

  @doc """
  Gets the current trace context.

  Returns nil if no trace is active.
  """
  @spec get() :: t() | nil
  def get do
    Process.get(@trace_key)
  end

  @doc """
  Gets the current trace_id, or nil if no trace is active.
  """
  @spec trace_id() :: trace_id() | nil
  def trace_id do
    case get() do
      %{trace_id: id} -> id
      nil -> nil
    end
  end

  @doc """
  Gets the current span_id, or nil if no trace is active.
  """
  @spec span_id() :: span_id() | nil
  def span_id do
    case get() do
      %{span_id: id} -> id
      nil -> nil
    end
  end

  @doc """
  Clears the current trace context.

  Call this when a request/operation completes.
  """
  @spec clear() :: :ok
  def clear do
    Process.delete(@trace_key)
    Process.delete(@span_stack_key)
    :ok
  end

  # ============================================================================
  # Span Management
  # ============================================================================

  @doc """
  Starts a new span within the current trace.

  Spans can be nested - calling start_span while a span is active
  creates a child span.

  ## Examples

      Context.start_span(:render)
      # ... do rendering ...
      Context.end_span()
  """
  @spec start_span(atom()) :: t()
  def start_span(name) when is_atom(name) do
    case get() do
      nil ->
        # No active trace, start one
        start_trace()
        |> tap(fn _ -> start_span(name) end)

      context ->
        # Push current span onto stack
        stack = Process.get(@span_stack_key, [])
        Process.put(@span_stack_key, [{context.span_id, name} | stack])

        # Create new span
        new_span_id = generate_id()

        new_context = %{
          context
          | span_id: new_span_id,
            parent_span_id: context.span_id
        }

        Process.put(@trace_key, new_context)
        new_context
    end
  end

  @doc """
  Ends the current span and returns to the parent span.
  """
  @spec end_span() :: t() | nil
  def end_span do
    case get() do
      nil ->
        nil

      context ->
        stack = Process.get(@span_stack_key, [])

        case stack do
          [] ->
            # No parent span, just return current context
            context

          [{parent_span_id, _name} | rest] ->
            # Restore parent span
            Process.put(@span_stack_key, rest)

            parent_context = %{
              context
              | span_id: parent_span_id,
                parent_span_id: get_grandparent_span_id(rest)
            }

            Process.put(@trace_key, parent_context)
            parent_context
        end
    end
  end

  @doc """
  Executes a function within a new span.

  Automatically starts a span, executes the function, and ends the span.
  The span timing is captured for telemetry.

  ## Examples

      result = Context.with_span(:database_query, fn ->
        Repo.all(User)
      end)
  """
  @spec with_span(atom(), (-> result)) :: result when result: any()
  def with_span(name, fun) when is_atom(name) and is_function(fun, 0) do
    _ = start_span(name)

    try do
      fun.()
    after
      _ = end_span()
    end
  end

  # ============================================================================
  # Baggage (Additional Context)
  # ============================================================================

  @doc """
  Sets a baggage value that will be propagated with the trace.

  Baggage is additional context that travels with the trace.

  ## Examples

      Context.put_baggage(:user_id, "user123")
      Context.put_baggage(:request_path, "/api/users")
  """
  @spec put_baggage(atom(), any()) :: :ok
  def put_baggage(key, value) when is_atom(key) do
    case get() do
      nil ->
        :ok

      context ->
        new_baggage = Map.put(context.baggage, key, value)
        Process.put(@trace_key, %{context | baggage: new_baggage})
        :ok
    end
  end

  @doc """
  Gets a baggage value.
  """
  @spec get_baggage(atom(), any()) :: any()
  def get_baggage(key, default \\ nil) when is_atom(key) do
    case get() do
      nil -> default
      context -> Map.get(context.baggage, key, default)
    end
  end

  # ============================================================================
  # Telemetry Integration
  # ============================================================================

  @doc """
  Converts current context to telemetry metadata map.

  Use this to add trace context to telemetry events:

  ## Examples

      metadata = Context.to_metadata()
      :telemetry.execute([:raxol, :render], measurements, metadata)

      # With additional metadata
      metadata = Context.to_metadata(%{component: :button})
  """
  @spec to_metadata(map()) :: map()
  def to_metadata(extra \\ %{}) do
    case get() do
      nil ->
        extra

      context ->
        Map.merge(extra, %{
          trace_id: context.trace_id,
          span_id: context.span_id,
          parent_span_id: context.parent_span_id
        })
    end
  end

  @doc """
  Executes a telemetry event with trace context automatically injected.

  ## Examples

      Context.execute([:raxol, :render, :stop], %{duration: 1234}, %{component: :button})
  """
  @spec execute([atom()], map(), map()) :: :ok
  def execute(event, measurements, metadata \\ %{}) do
    enriched_metadata = to_metadata(metadata)
    :telemetry.execute(event, measurements, enriched_metadata)
  end

  @doc """
  Wraps a function with telemetry span instrumentation.

  Emits start/stop/exception events with trace context.

  ## Examples

      result = Context.span([:raxol, :render], %{component: :button}, fn ->
        render_component()
      end)
  """
  @spec span([atom()], map(), (-> result)) :: result when result: any()
  def span(event_prefix, metadata, fun)
      when is_list(event_prefix) and is_function(fun, 0) do
    span_name =
      event_prefix
      |> List.last()
      |> to_string()
      |> String.to_atom()

    _ = start_span(span_name)
    start_time = System.monotonic_time()

    enriched_metadata = to_metadata(metadata)

    _ =
      execute(
        event_prefix ++ [:start],
        %{system_time: System.system_time()},
        enriched_metadata
      )

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time

      _ =
        execute(
          event_prefix ++ [:stop],
          %{duration: duration},
          Map.put(enriched_metadata, :result, :ok)
        )

      result
    rescue
      exception ->
        duration = System.monotonic_time() - start_time

        _ =
          execute(
            event_prefix ++ [:exception],
            %{duration: duration},
            Map.merge(enriched_metadata, %{
              exception: exception,
              stacktrace: __STACKTRACE__
            })
          )

        reraise exception, __STACKTRACE__
    after
      _ = end_span()
    end
  end

  # ============================================================================
  # Process Propagation
  # ============================================================================

  @doc """
  Captures current context for propagation to another process.

  ## Examples

      # In parent process
      captured = Context.capture()

      # In spawned process
      Task.async(fn ->
        Context.restore(captured)
        # ... work with trace context ...
      end)
  """
  @spec capture() :: t() | nil
  def capture do
    case get() do
      nil -> nil
      context -> Map.put(context, :span_stack, Process.get(@span_stack_key, []))
    end
  end

  @doc """
  Restores captured context in a new process.
  """
  @spec restore(map() | nil) :: :ok
  def restore(nil), do: :ok

  def restore(captured) when is_map(captured) do
    {span_stack, context} = Map.pop(captured, :span_stack, [])
    Process.put(@trace_key, context)
    Process.put(@span_stack_key, span_stack)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_id do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end

  defp get_grandparent_span_id([]), do: nil
  defp get_grandparent_span_id([{span_id, _name} | _rest]), do: span_id
end
