defmodule Raxol.Core.ErrorPatternLearner do
  @moduledoc """
  Error Pattern Learning System - Error Experience

  Machine learning-inspired system that learns from error patterns to:
  - Predict likely errors before they occur
  - Improve fix suggestions based on success rates
  - Identify emerging error patterns in performance optimizations
  - Automatically update error templates with learned knowledge

  Sub-modules:
  - `Predictor`    -- predictions, confidence, suggestion enhancement
  - `Persistence`  -- load/save/import/export
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Core.ErrorPatternLearner.{Persistence, Predictor}
  alias Raxol.Core.Runtime.Log

  @table_name :raxol_error_patterns
  @persist_interval_ms :timer.hours(1)

  defstruct [
    :patterns,
    :suggestion_success_rates,
    :optimization_correlations,
    :prediction_models,
    :learning_enabled,
    :last_cleanup
  ]

  @type error_pattern :: %{
          signature: String.t(),
          frequency: integer(),
          contexts: [map()],
          successful_fixes: [String.t()],
          failure_modes: [String.t()],
          optimization_correlation: float(),
          prediction_confidence: float(),
          first_seen: DateTime.t(),
          last_seen: DateTime.t()
        }

  @type learning_state :: %__MODULE__{
          patterns: %{String.t() => error_pattern()},
          suggestion_success_rates: %{String.t() => float()},
          optimization_correlations: %{atom() => float()},
          prediction_models: map(),
          learning_enabled: boolean(),
          last_cleanup: DateTime.t()
        }

  # Public API

  @doc "Record a new error occurrence for learning."
  def record_error(error, context \\ %{}) do
    GenServer.cast(
      __MODULE__,
      {:record_error, error, context, DateTime.utc_now()}
    )
  end

  @doc "Record the success or failure of a fix suggestion."
  def record_fix_outcome(error_signature, fix_description, outcome)
      when outcome in [:success, :failure] do
    GenServer.cast(
      __MODULE__,
      {:record_fix_outcome, error_signature, fix_description, outcome}
    )
  end

  @doc "Get predictions for potential errors based on current context."
  def predict_errors(context) do
    GenServer.call(__MODULE__, {:predict_errors, context})
  end

  @doc "Get enhanced suggestions based on learned patterns."
  def enhance_suggestions(error, base_suggestions, context \\ %{}) do
    GenServer.call(
      __MODULE__,
      {:enhance_suggestions, error, base_suggestions, context}
    )
  end

  @doc "Get learning statistics and insights."
  def get_learning_stats do
    GenServer.call(__MODULE__, :get_learning_stats)
  end

  @doc "Get the most common error patterns."
  def get_common_patterns(limit \\ 10) do
    GenServer.call(__MODULE__, {:get_common_patterns, limit})
  end

  @doc "Get patterns correlated with performance optimizations."
  def get_optimization_correlations do
    GenServer.call(__MODULE__, :get_optimization_correlations)
  end

  @doc "Export learned patterns for analysis or backup."
  def export_patterns(format \\ :json) do
    GenServer.call(__MODULE__, {:export_patterns, format})
  end

  @doc "Import previously learned patterns."
  def import_patterns(patterns_data) do
    GenServer.cast(__MODULE__, {:import_patterns, patterns_data})
  end

  # GenServer implementation

  @impl true
  def init_manager(_opts) do
    _ =
      :ets.new(@table_name, [
        :named_table,
        :public,
        :set,
        {:read_concurrency, true}
      ])

    initial_state = Persistence.load_initial_state(__MODULE__)
    schedule_cleanup()
    Log.info("Error pattern learning system started")
    {:ok, initial_state}
  end

  @impl true
  def handle_manager_cast({:record_error, error, context, timestamp}, state) do
    error_signature = Predictor.generate_error_signature(error)

    update_pattern_ets(error_signature, context, timestamp)

    updated_patterns =
      update_pattern_frequency(
        state.patterns,
        error_signature,
        context,
        timestamp
      )

    updated_correlations =
      update_optimization_correlations(
        state.optimization_correlations,
        error,
        context
      )

    new_state = %{
      state
      | patterns: updated_patterns,
        optimization_correlations: updated_correlations
    }

    if should_persist?(state, new_state) do
      Persistence.persist_async(new_state)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_manager_cast(
        {:record_fix_outcome, error_signature, fix_description, outcome},
        state
      ) do
    fix_key = "#{error_signature}:#{fix_description}"
    current_rate = Map.get(state.suggestion_success_rates, fix_key, 0.5)

    new_rate =
      case outcome do
        :success -> min(0.95, current_rate + 0.1)
        :failure -> max(0.05, current_rate - 0.1)
      end

    updated_rates = Map.put(state.suggestion_success_rates, fix_key, new_rate)

    updated_patterns =
      update_pattern_fixes(
        state.patterns,
        error_signature,
        fix_description,
        outcome
      )

    new_state = %{
      state
      | suggestion_success_rates: updated_rates,
        patterns: updated_patterns
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_manager_cast({:import_patterns, patterns_data}, state) do
    imported_patterns = Persistence.parse_imported(patterns_data)
    merged_patterns = Map.merge(state.patterns, imported_patterns)

    Enum.each(merged_patterns, fn {signature, pattern} ->
      :ets.insert(@table_name, {signature, pattern})
    end)

    new_state = %{state | patterns: merged_patterns}
    Log.info("Imported #{map_size(imported_patterns)} error patterns")
    {:noreply, new_state}
  end

  @impl true
  def handle_manager_call({:predict_errors, context}, _from, state) do
    predictions = Predictor.generate_predictions(state, context)
    {:reply, predictions, state}
  end

  @impl true
  def handle_manager_call(
        {:enhance_suggestions, error, base_suggestions, context},
        _from,
        state
      ) do
    enhanced =
      Predictor.enhance_suggestions(state, error, base_suggestions, context)

    {:reply, enhanced, state}
  end

  @impl true
  def handle_manager_call(:get_learning_stats, _from, state) do
    stats = %{
      total_patterns: map_size(state.patterns),
      total_error_occurrences: calculate_total_occurrences(state.patterns),
      top_patterns: get_top_patterns(state.patterns, 5),
      success_rates_tracked: map_size(state.suggestion_success_rates),
      optimization_correlations: state.optimization_correlations,
      learning_enabled: state.learning_enabled,
      last_cleanup: state.last_cleanup
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_manager_call({:get_common_patterns, limit}, _from, state) do
    common_patterns = get_top_patterns(state.patterns, limit)
    {:reply, common_patterns, state}
  end

  @impl true
  def handle_manager_call(:get_optimization_correlations, _from, state) do
    correlations = analyze_optimization_correlations(state)
    {:reply, correlations, state}
  end

  @impl true
  def handle_manager_call({:export_patterns, format}, _from, state) do
    exported_data = Persistence.export(state, format)
    {:reply, exported_data, state}
  end

  @impl true
  def handle_manager_info(:cleanup_and_persist, state) do
    cleaned_patterns = cleanup_old_patterns(state.patterns)
    Persistence.persist(state)
    schedule_cleanup()

    new_state = %{
      state
      | patterns: cleaned_patterns,
        last_cleanup: DateTime.utc_now()
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_manager_info(_msg, state) do
    {:noreply, state}
  end

  # Private implementation

  defp update_pattern_ets(signature, context, timestamp) do
    pattern =
      case :ets.lookup(@table_name, signature) do
        [{^signature, existing_pattern}] ->
          %{
            existing_pattern
            | frequency: existing_pattern.frequency + 1,
              contexts: [context | existing_pattern.contexts] |> Enum.take(10),
              last_seen: timestamp
          }

        [] ->
          %{
            signature: signature,
            frequency: 1,
            contexts: [context],
            successful_fixes: [],
            failure_modes: [],
            optimization_correlation: 0.0,
            prediction_confidence: 0.5,
            first_seen: timestamp,
            last_seen: timestamp
          }
      end

    :ets.insert(@table_name, {signature, pattern})
  end

  defp update_pattern_frequency(patterns, signature, context, timestamp) do
    pattern =
      Map.get(patterns, signature, %{
        signature: signature,
        frequency: 0,
        contexts: [],
        successful_fixes: [],
        failure_modes: [],
        optimization_correlation: 0.0,
        prediction_confidence: 0.5,
        first_seen: timestamp,
        last_seen: timestamp
      })

    updated_pattern = %{
      pattern
      | frequency: pattern.frequency + 1,
        contexts: [context | pattern.contexts] |> Enum.take(10),
        last_seen: timestamp
    }

    Map.put(patterns, signature, updated_pattern)
  end

  defp update_optimization_correlations(correlations, error, _context) do
    error_text = inspect(error) |> String.downcase()

    optimization_terms = %{
      parser: ["parse", "ansi", "sequence", "3.3μs"],
      memory: ["memory", "allocation", "2.8mb", "buffer"],
      render: ["render", "batch", "damage", "frame"],
      optimization: ["optimization", "@raxol_optimized"]
    }

    Enum.reduce(optimization_terms, correlations, fn {category, terms}, acc ->
      correlation_strength =
        Enum.count(terms, &String.contains?(error_text, &1)) / length(terms)

      current_correlation = Map.get(acc, category, 0.0)
      new_correlation = current_correlation * 0.9 + correlation_strength * 0.1
      Map.put(acc, category, new_correlation)
    end)
  end

  defp update_pattern_fixes(patterns, signature, fix_description, outcome) do
    case Map.get(patterns, signature) do
      nil ->
        patterns

      pattern ->
        updated_pattern =
          case outcome do
            :success ->
              %{
                pattern
                | successful_fixes: [fix_description | pattern.successful_fixes]
              }

            :failure ->
              %{
                pattern
                | failure_modes: [fix_description | pattern.failure_modes]
              }
          end

        Map.put(patterns, signature, updated_pattern)
    end
  end

  defp analyze_optimization_correlations(state) do
    %{
      correlations: state.optimization_correlations,
      insights: generate_correlation_insights(state.optimization_correlations),
      recommendations:
        generate_correlation_recommendations(state.optimization_correlations)
    }
  end

  defp generate_correlation_insights(correlations) do
    Enum.map(correlations, fn {category, strength} ->
      cond do
        strength > 0.7 ->
          "High correlation between errors and #{category} optimization"

        strength > 0.4 ->
          "Moderate correlation with #{category} components"

        strength > 0.2 ->
          "Some correlation detected with #{category}"

        true ->
          "Low correlation with #{category}"
      end
    end)
  end

  defp generate_correlation_recommendations(correlations) do
    correlations
    |> Enum.filter(fn {_category, strength} -> strength > 0.5 end)
    |> Enum.map(fn {category, _strength} ->
      case category do
        :parser ->
          "Review ANSI parser implementation for optimization opportunities"

        :memory ->
          "Check memory usage patterns against 2.8MB target"

        :render ->
          "Verify render batching and damage tracking are working correctly"

        :optimization ->
          "Ensure all components have proper @raxol_optimized attributes"
      end
    end)
  end

  defp get_top_patterns(patterns, limit) do
    patterns
    |> Enum.sort_by(fn {_signature, pattern} -> pattern.frequency end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {signature, pattern} ->
      %{
        signature: signature,
        frequency: pattern.frequency,
        success_fixes: length(pattern.successful_fixes),
        failure_modes: length(pattern.failure_modes),
        optimization_correlation: pattern.optimization_correlation
      }
    end)
  end

  defp calculate_total_occurrences(patterns) do
    patterns
    |> Enum.map(fn {_signature, pattern} -> pattern.frequency end)
    |> Enum.sum()
  end

  defp cleanup_old_patterns(patterns) do
    cutoff_date = DateTime.add(DateTime.utc_now(), -30, :day)

    patterns
    |> Enum.filter(fn {_signature, pattern} ->
      DateTime.compare(pattern.last_seen, cutoff_date) == :gt
    end)
    |> Map.new()
  end

  defp should_persist?(_old_state, _new_state) do
    :rand.uniform(10) == 1
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_and_persist, @persist_interval_ms)
  end
end
