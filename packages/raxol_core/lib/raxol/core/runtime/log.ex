defmodule Raxol.Core.Runtime.Log do
  @moduledoc """
  Centralized logging system for Raxol with structured context, performance tracking,
  and consistent formatting across all modules.

  ## Features

  - Structured logging with automatic context enrichment
  - Module-aware logging with automatic module detection
  - Performance and timing utilities
  - Standardized error handling with stacktraces
  - Debug mode support with conditional logging
  - Automatic metadata collection (node, environment, version)
  - IO.puts/inspect migration helpers

  ## Usage

  Instead of using Logger directly or IO.puts, use this module:

      # Basic logging
      Log.info("User authenticated successfully")
      Log.error("Database connection failed")

      # With context
      Log.info("Processing request", %{user_id: 123, action: :login})
      Log.error("Validation failed", %{errors: errors, input: input})

      # A zero-arity fun defers message rendering until the level is enabled.
      # In modules that can `require Logger`, prefer the Logger macros on hot
      # paths so even the callback closure is avoided.
      Log.debug(fn -> "Parsed \#{inspect(byte)} in state \#{state}" end)
      Log.debug(fn -> "Parsed \#{inspect(byte)}" end, %{state: state})

      # Performance timing
      Log.time_info("Database query", fn ->
        expensive_operation()
      end)

      # Module-aware logging (automatically detects calling module)
      Log.info("Operation completed")

      # Migration from IO.puts
      Log.console("Debug output for development")
  """
  @type log_level :: :debug | :info | :warn | :error
  @type context :: map() | keyword() | nil
  @type metadata :: map()

  @doc """
  Logs an error with stacktrace and context.
  """
  def error_with_stacktrace(msg, error, stacktrace, context \\ nil) do
    error(
      "#{msg}\nError: #{inspect(error)}\nStacktrace: #{Exception.format_stacktrace(stacktrace)}",
      context
    )
  end

  @doc """
  Logs a warning with context.
  """
  def warning_with_context(msg, context), do: warning(msg, context)

  def info_with_context(msg) do
    info_with_context(msg, %{})
  end

  def info_with_context(msg, context), do: info(msg, context)

  def debug_with_context(msg, context), do: debug(msg, context)

  def error_with_context(msg, context), do: error(msg, context)

  def info(msg), do: log(:info, msg)

  @doc """
  Logs a debug message.

  `msg` is either iodata or a zero-arity fun returning iodata. The fun form is
  evaluated only when the `:debug` level is enabled. Code that can
  `require Logger` should prefer `Logger.debug/1` on hot paths; its macro also
  avoids allocating a callback closure while debug logging is disabled.

      Log.debug("starting up")
      Log.debug(fn -> "byte \#{inspect(byte)}" end)

  """
  @spec debug(iodata() | (-> iodata())) :: :ok
  def debug(msg), do: log(:debug, msg)

  def warning(msg), do: log(:warn, msg)
  def error(msg), do: log(:error, msg)

  def info(msg, context), do: log(:info, msg, context)
  def debug(msg, context), do: log(:debug, msg, context)
  def warning(msg, context), do: log(:warn, msg, context)
  def error(msg, context), do: log(:error, msg, context)

  defp log(level, msg, context \\ nil) do
    level = if level == :warn, do: :warning, else: level
    Logger.bare_log(level, with_context(msg, context))
  end

  # `msg` may be a zero-arity fun; preserve it through formatting so
  # `Logger.bare_log/2` controls whether it is evaluated.
  defp with_context(msg, nil), do: msg

  defp with_context(msg, context) when is_function(msg, 0) do
    fn -> [msg.(), " | Context: ", inspect(context)] end
  end

  defp with_context(msg, context), do: [msg, " | Context: ", inspect(context)]

  ## Enhanced Logging Functions

  @doc """
  Module-aware logging that automatically detects the calling module.
  """
  def module_debug(msg, context \\ nil) do
    module_log(:debug, msg, context)
  end

  def module_info(msg, context \\ nil) do
    module_log(:info, msg, context)
  end

  def module_warning(msg, context \\ nil) do
    module_log(:warn, msg, context)
  end

  def module_error(msg, context \\ nil) do
    module_log(:error, msg, context)
  end

  @doc """
  Performance timing logger that measures and logs execution time.
  """
  def time_debug(msg, func) when is_function(func, 0) do
    time_log(:debug, msg, func)
  end

  def time_info(msg, func) when is_function(func, 0) do
    time_log(:info, msg, func)
  end

  def time_warning(msg, func) when is_function(func, 0) do
    time_log(:warn, msg, func)
  end

  @doc """
  Console logging for development - replacement for IO.puts.
  Logs at `:info` in development/test environments and at `:debug` otherwise.
  """
  def console(msg, context \\ nil) do
    case Application.get_env(:raxol, :environment, :prod) do
      env when env in [:dev, :test] ->
        formatted = format_console_message(msg, context)
        info(formatted)

      _ ->
        debug(msg, context)
    end
  end

  @doc """
  Structured inspect logging - replacement for IO.inspect.
  """
  def log_inspect(data, label \\ nil, opts \\ []) do
    level = Keyword.get(opts, :level, :debug)
    context = %{data: data, label: label}

    message =
      case label do
        nil -> "Inspect: #{Kernel.inspect(data)}"
        label -> "#{label}: #{Kernel.inspect(data)}"
      end

    log(level, message, context)
    data
  end

  @doc """
  Conditional debug logging based on module configuration.
  """
  def debug_if(condition, msg, context \\ nil) do
    case condition do
      true ->
        module_debug(msg, context)

      false ->
        :ok

      module when is_atom(module) ->
        case debug_enabled_for_module?(module) do
          true -> module_debug(msg, context)
          false -> :ok
        end
    end
  end

  @doc """
  Log with automatic error classification and severity detection.
  """
  def auto_log(msg, data \\ nil) do
    {level, context} = classify_log_data(msg, data)
    module_log(level, msg, context)
  end

  @doc """
  Structured event logging with automatic metadata enrichment.
  """
  def event(event_type, msg, context \\ %{}) do
    enriched_context =
      context
      |> Map.put(:event_type, event_type)
      |> Map.put(:timestamp, System.system_time(:millisecond))
      |> enrich_metadata()

    module_info("[#{event_type}] #{msg}", enriched_context)
  end

  ## Private Implementation

  defp module_log(level, msg, context) do
    calling_module = get_calling_module()

    enriched_context =
      context
      |> normalize_context()
      |> Map.put(:module, calling_module)
      |> enrich_metadata()

    formatted_message = format_module_message(calling_module, msg)
    log_with_metadata(level, formatted_message, enriched_context)
  end

  defp time_log(level, msg, func) do
    start_time = System.monotonic_time(:microsecond)
    result = func.()
    end_time = System.monotonic_time(:microsecond)

    duration_us = end_time - start_time
    duration_ms = duration_us / 1000

    context = %{
      duration_us: duration_us,
      duration_ms: duration_ms,
      performance: true
    }

    formatted_msg = format_timed_message(msg, duration_us)
    module_log(level, formatted_msg, context)

    result
  end

  defp get_calling_module do
    case Process.info(self(), :current_stacktrace) do
      {:current_stacktrace, stack} when is_list(stack) ->
        extract_caller_module(stack)

      _ ->
        __MODULE__
    end
  end

  defp extract_caller_module([_current | [{module, _, _, _} | _]]), do: module
  defp extract_caller_module(_), do: __MODULE__

  defp normalize_context(nil), do: %{}
  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(context) when is_list(context), do: Map.new(context)
  defp normalize_context(context), do: %{data: context}

  defp enrich_metadata(context) do
    Map.merge(context, %{
      node: node(),
      environment: Application.get_env(:raxol, :environment, :prod),
      version: Application.spec(:raxol, :vsn) |> to_string(),
      pid: inspect(self()),
      timestamp: System.system_time(:millisecond)
    })
  end

  defp format_module_message(module, msg) when is_function(msg, 0) do
    module_name = module |> Module.split() |> List.last()
    fn -> ["[", module_name, "] ", msg.()] end
  end

  defp format_module_message(module, msg) do
    module_name = module |> Module.split() |> List.last()
    ["[", module_name, "] ", msg]
  end

  defp format_console_message(msg, nil) when is_function(msg, 0) do
    fn -> ["[CONSOLE] ", msg.()] end
  end

  defp format_console_message(msg, nil), do: ["[CONSOLE] ", msg]

  defp format_console_message(msg, context) when is_function(msg, 0) do
    fn -> ["[CONSOLE] ", msg.(), " | ", inspect(context)] end
  end

  defp format_console_message(msg, context),
    do: ["[CONSOLE] ", msg, " | ", inspect(context)]

  defp format_timed_message(msg, duration_us) when is_function(msg, 0) do
    fn -> [msg.(), " (", format_duration(duration_us), ")"] end
  end

  defp format_timed_message(msg, duration_us) do
    [msg, " (", format_duration(duration_us), ")"]
  end

  defp format_duration(microseconds) when microseconds < 1000 do
    "#{microseconds}μs"
  end

  defp format_duration(microseconds) when microseconds < 1_000_000 do
    ms = Float.round(microseconds / 1000, 2)
    "#{ms}ms"
  end

  defp format_duration(microseconds) do
    s = Float.round(microseconds / 1_000_000, 3)
    "#{s}s"
  end

  defp log_with_metadata(level, msg, context) do
    metadata = Map.to_list(context)
    Logger.metadata(metadata)

    level = if level == :warn, do: :warning, else: level
    Logger.bare_log(level, msg)
    Logger.reset_metadata()
  end

  defp classify_log_data(msg, data) do
    cond do
      error_message?(msg) -> {:error, %{error_detected: true, data: data}}
      warning_message?(msg) -> {:warn, %{warning_detected: true, data: data}}
      performance_related?(msg) -> {:info, %{performance: true, data: data}}
      true -> {:info, %{data: data}}
    end
  end

  defp error_message?(msg) when is_binary(msg) do
    error_keywords = ["error", "failed", "exception", "crash", "timeout"]
    msg_lower = String.downcase(msg)
    Enum.any?(error_keywords, &String.contains?(msg_lower, &1))
  end

  defp error_message?(_), do: false

  defp warning_message?(msg) when is_binary(msg) do
    warning_keywords = ["warning", "deprecated", "slow", "retry", "fallback"]
    msg_lower = String.downcase(msg)
    Enum.any?(warning_keywords, &String.contains?(msg_lower, &1))
  end

  defp warning_message?(_), do: false

  defp performance_related?(msg) when is_binary(msg) do
    perf_keywords = [
      "performance",
      "timing",
      "duration",
      "benchmark",
      "profile"
    ]

    msg_lower = String.downcase(msg)
    Enum.any?(perf_keywords, &String.contains?(msg_lower, &1))
  end

  defp performance_related?(_), do: false

  defp debug_enabled_for_module?(module) do
    case Application.get_env(:raxol, :debug_modules, []) do
      :all -> true
      modules when is_list(modules) -> module in modules
      _ -> false
    end
  end
end
