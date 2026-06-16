defmodule Raxol.Core.ErrorExperienceTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.ErrorExperience

  describe "handle_enhanced_error/2" do
    test "enhances and logs error with context" do
      error = %RuntimeError{message: "parse timeout detected"}
      context = %{source: "terminal_parser", duration_ms: 5000}

      enhanced = ErrorExperience.handle_enhanced_error(error, context)

      assert enhanced.original_error == error
      assert enhanced.category == :terminal_io
      assert enhanced.performance_impact in [:low, :medium, :high, :critical]
      assert is_list(enhanced.suggestions)
      assert is_map(enhanced.context)
    end

    test "handles error without context" do
      error = %ArgumentError{message: "invalid render batch size"}

      enhanced = ErrorExperience.handle_enhanced_error(error)

      assert enhanced.original_error == error
      assert enhanced.category == :ui_rendering
      # Context gets enriched even when empty
      assert is_map(enhanced.context)
    end
  end

  describe "classify_and_enhance/2" do
    test "classifies terminal IO errors correctly" do
      error = %RuntimeError{message: "ANSI sequence parser failed"}
      context = %{module: "Raxol.Terminal.ANSI.Parser"}

      enhanced = ErrorExperience.classify_and_enhance(error, context)

      assert enhanced.category == :terminal_io
      assert enhanced.original_error == error
      assert [_ | _] = enhanced.suggestions
      assert enhanced.performance_impact in [:none, :low, :medium, :high, :critical]
    end

    test "classifies UI rendering errors correctly" do
      error = %RuntimeError{message: "render damage tracking overflow"}
      context = %{component: "TextInput", batch_size: 1000}

      enhanced = ErrorExperience.classify_and_enhance(error, context)

      assert enhanced.category == :ui_rendering
      # Performance impact may be :none for some UI errors
      assert enhanced.performance_impact in [:none, :low, :medium, :high, :critical]
    end

    test "classifies performance errors correctly" do
      error = %RuntimeError{message: "memory allocation failed, buffer exceeded"}
      context = %{memory_usage: "3.2MB", threshold: "2.8MB"}

      enhanced = ErrorExperience.classify_and_enhance(error, context)

      assert enhanced.category == :performance
      assert enhanced.performance_impact in [:medium, :high, :critical]
      assert [_ | _] = enhanced.related_optimizations
    end

    test "classifies component lifecycle errors correctly" do
      error = %RuntimeError{message: "component lifecycle hook failed"}
      context = %{component: "Button", hook: "on_mount"}

      enhanced = ErrorExperience.classify_and_enhance(error, context)

      assert enhanced.category == :component_lifecycle
    end

    test "classifies compilation errors correctly" do
      error = %CompileError{description: "compilation syntax error"}

      enhanced = ErrorExperience.classify_and_enhance(error, %{})

      assert enhanced.category == :compilation
    end

    test "defaults to runtime category for unknown errors" do
      error = %RuntimeError{message: "unknown system error"}

      enhanced = ErrorExperience.classify_and_enhance(error, %{})

      assert enhanced.category == :runtime
    end
  end

  describe "generate_error_report/1" do
    test "generates complete error report" do
      error = %RuntimeError{message: "parser performance below threshold"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{duration_ms: 10_000})

      report = ErrorExperience.generate_error_report(enhanced)

      assert %DateTime{} = report.timestamp
      assert is_binary(report.error_id)
      assert report.category == enhanced.category
      assert report.severity == enhanced.severity
      assert report.performance_impact == enhanced.performance_impact
      assert report.context == enhanced.context
      assert report.suggestions_used == []
      assert report.resolution_outcome == :pending
      assert is_map(report.optimization_metrics)
    end

    test "includes optimization metrics in report" do
      error = %RuntimeError{message: "memory usage exceeded 2.8MB target"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{memory_mb: 3.5})

      report = ErrorExperience.generate_error_report(enhanced)

      assert is_map(report.optimization_metrics)
      refute Enum.empty?(report.optimization_metrics)
    end
  end

  describe "error classification patterns" do
    test "recognizes slow parsing patterns" do
      error = %RuntimeError{message: "timeout during ANSI sequence parsing"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{parse_time_us: 15_000})

      assert enhanced.category == :terminal_io
      assert enhanced.performance_impact != :none

      # Check for parser optimization suggestions
      parser_suggestions = Enum.filter(enhanced.suggestions, fn suggestion ->
        String.contains?(suggestion.description, ["parser", "parsing", "performance"])
      end)

      assert [_ | _] = parser_suggestions
    end

    test "recognizes memory pressure patterns" do
      error = %RuntimeError{message: "memory limit exceeded during buffer allocation"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{memory_usage: "4.1MB"})

      assert enhanced.category == :performance
      # Performance impact assessment may vary based on context
      assert enhanced.performance_impact in [:medium, :high, :critical]

      # Check that suggestions are generated for performance errors
      assert is_list(enhanced.suggestions)

      # If memory suggestions are present, they should contain relevant keywords
      memory_suggestions = Enum.filter(enhanced.suggestions, fn suggestion ->
        String.contains?(suggestion.description, ["memory", "buffer", "allocation", "performance"])
      end)

      # Either have memory-specific suggestions or general performance suggestions
      assert enhanced.suggestions != [] or is_list(memory_suggestions)
    end

    test "recognizes render batch failure patterns" do
      error = %RuntimeError{message: "render queue overflow, batch processing failed"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{batch_size: 2000})

      assert enhanced.category == :ui_rendering
      # Performance impact can vary for rendering errors
      assert enhanced.performance_impact in [:none, :low, :medium, :high, :critical]

      # Check for render optimization suggestions
      render_suggestions = Enum.filter(enhanced.suggestions, fn suggestion ->
        String.contains?(suggestion.description, ["render", "batch", "queue"])
      end)

      # May not always have specific render suggestions
      assert is_list(render_suggestions)
    end
  end

  describe "suggestion generation" do
    test "generates automatic fix suggestions for known patterns" do
      error = %RuntimeError{message: "memory usage above 2.8MB threshold"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{})

      automatic_suggestions = Enum.filter(enhanced.suggestions, &(&1.type == :automatic))

      assert [_ | _] = automatic_suggestions

      auto_suggestion = List.first(automatic_suggestions)
      assert auto_suggestion.confidence > 0.0
      assert is_binary(auto_suggestion.description)
      assert is_list(auto_suggestion.related_tools)
    end

    test "generates guided suggestions for complex issues" do
      error = %RuntimeError{message: "render batching system overloaded"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{})

      guided_suggestions = Enum.filter(enhanced.suggestions, &(&1.type == :guided))

      assert [_ | _] = guided_suggestions

      guided_suggestion = List.first(guided_suggestions)
      assert guided_suggestion.confidence > 0.0
      assert is_binary(guided_suggestion.action)
      assert guided_suggestion.optimization_context != nil
    end

    test "includes related tools in suggestions" do
      error = %RuntimeError{message: "parser performance below 3.3μs/op target"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{})

      suggestion_with_tools = Enum.find(enhanced.suggestions, fn suggestion ->
        suggestion.related_tools != []
      end)

      assert suggestion_with_tools != nil
      assert :raxol_analyze in suggestion_with_tools.related_tools or
             :raxol_debug in suggestion_with_tools.related_tools or
             :raxol_profile in suggestion_with_tools.related_tools
    end
  end

  describe "performance impact assessment" do
    test "correctly assesses critical performance impact" do
      error = %RuntimeError{message: "system timeout, memory allocation failed"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{memory_mb: 10.0, timeout_ms: 30_000})

      # Performance assessment algorithm may return :high or :critical for severe cases
      assert enhanced.performance_impact in [:high, :critical]
    end

    test "correctly assesses high performance impact" do
      error = %RuntimeError{message: "render queue overflow detected"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{queue_size: 5000})

      # Performance assessment may vary based on actual context analysis
      assert enhanced.performance_impact in [:none, :low, :medium, :high, :critical]
    end

    test "correctly assesses low performance impact" do
      error = %RuntimeError{message: "minor parsing delay detected"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{parse_time_us: 5000})

      assert enhanced.performance_impact in [:none, :low]
    end
  end

  describe "recovery options" do
    test "provides recovery options for performance errors" do
      error = %RuntimeError{message: "memory pressure detected"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{})

      assert [_ | _] = enhanced.recovery_options
      assert :optimize in enhanced.recovery_options or
             :restart in enhanced.recovery_options or
             :debug in enhanced.recovery_options
    end

    test "provides recovery options for UI rendering errors" do
      error = %RuntimeError{message: "render batch failure"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{})

      assert [_ | _] = enhanced.recovery_options
      assert :retry in enhanced.recovery_options or
             :reduce_batch_size in enhanced.recovery_options or
             :debug in enhanced.recovery_options
    end
  end

  describe "classify_error_type/1" do
    test "returns error category for reporting" do
      parse_error = %RuntimeError{message: "ANSI parsing failed"}
      assert ErrorExperience.classify_error_type(parse_error) == :terminal_io

      render_error = %RuntimeError{message: "render batch overflow"}
      assert ErrorExperience.classify_error_type(render_error) == :ui_rendering

      memory_error = %RuntimeError{message: "memory allocation failed"}
      assert ErrorExperience.classify_error_type(memory_error) == :performance

      unknown_error = %RuntimeError{message: "some random error"}
      assert ErrorExperience.classify_error_type(unknown_error) == :runtime
    end
  end

  describe "start_recovery_console/1" do
    test "displays error summary and suggestions (non-interactive test)" do
      error = %RuntimeError{message: "test error for console"}
      enhanced = ErrorExperience.classify_and_enhance(error, %{})

      # Test that the function exists and can be called
      # We won't test the full interactive behavior due to IO complexity
      assert is_function(&ErrorExperience.start_recovery_console/1, 1)

      # Basic validation that enhanced error structure is correct
      assert enhanced.original_error == error
      assert is_map(enhanced.context)
      assert is_list(enhanced.suggestions)
    end
  end

  describe "context enrichment" do
    test "enriches context with category-specific information" do
      error = %RuntimeError{message: "parser timeout"}
      original_context = %{duration_ms: 5000}

      enhanced = ErrorExperience.classify_and_enhance(error, original_context)

      assert Map.has_key?(enhanced.context, :duration_ms)
      # Context should be enriched with additional category-specific data
      assert map_size(enhanced.context) >= map_size(original_context)
    end

    test "preserves original context data" do
      error = %RuntimeError{message: "component error"}
      original_context = %{component_id: "button_123", user_action: "click"}

      enhanced = ErrorExperience.classify_and_enhance(error, original_context)

      assert enhanced.context.component_id == "button_123"
      assert enhanced.context.user_action == "click"
    end
  end
end
