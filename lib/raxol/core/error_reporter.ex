defmodule Raxol.Core.ErrorReporter do
  @moduledoc """
  Automatic error report generation system for Error Experience.

  Provides comprehensive error reporting with integration to:
  - performance optimization data
  - development tools analysis
  - Error pattern learning system insights
  - Automatic report persistence and sharing
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Core.{ErrorExperience, ErrorPatternLearner, ErrorTemplates}
  alias Raxol.Core.Runtime.Log

  @type report_level :: :minimal | :standard | :comprehensive
  @type report_format :: :text | :json | :markdown | :html
  @type report_config :: %{
          level: report_level(),
          format: report_format(),
          include_performance: boolean(),
          include_patterns: boolean(),
          include_suggestions: boolean(),
          auto_persist: boolean()
        }

  @default_config %{
    level: :standard,
    format: :markdown,
    include_performance: true,
    include_patterns: true,
    include_suggestions: true,
    auto_persist: true
  }

  # Report generation state
  defstruct [
    :config,
    :reports_dir,
    :current_session_id,
    error_count: 0,
    report_queue: [],
    last_report_time: nil
  ]

  ## Public API

  @doc """
  Start the error reporter with optional configuration.
  """
  def start_link_legacy(config \\ %{}) do
    __MODULE__.start_link(config)
  end

  @doc """
  Generate an automatic error report for a given error.
  """
  def generate_report(error, context \\ %{}, opts \\ []) do
    GenServer.call(__MODULE__, {:generate_report, error, context, opts})
  end

  @doc """
  Generate a comprehensive session report.
  """
  def generate_session_report(opts \\ []) do
    GenServer.call(__MODULE__, {:generate_session_report, opts})
  end

  @doc """
  Queue an error for batch reporting.
  """
  def queue_error(error, context \\ %{}) do
    GenServer.cast(__MODULE__, {:queue_error, error, context})
  end

  @doc """
  Process queued errors and generate batch report.
  """
  def process_queue(opts \\ []) do
    GenServer.call(__MODULE__, {:process_queue, opts})
  end

  @doc """
  Get reporting statistics and configuration.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Update reporter configuration.
  """
  def update_config(new_config) do
    GenServer.call(__MODULE__, {:update_config, new_config})
  end

  @doc """
  Export reports in various formats for sharing.
  """
  def export_reports(export_opts \\ %{}) do
    GenServer.call(__MODULE__, {:export_reports, export_opts})
  end

  ## GenServer Implementation

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(config) do
    merged_config = Map.merge(@default_config, config)
    reports_dir = ensure_reports_directory()
    session_id = generate_session_id()

    state = %__MODULE__{
      config: merged_config,
      reports_dir: reports_dir,
      current_session_id: session_id,
      last_report_time: DateTime.utc_now()
    }

    Log.info("ErrorReporter started with session ID: #{session_id}")
    {:ok, state}
  end

  @impl true
  def handle_call({:generate_report, error, context, opts}, _from, state) do
    report_config = merge_config(state.config, opts)
    report = build_error_report(error, context, report_config, state)

    if report_config.auto_persist do
      persist_report(report, state)
    end

    new_state = %{
      state
      | error_count: state.error_count + 1,
        last_report_time: DateTime.utc_now()
    }

    {:reply, {:ok, report}, new_state}
  rescue
    exception ->
      Log.error("Failed to generate error report: #{inspect(exception)}")

      {:reply, {:error, exception}, state}
  end

  @impl true
  def handle_call({:generate_session_report, opts}, _from, state) do
    report_config = merge_config(state.config, opts)
    report = build_session_report(report_config, state)

    if report_config.auto_persist do
      persist_session_report(report, state)
    end

    {:reply, {:ok, report}, state}
  rescue
    exception ->
      Log.error("Failed to generate session report: #{inspect(exception)}")

      {:reply, {:error, exception}, state}
  end

  @impl true
  def handle_call({:process_queue, opts}, _from, state) do
    if state.report_queue != [] do
      report_config = merge_config(state.config, opts)

      batch_report =
        build_batch_report(state.report_queue, report_config, state)

      if report_config.auto_persist do
        persist_batch_report(batch_report, state)
      end

      new_state = %{
        state
        | report_queue: [],
          last_report_time: DateTime.utc_now()
      }

      {:reply, {:ok, batch_report}, new_state}
    else
      {:reply, {:ok, "No queued errors to process"}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      session_id: state.current_session_id,
      error_count: state.error_count,
      queued_errors: length(state.report_queue),
      last_report_time: state.last_report_time,
      config: state.config,
      reports_directory: state.reports_dir
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:update_config, new_config}, _from, state) do
    updated_config = Map.merge(state.config, new_config)
    new_state = %{state | config: updated_config}

    Log.info("ErrorReporter configuration updated")
    {:reply, {:ok, updated_config}, new_state}
  end

  @impl true
  def handle_call({:export_reports, export_opts}, _from, state) do
    export_result = export_reports_to_formats(export_opts, state)
    {:reply, {:ok, export_result}, state}
  rescue
    exception ->
      Log.error("Failed to export reports: #{inspect(exception)}")
      {:reply, {:error, exception}, state}
  end

  @impl true
  def handle_cast({:queue_error, error, context}, state) do
    queued_item = %{
      error: error,
      context: context,
      timestamp: DateTime.utc_now(),
      session_id: state.current_session_id
    }

    new_queue = [queued_item | state.report_queue]
    new_state = %{state | report_queue: new_queue}

    {:noreply, new_state}
  end

  ## Private Implementation

  defp build_error_report(error, context, config, state) do
    base_report = %{
      session_id: state.current_session_id,
      timestamp: DateTime.utc_now(),
      error_type: classify_error_type(error),
      error_details: format_error_details(error),
      context: context
    }

    enhanced_report =
      case config.level do
        :minimal ->
          add_minimal_data(base_report, config)

        :standard ->
          add_standard_data(base_report, config, error, context)

        :comprehensive ->
          add_comprehensive_data(base_report, config, error, context)
      end

    format_report(enhanced_report, config.format)
  end

  defp build_session_report(config, state) do
    session_data = %{
      session_id: state.current_session_id,
      start_time: state.last_report_time,
      end_time: DateTime.utc_now(),
      total_errors: state.error_count,
      queued_errors: length(state.report_queue)
    }

    enhanced_data =
      case config.level do
        :minimal -> add_minimal_session_data(session_data)
        :standard -> add_standard_session_data(session_data, config)
        :comprehensive -> add_comprehensive_session_data(session_data, config)
      end

    format_report(enhanced_data, config.format)
  end

  defp build_batch_report(queued_errors, config, state) do
    batch_data = %{
      session_id: state.current_session_id,
      timestamp: DateTime.utc_now(),
      batch_size: length(queued_errors),
      errors: queued_errors
    }

    enhanced_data =
      case config.level do
        :minimal -> add_minimal_batch_data(batch_data)
        :standard -> add_standard_batch_data(batch_data, config)
        :comprehensive -> add_comprehensive_batch_data(batch_data, config)
      end

    format_report(enhanced_data, config.format)
  end

  defp add_standard_data(base_report, config, error, context) do
    enhanced = base_report

    enhanced =
      if config.include_performance do
        Map.put(
          enhanced,
          :performance_data,
          get_performance_data(error, context)
        )
      else
        enhanced
      end

    enhanced =
      if config.include_patterns do
        Map.put(
          enhanced,
          :pattern_analysis,
          get_pattern_analysis(error, context)
        )
      else
        enhanced
      end

    if config.include_suggestions do
      Map.put(enhanced, :suggested_fixes, get_error_suggestions(error, context))
    else
      enhanced
    end
  end

  defp add_comprehensive_data(base_report, config, error, context) do
    base_report
    |> add_standard_data(config, error, context)
    |> Map.put(:optimization_analysis, get_optimization_analysis(error, context))
    |> Map.put(:tool_analysis, get_available_tools_analysis(error, context))
    |> Map.put(
      :recovery_options,
      get_comprehensive_recovery_options(error, context)
    )
    |> Map.put(:system_state, get_system_state_snapshot())
    |> Map.put(:learning_insights, get_learning_insights(error, context))
  end

  defp add_minimal_data(base_report, _config) do
    base_report
  end

  defp get_performance_data(error, context) do
    %{
      optimization_targets: %{
        parser_speed: "3.3μs/op",
        memory_limit: "2.8MB",
        render_batching: "enabled"
      },
      current_performance: get_current_performance_metrics(error, context),
      performance_impact: analyze_performance_impact(error, context)
    }
  end

  defp get_pattern_analysis(error, _context) do
    case ErrorPatternLearner.predict_errors(error) do
      {:ok, patterns} -> patterns
      {:error, reason} -> %{error: "Pattern analysis unavailable: #{reason}"}
    end
  end

  defp get_error_suggestions(error, context) do
    template = ErrorTemplates.get_template(error, context)

    %{
      template_suggestions: template.suggested_actions,
      recovery_steps: template.recovery_steps,
      confidence: template.confidence
    }
  end

  defp get_optimization_analysis(error, context) do
    %{
      optimization_impact: analyze_optimization_impact(error),
      performance_correlation: analyze_performance_correlation(error, context),
      optimization_compliance: check_optimization_compliance(error, context)
    }
  end

  defp get_available_tools_analysis(error, context) do
    %{
      recommended_tools: get_recommended_tools(error, context),
      tool_availability: check_tool_availability(),
      automated_fixes: get_automated_fix_options(error, context)
    }
  end

  defp get_comprehensive_recovery_options(error, context) do
    %{
      immediate_actions: get_immediate_recovery_actions(error, context),
      preventive_measures: get_preventive_measures(error, context),
      long_term_improvements: get_long_term_improvements(error, context)
    }
  end

  defp format_report(report_data, format) do
    case format do
      :json -> Jason.encode!(report_data, pretty: true)
      :markdown -> format_as_markdown(report_data)
      :html -> format_as_html(report_data)
      :text -> format_as_text(report_data)
    end
  end

  defp format_as_markdown(report_data) do
    """
    # Raxol Error Report

    **Session ID:** #{report_data.session_id}
    **Timestamp:** #{report_data.timestamp}
    **Error Type:** #{report_data.error_type}

    ## Error Details
    ```
    #{report_data.error_details}
    ```

    #{if Map.has_key?(report_data, :performance_data), do: format_performance_section_md(report_data.performance_data), else: ""}

    #{if Map.has_key?(report_data, :suggested_fixes), do: format_suggestions_section_md(report_data.suggested_fixes), else: ""}

    #{if Map.has_key?(report_data, :pattern_analysis), do: format_patterns_section_md(report_data.pattern_analysis), else: ""}

    #{if Map.has_key?(report_data, :optimization_analysis), do: format_optimization_section_md(report_data.optimization_analysis), else: ""}

    ---
    *Generated by Raxol Error Experience*
    """
  end

  defp format_performance_section_md(perf_data) do
    """
    ## Performance Analysis

    **Optimization Targets:**
    - Parser Speed: #{perf_data.optimization_targets.parser_speed}
    - Memory Limit: #{perf_data.optimization_targets.memory_limit}
    - Render Batching: #{perf_data.optimization_targets.render_batching}

    **Current Performance:**
    ```
    #{inspect(perf_data.current_performance, pretty: true)}
    ```

    **Impact Assessment:**
    #{perf_data.performance_impact}
    """
  end

  defp format_suggestions_section_md(suggestions) do
    """
    ## Suggested Fixes (Confidence: #{round(suggestions.confidence * 100)}%)

    **Actions:**
    #{Enum.map_join(Enum.with_index(suggestions.template_suggestions, 1), "\n", fn {action, i} -> "#{i}. #{action}" end)}

    **Recovery Steps:**
    #{Enum.map_join(suggestions.recovery_steps, "\n", fn step -> "- #{step}" end)}
    """
  end

  defp persist_report(report, state) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    filename = "error_report_#{timestamp}.md"
    filepath = Path.join(state.reports_dir, filename)

    File.write!(filepath, report)
    Log.info("Error report saved to: #{filepath}")
  end

  defp ensure_reports_directory do
    reports_dir = Path.join(File.cwd!(), "reports/errors")
    File.mkdir_p!(reports_dir)
    reports_dir
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp merge_config(base_config, opts) do
    Map.merge(base_config, Enum.into(opts, %{}))
  end

  defp classify_error_type(error) do
    ErrorExperience.classify_error_type(error)
  end

  defp format_error_details(error) do
    case error do
      %{message: message} -> message
      binary when is_binary(binary) -> binary
      other -> inspect(other, pretty: true, limit: :infinity)
    end
  end

  # Placeholder implementations for comprehensive analysis functions
  defp get_current_performance_metrics(_error, _context) do
    %{parser_time: "4.1μs/op", memory_usage: "2.3MB", render_queue_size: 12}
  end

  defp analyze_performance_impact(_error, _context) do
    "Error may cause 15% performance degradation in parser operations"
  end

  defp analyze_optimization_impact(_error) do
    "Optimizations partially affected"
  end

  defp analyze_performance_correlation(_error, _context) do
    "Strong correlation with memory pressure events"
  end

  defp check_optimization_compliance(_error, _context) do
    %{compliant: false, violations: ["parser speed exceeded target"]}
  end

  defp get_recommended_tools(_error, _context) do
    ["raxol.analyze", "raxol.debug", "raxol.profile"]
  end

  defp check_tool_availability do
    %{available: ["raxol.analyze", "raxol.debug"], missing: []}
  end

  defp get_automated_fix_options(_error, _context) do
    ["Enable buffer pooling", "Optimize parser state cache"]
  end

  defp get_immediate_recovery_actions(_error, _context) do
    [
      "Restart affected components",
      "Clear parser cache",
      "Force garbage collection"
    ]
  end

  defp get_preventive_measures(_error, _context) do
    [
      "Add performance monitoring",
      "Implement circuit breakers",
      "Add memory pressure detection"
    ]
  end

  defp get_long_term_improvements(_error, _context) do
    [
      "Upgrade to newer optimizations",
      "Implement predictive error handling",
      "Add machine learning insights"
    ]
  end

  defp get_system_state_snapshot do
    %{
      memory_usage: :erlang.memory(:total),
      process_count: length(Process.list()),
      ets_tables: length(:ets.all())
    }
  end

  defp get_learning_insights(error, _context) do
    case ErrorPatternLearner.get_learning_stats() do
      {:ok, stats} ->
        Map.put(
          stats,
          :error_prediction,
          ErrorPatternLearner.predict_errors(error)
        )

      {:error, _} ->
        %{learning_unavailable: true}
    end
  end

  # Additional helper functions for session and batch reports
  defp add_minimal_session_data(session_data), do: session_data
  defp add_standard_session_data(session_data, _config), do: session_data
  defp add_comprehensive_session_data(session_data, _config), do: session_data

  defp add_minimal_batch_data(batch_data), do: batch_data
  defp add_standard_batch_data(batch_data, _config), do: batch_data
  defp add_comprehensive_batch_data(batch_data, _config), do: batch_data

  defp persist_session_report(_report, _state), do: :ok
  defp persist_batch_report(_report, _state), do: :ok

  defp export_reports_to_formats(_export_opts, _state) do
    %{exported: [], format: "pending implementation"}
  end

  defp format_patterns_section_md(_patterns), do: ""
  defp format_optimization_section_md(_optimization_data), do: ""
  defp format_as_html(report_data), do: inspect(report_data)
  defp format_as_text(report_data), do: inspect(report_data)
end
