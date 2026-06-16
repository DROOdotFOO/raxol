defmodule Raxol.Core.ErrorPatternLearner.Predictor do
  @moduledoc """
  Prediction and suggestion enhancement for ErrorPatternLearner.
  All functions are pure and operate on the learner state map.
  """

  @doc """
  Generates predictions for likely errors given current context.
  Returns up to 3 predictions sorted by confidence descending.
  """
  def generate_predictions(state, context) do
    state.patterns
    |> Enum.filter(fn {_signature, pattern} ->
      pattern.frequency > 2 &&
        context_similarity(pattern.contexts, context) > 0.3
    end)
    |> Enum.map(fn {signature, pattern} ->
      confidence = calculate_prediction_confidence(pattern, context)

      %{
        signature: signature,
        predicted_error: pattern,
        confidence: confidence,
        prevention_suggestions: generate_prevention_suggestions(pattern)
      }
    end)
    |> Enum.sort_by(& &1.confidence, :desc)
    |> Enum.take(3)
  end

  @doc """
  Enhances base suggestions with learned success rates and patterns from similar errors.
  """
  def enhance_suggestions(state, error, base_suggestions, context) do
    error_signature = generate_error_signature(error)

    enhanced_suggestions =
      Enum.map(base_suggestions, fn suggestion ->
        fix_key = "#{error_signature}:#{suggestion.description}"

        learned_confidence =
          Map.get(
            state.suggestion_success_rates,
            fix_key,
            suggestion.confidence
          )

        final_confidence = (suggestion.confidence + learned_confidence) / 2.0
        %{suggestion | confidence: final_confidence}
      end)

    learned_suggestions =
      get_learned_suggestions(state, error_signature, context)

    (enhanced_suggestions ++ learned_suggestions)
    |> Enum.uniq_by(& &1.description)
    |> Enum.sort_by(& &1.confidence, :desc)
  end

  @doc "Generates the MD5-based signature for an error term."
  def generate_error_signature(error) do
    error_text = inspect(error) |> String.downcase()

    components =
      [
        extract_error_type(error_text),
        extract_module_path(error_text),
        extract_key_terms(error_text)
      ]
      |> Enum.filter(&(&1 != ""))
      |> Enum.join(":")

    :crypto.hash(:md5, components)
    |> Base.encode16(case: :lower)
    |> String.slice(0..15)
  end

  # --- private ---

  defp extract_error_type(error_text) do
    cond do
      String.contains?(error_text, "timeout") -> "timeout"
      String.contains?(error_text, "memory") -> "memory"
      String.contains?(error_text, "parse") -> "parse"
      String.contains?(error_text, "render") -> "render"
      String.contains?(error_text, "component") -> "component"
      true -> "generic"
    end
  end

  defp extract_module_path(error_text) do
    case Regex.run(~r/Raxol\.\w+(?:\.\w+)*/, error_text) do
      [module_path] -> module_path
      _ -> ""
    end
  end

  defp extract_key_terms(error_text) do
    error_text
    |> String.split()
    |> Enum.filter(
      &(String.length(&1) > 3 and String.match?(&1, ~r/^[a-zA-Z_]+$/))
    )
    |> Enum.take(3)
    |> Enum.join("_")
  end

  defp context_similarity(pattern_contexts, current_context) do
    if pattern_contexts == [] do
      0.0
    else
      similarities =
        Enum.map(
          pattern_contexts,
          &calculate_context_overlap(&1, current_context)
        )

      Enum.sum(similarities) / length(similarities)
    end
  end

  defp calculate_context_overlap(context1, context2) do
    common_keys =
      MapSet.intersection(
        MapSet.new(Map.keys(context1)),
        MapSet.new(Map.keys(context2))
      )

    if MapSet.size(common_keys) == 0 do
      0.0
    else
      matching_values =
        Enum.count(common_keys, fn key ->
          Map.get(context1, key) == Map.get(context2, key)
        end)

      matching_values / MapSet.size(common_keys)
    end
  end

  defp calculate_prediction_confidence(pattern, context) do
    base_confidence = min(0.9, pattern.frequency / 10.0)
    context_boost = context_similarity(pattern.contexts, context) * 0.2
    min(0.95, base_confidence + context_boost)
  end

  defp generate_prevention_suggestions(pattern) do
    case pattern.successful_fixes do
      [] ->
        ["Monitor for similar error patterns"]

      fixes ->
        ["Consider preventive measures based on: #{Enum.join(fixes, ", ")}"]
    end
  end

  defp get_learned_suggestions(state, error_signature, context) do
    state.patterns
    |> Enum.filter(fn {signature, pattern} ->
      signature != error_signature &&
        (String.jaro_distance(signature, error_signature) > 0.7 ||
           context_similarity(pattern.contexts, context) > 0.5)
    end)
    |> Enum.take(3)
    |> Enum.flat_map(fn {_signature, pattern} ->
      Enum.map(pattern.successful_fixes, fn fix ->
        %{
          type: :learned,
          description: "Learned suggestion: #{fix}",
          action: fix,
          confidence: 0.7,
          related_tools: [],
          optimization_context: %{
            source: "learned_pattern",
            frequency: pattern.frequency
          }
        }
      end)
    end)
    |> Enum.take(2)
  end
end
