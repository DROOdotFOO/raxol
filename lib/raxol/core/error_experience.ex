defmodule Raxol.Core.ErrorExperience do
  @moduledoc """
  Enhanced error experience system for Raxol applications.

  Intelligent error handling with:
  - Contextual fix suggestions based on performance optimizations
  - Integration with development tools
  - Pattern learning for common error scenarios
  - Interactive error recovery workflows

  ## Features

  - Smart error classification with performance context
  - Automatic fix suggestions using performance knowledge
  - Integration with `mix raxol.analyze` and `mix raxol.debug`
  - Error pattern learning and prevention
  - Interactive recovery console
  """

  alias Raxol.Core.ErrorHandling
  alias Raxol.Core.Runtime.Log
  require Logger

  @type error_category ::
          :performance
          | :compilation
          | :runtime
          | :ui_rendering
          | :terminal_io
          | :component_lifecycle
          | :optimization
          | :integration

  @type fix_suggestion :: %{
          type: :automatic | :guided | :manual | :documentation,
          description: String.t(),
          action: String.t() | nil,
          confidence: float(),
          related_tools: [atom()],
          optimization_context: map() | nil
        }

  @type enhanced_error :: %{
          original_error: term(),
          category: error_category(),
          severity: ErrorHandling.error_severity(),
          context: map(),
          suggestions: [fix_suggestion()],
          performance_impact: :none | :low | :medium | :high | :critical,
          related_optimizations: [String.t()],
          recovery_options: [atom()]
        }

  # Error patterns learned from performance tuning
  @performance_patterns %{
    slow_parsing: %{
      indicators: [:timeout, :performance_warning, "parser took"],
      suggestions: [
        %{
          type: :guided,
          description: "Parser performance below 3.3μs/op target",
          action: "mix raxol.analyze --depth comprehensive --benchmark",
          confidence: 0.9,
          related_tools: [:raxol_analyze, :raxol_profile],
          optimization_context: %{optimization: "parser_caching", target: "3.3μs/op"}
        }
      ]
    },
    memory_pressure: %{
      indicators: [:memory_limit, :allocation_failed, "memory usage"],
      suggestions: [
        %{
          type: :automatic,
          description: "Memory usage above 2.8MB threshold detected",
          action: "Enable buffer pooling and garbage collection optimization",
          confidence: 0.8,
          related_tools: [:raxol_debug, :raxol_profile],
          optimization_context: %{optimization: "buffer_pooling", target: "2.8MB"}
        }
      ]
    },
    render_batch_failure: %{
      indicators: [:render_timeout, :batch_overflow, "render queue"],
      suggestions: [
        %{
          type: :guided,
          description: "Render batching system overloaded",
          action: "mix raxol.debug --trace \"Raxol.UI.Rendering.*\"",
          confidence: 0.85,
          related_tools: [:raxol_debug, :raxol_analyze],
          optimization_context: %{
            optimization: "render_batching",
            system: "damage_tracking"
          }
        }
      ]
    }
  }

  @doc """
  Enhanced error handling with intelligent suggestions and recovery.
  """
  def handle_enhanced_error(error, context \\ %{}) do
    enhanced = classify_and_enhance(error, context)

    # Log with optimization context
    log_enhanced_error(enhanced)

    # Trigger appropriate development tools if available
    _ = maybe_trigger_analysis_tools(enhanced)

    # Return enhanced error for interactive handling
    enhanced
  end

  @doc """
  Classify error and provide enhancement based on optimization patterns.
  """
  def classify_and_enhance(error, context) do
    category = classify_error(error, context)
    suggestions = generate_suggestions(error, category, context)
    performance_impact = assess_performance_impact(error, context)
    related_opts = find_related_optimizations(error, category)

    %{
      original_error: error,
      category: category,
      severity: determine_severity(error, performance_impact),
      context: enrich_context(context, category),
      suggestions: suggestions,
      performance_impact: performance_impact,
      related_optimizations: related_opts,
      recovery_options: determine_recovery_options(category, performance_impact)
    }
  end

  @doc """
  Classify error type for reporting purposes.
  """
  def classify_error_type(error) do
    classify_error(error, %{})
  end

  @doc """
  Interactive error recovery console.
  """
  def start_recovery_console(enhanced_error) do
    Log.info(
      "\n" <> IO.ANSI.red() <> "Raxol Error Recovery Console" <> IO.ANSI.reset()
    )

    Log.info(String.duplicate("=", 35))

    display_error_summary(enhanced_error)
    display_suggestions(enhanced_error.suggestions)

    if enhanced_error.performance_impact != :none do
      display_performance_context(enhanced_error)
    end

    handle_recovery_interaction(enhanced_error)
  end

  @doc """
  Generate automatic error report for learning system.
  """
  def generate_error_report(enhanced_error) do
    report = %{
      timestamp: DateTime.utc_now(),
      error_id: generate_error_id(enhanced_error),
      category: enhanced_error.category,
      severity: enhanced_error.severity,
      performance_impact: enhanced_error.performance_impact,
      context: enhanced_error.context,
      suggestions_used: [],
      resolution_outcome: :pending,
      optimization_metrics: extract_optimization_metrics(enhanced_error)
    }

    store_error_report(report)
    report
  end

  # Private implementation

  @error_category_keywords [
    {:terminal_io, ["parse", "ansi", "sequence"]},
    {:ui_rendering, ["render", "damage", "batch"]},
    {:component_lifecycle, ["component", "lifecycle"]},
    {:performance, ["memory", "allocation", "buffer"]},
    {:performance, ["timeout", "slow", "latency"]},
    {:compilation, ["compilation", "syntax"]},
    {:optimization, ["optimization"]}
  ]

  @spec classify_error(term(), map()) ::
          :terminal_io
          | :ui_rendering
          | :component_lifecycle
          | :performance
          | :compilation
          | :optimization
          | :runtime
  defp classify_error(error, context) do
    error_string = inspect(error) |> String.downcase()

    classify_by_keywords(error_string) ||
      classify_by_context(context) ||
      :runtime
  end

  defp classify_by_keywords(error_string) do
    Enum.find_value(@error_category_keywords, fn {category, keywords} ->
      if String.contains?(error_string, keywords), do: category
    end)
  end

  defp classify_by_context(context) do
    if Map.has_key?(context, :performance_metrics), do: :performance
  end

  defp generate_suggestions(error, category, context) do
    # Pattern-based suggestions from prior experience
    pattern_suggestions = find_pattern_suggestions(error)

    # Category-specific suggestions
    category_suggestions =
      case category do
        :performance -> performance_suggestions(error, context)
        :ui_rendering -> rendering_suggestions(error, context)
        :terminal_io -> terminal_suggestions(error, context)
        :optimization -> optimization_suggestions(error, context)
        _ -> general_suggestions(error, context)
      end

    (pattern_suggestions ++ category_suggestions)
    |> Enum.uniq_by(& &1.description)
    |> Enum.sort_by(& &1.confidence, :desc)
  end

  defp find_pattern_suggestions(error) do
    error_text = inspect(error) |> String.downcase()

    @performance_patterns
    |> Enum.flat_map(fn {_pattern_name, pattern} ->
      if Enum.any?(
           pattern.indicators,
           &String.contains?(error_text, to_string(&1))
         ) do
        pattern.suggestions
      else
        []
      end
    end)
  end

  defp performance_suggestions(_error, context) do
    base_suggestions = [
      %{
        type: :guided,
        description: "Analyze performance with performance tools",
        action: "mix raxol.analyze --target . --benchmark",
        confidence: 0.8,
        related_tools: [:raxol_analyze],
        optimization_context: %{component: "performance_analyzer"}
      },
      %{
        type: :guided,
        description: "Profile with real-time monitoring",
        action: "mix raxol.profile --live --threshold 1",
        confidence: 0.8,
        related_tools: [:raxol_profile],
        optimization_context: %{component: "interactive_profiler"}
      }
    ]

    # Add context-specific suggestions
    if Map.get(context, :memory_usage, 0) > 2_800_000 do
      memory_suggestion = %{
        type: :automatic,
        description: "Memory usage exceeds performance target (2.8MB)",
        action: "Enable buffer pooling optimization",
        confidence: 0.9,
        related_tools: [:raxol_debug],
        optimization_context: %{target: "2.8MB", current: context.memory_usage}
      }

      [memory_suggestion | base_suggestions]
    else
      base_suggestions
    end
  end

  defp rendering_suggestions(_error, _context) do
    [
      %{
        type: :guided,
        description: "Debug render pipeline with damage tracking",
        action: "mix raxol.debug --trace \"Raxol.UI.Rendering.*\"",
        confidence: 0.85,
        related_tools: [:raxol_debug],
        optimization_context: %{
          system: "damage_tracking",
          optimization: "render_batching"
        }
      },
      %{
        type: :manual,
        description: "Check component for optimization markers",
        action: "Verify @raxol_optimized attribute is set",
        confidence: 0.7,
        related_tools: [:raxol_gen_component],
        optimization_context: %{pattern: "optimization_marker"}
      }
    ]
  end

  defp terminal_suggestions(_error, _context) do
    [
      %{
        type: :guided,
        description: "Analyze ANSI parsing performance",
        action: "mix raxol.analyze --depth comprehensive",
        confidence: 0.8,
        related_tools: [:raxol_analyze],
        optimization_context: %{target: "3.3μs/op", component: "ansi_parser"}
      }
    ]
  end

  defp optimization_suggestions(_error, _context) do
    [
      %{
        type: :documentation,
        description: "Review optimization guide",
        action: "Check docs/performance/optimizations.md",
        confidence: 0.6,
        related_tools: [],
        optimization_context: %{documentation: "optimization_guide"}
      }
    ]
  end

  defp general_suggestions(_error, _context) do
    [
      %{
        type: :guided,
        description: "Start debug console for investigation",
        action: "mix raxol.debug",
        confidence: 0.5,
        related_tools: [:raxol_debug],
        optimization_context: nil
      }
    ]
  end

  @spec assess_performance_impact(term(), map()) ::
          :none | :low | :medium | :high | :critical
  defp assess_performance_impact(error, context) do
    error_text = inspect(error) |> String.downcase()

    cond do
      String.contains?(error_text, ["critical", "crash", "abort"]) -> :critical
      String.contains?(error_text, ["timeout", "slow", "latency"]) -> :high
      String.contains?(error_text, ["memory", "allocation"]) -> :medium
      String.contains?(error_text, ["warning", "deprecated"]) -> :low
      Map.get(context, :performance_degradation, false) -> :medium
      true -> :none
    end
  end

  defp find_related_optimizations(_error, category) do
    case category do
      :performance ->
        ["parser_caching", "buffer_pooling", "memory_pressure_detection"]

      :ui_rendering ->
        ["damage_tracking", "render_batching", "adaptive_frame_rate"]

      :terminal_io ->
        ["ansi_parsing", "parser_state_caching"]

      :optimization ->
        ["all_optimizations"]

      _ ->
        []
    end
  end

  defp determine_severity(error, performance_impact) do
    case {error, performance_impact} do
      {_, :critical} -> :critical
      {{:error, _}, :high} -> :error
      {_, :high} -> :warning
      {{:error, _}, _} -> :warning
      {_, :medium} -> :info
      _ -> :debug
    end
  end

  defp enrich_context(context, category) do
    base_context =
      Map.merge(context, %{
        category: category,
        subsystem: "error_experience",
        tools_available: available_tools()
      })

    case category do
      :performance ->
        Map.merge(base_context, %{
          optimization_targets: %{parser: "3.3μs/op", memory: "2.8MB"},
          analysis_tools: [:raxol_analyze, :raxol_profile]
        })

      :ui_rendering ->
        Map.merge(base_context, %{
          render_system: "damage_tracking_batching",
          debug_tools: [:raxol_debug]
        })

      _ ->
        base_context
    end
  end

  defp determine_recovery_options(category, performance_impact) do
    base_options = [:retry, :ignore, :debug]

    case {category, performance_impact} do
      {:performance, impact} when impact in [:high, :critical] ->
        [:analyze, :profile, :optimize] ++ base_options

      {:ui_rendering, _} ->
        [:debug_render, :check_optimizations] ++ base_options

      {:terminal_io, _} ->
        [:analyze_parser, :check_ansi] ++ base_options

      _ ->
        base_options
    end
  end

  defp available_tools do
    [
      :raxol_analyze,
      :raxol_profile,
      :raxol_debug,
      :raxol_gen_component
    ]
  end

  defp display_error_summary(enhanced_error) do
    Log.info("\n" <> IO.ANSI.yellow() <> "Error Summary:" <> IO.ANSI.reset())
    Log.info("Category: #{enhanced_error.category}")
    Log.info("Severity: #{enhanced_error.severity}")
    Log.info("Performance Impact: #{enhanced_error.performance_impact}")

    if enhanced_error.related_optimizations != [] do
      Log.info(
        "Related Optimizations: #{Enum.join(enhanced_error.related_optimizations, ", ")}"
      )
    end

    :ok
  end

  defp display_suggestions(suggestions) do
    Log.info("\n" <> IO.ANSI.green() <> "Fix Suggestions:" <> IO.ANSI.reset())

    suggestions
    |> Enum.with_index(1)
    |> Enum.each(fn {suggestion, index} ->
      confidence_bar = String.duplicate("█", round(suggestion.confidence * 10))
      Log.info("#{index}. #{suggestion.description}")

      if suggestion.action do
        Log.info(
          "   Action: #{IO.ANSI.cyan()}#{suggestion.action}#{IO.ANSI.reset()}"
        )
      end

      Log.info(
        "   Confidence: #{confidence_bar} (#{trunc(suggestion.confidence * 100)}%)"
      )

      if suggestion.optimization_context do
        Log.info("   Optimization Context: #{inspect(suggestion.optimization_context)}")
      end

      Log.info("")
    end)

    :ok
  end

  defp display_performance_context(enhanced_error) do
    Log.info(
      "\n" <> IO.ANSI.magenta() <> "Performance Context:" <> IO.ANSI.reset()
    )

    Log.info("Impact Level: #{enhanced_error.performance_impact}")

    if enhanced_error.context[:optimization_targets] do
      targets = enhanced_error.context[:optimization_targets]
      Log.info("Optimization Targets: #{inspect(targets)}")
    end

    Log.info(
      "Available Analysis Tools: #{inspect(enhanced_error.context[:analysis_tools] || [])}"
    )

    :ok
  end

  defp handle_recovery_interaction(enhanced_error) do
    display_recovery_menu(enhanced_error.recovery_options)
    prompt_and_execute(enhanced_error)
  end

  defp display_recovery_menu(options) do
    Log.info("\n" <> IO.ANSI.blue() <> "Recovery Options:" <> IO.ANSI.reset())

    options
    |> Enum.with_index(1)
    |> Enum.each(fn {option, index} ->
      Log.info("#{index}. #{format_recovery_option(option)}")
    end)

    Log.info("#{length(options) + 1}. Exit")
  end

  defp prompt_and_execute(enhanced_error) do
    raw = IO.gets("Select option: ") |> String.trim()
    options = enhanced_error.recovery_options

    case Integer.parse(raw) do
      {choice, _} when choice >= 1 and choice <= length(options) ->
        option = Enum.at(options, choice - 1)
        execute_recovery_option(option, enhanced_error)

      _ ->
        :ok
    end
  end

  @recovery_labels %{
    retry: "Retry operation",
    ignore: "Ignore and continue",
    debug: "Start debug console",
    analyze: "Run performance analysis",
    profile: "Start interactive profiler",
    optimize: "Apply automatic optimizations",
    debug_render: "Debug rendering pipeline",
    check_optimizations: "Check performance optimizations",
    analyze_parser: "Analyze parser performance",
    check_ansi: "Check ANSI sequence handling"
  }

  defp format_recovery_option(option) do
    Map.get(@recovery_labels, option, to_string(option))
  end

  defp execute_recovery_option(option, _enhanced_error) do
    case option do
      :analyze ->
        Log.info("Starting performance analysis...")
        System.cmd("mix", ["raxol.analyze", "--target", ".", "--benchmark"])

      :profile ->
        Log.info("Starting interactive profiler...")
        System.cmd("mix", ["raxol.profile", "--live"])

      :debug ->
        Log.info("Starting debug console...")
        System.cmd("mix", ["raxol.debug"])

      :debug_render ->
        Log.info("Starting render pipeline debugging...")
        System.cmd("mix", ["raxol.debug", "--trace", "Raxol.UI.Rendering.*"])

      _ ->
        Log.info("Executing #{option}...")
        :ok
    end
  end

  defp log_enhanced_error(enhanced_error) do
    level =
      case enhanced_error.severity do
        :critical -> :error
        :error -> :error
        :warning -> :warning
        :info -> :info
        :debug -> :debug
      end

    Logger.log(level, "Enhanced error detected",
      category: enhanced_error.category,
      performance_impact: enhanced_error.performance_impact,
      suggestions_count: length(enhanced_error.suggestions),
      optimization_context: enhanced_error.context[:optimization_targets]
    )

    :ok
  end

  defp maybe_trigger_analysis_tools(enhanced_error) do
    # Auto-trigger tools for critical performance issues
    case enhanced_error.performance_impact do
      :critical ->
        Log.info("Critical performance impact detected. Starting analysis...")

        Task.start(fn ->
          System.cmd("mix", ["raxol.analyze", "--depth", "comprehensive"])
        end)

      :high ->
        Log.info(
          "High performance impact detected. Consider running: mix raxol.analyze"
        )

      _ ->
        :ok
    end
  end

  defp extract_optimization_metrics(enhanced_error) do
    %{
      targets_referenced: enhanced_error.context[:optimization_targets],
      optimizations_involved: enhanced_error.related_optimizations,
      tools_suggested:
        enhanced_error.suggestions
        |> Enum.flat_map(& &1.related_tools)
        |> Enum.uniq()
    }
  end

  defp generate_error_id(enhanced_error) do
    :crypto.hash(:md5, inspect(enhanced_error.original_error))
    |> Base.encode16(case: :lower)
    |> String.slice(0..7)
  end

  defp store_error_report(report) do
    # Store in tmp for now - in production would use proper storage
    reports_dir = "/tmp/raxol_error_reports"
    File.mkdir_p!(reports_dir)

    filename = "#{report.error_id}_#{DateTime.to_unix(report.timestamp)}.json"
    filepath = Path.join(reports_dir, filename)

    File.write!(filepath, Jason.encode!(report, pretty: true))
  end
end
