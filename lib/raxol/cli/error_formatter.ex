defmodule Raxol.CLI.ErrorFormatter do
  @moduledoc """
  Formats ErrorExperience suggestions for CLI output.

  Bridges the sophisticated error analysis from `Raxol.Core.ErrorExperience`
  to user-friendly CLI output using the `Raxol.CLI.Colors` palette.

  ## Usage

      # Format and display an error with suggestions
      ErrorFormatter.format_error(error, context)

      # Get formatted string without printing
      output = ErrorFormatter.to_string(error, context)

      # Use in Mix tasks
      case compile_project() do
        {:error, reason} ->
          ErrorFormatter.format_error(reason, %{task: :compile})
          Mix.raise("Compilation failed")
        :ok -> :ok
      end
  """

  alias Raxol.CLI.Colors
  alias Raxol.Core.ErrorExperience

  @doc """
  Formats and prints an error with intelligent suggestions.

  Analyzes the error, generates suggestions, and displays them
  in a user-friendly CLI format.
  """
  @spec format_error(term(), map()) :: :ok
  def format_error(error, context \\ %{}) do
    enhanced = ErrorExperience.classify_and_enhance(error, context)
    output = format_enhanced_error(enhanced)
    IO.puts(output)
    :ok
  end

  @doc """
  Returns formatted error string without printing.
  """
  @spec to_string(term(), map()) :: String.t()
  def to_string(error, context \\ %{}) do
    enhanced = ErrorExperience.classify_and_enhance(error, context)
    format_enhanced_error(enhanced)
  end

  @doc """
  Formats an already-enhanced error structure.
  """
  @spec format_enhanced(ErrorExperience.enhanced_error()) :: :ok
  def format_enhanced(enhanced_error) do
    output = format_enhanced_error(enhanced_error)
    IO.puts(output)
    :ok
  end

  # ============================================================================
  # Formatting Functions
  # ============================================================================

  defp format_enhanced_error(enhanced) do
    sections = [
      format_header(enhanced),
      format_error_details(enhanced),
      format_suggestions(enhanced.suggestions),
      format_performance_context(enhanced),
      format_next_steps(enhanced)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_header(enhanced) do
    severity_indicator = severity_to_indicator(enhanced.severity)
    category = enhanced.category |> Atom.to_string() |> String.replace("_", " ")

    """
    #{Colors.divider("-", 60)}
    #{severity_indicator} #{Colors.bold(String.upcase(category) <> " ERROR")}
    #{Colors.divider("-", 60)}
    """
  end

  defp format_error_details(enhanced) do
    impact_color = impact_to_color(enhanced.performance_impact)

    base_lines = [
      "  #{Colors.muted("Category:")} #{enhanced.category}",
      "  #{Colors.muted("Severity:")} #{enhanced.severity}",
      "  #{Colors.muted("Impact:")} #{impact_color.(Atom.to_string(enhanced.performance_impact))}"
    ]

    related_line =
      case enhanced.related_optimizations do
        [] -> []
        opts -> ["  #{Colors.muted("Related:")} #{Enum.join(opts, ", ")}"]
      end

    (base_lines ++ related_line)
    |> Enum.join("\n")
  end

  defp format_suggestions([]), do: nil

  defp format_suggestions(suggestions) do
    header = "\n#{Colors.section_header("Suggestions")}\n"

    formatted =
      suggestions
      |> Enum.take(3)
      |> Enum.with_index(1)
      |> Enum.map_join("\n", &format_single_suggestion/1)

    header <> formatted
  end

  defp format_single_suggestion({suggestion, index}) do
    confidence_pct = trunc(suggestion.confidence * 100)
    confidence_bar = confidence_indicator(suggestion.confidence)

    type_badge =
      case suggestion.type do
        :automatic -> Colors.success("[AUTO]")
        :guided -> Colors.info("[GUIDED]")
        :manual -> Colors.warning("[MANUAL]")
        :documentation -> Colors.muted("[DOCS]")
      end

    base_lines = [
      "  #{Colors.bold("#{index}.")} #{suggestion.description}",
      "     #{type_badge} #{confidence_bar} #{confidence_pct}% confidence"
    ]

    action_line =
      if suggestion.action do
        ["     #{Colors.muted("Run:")} #{Colors.info(suggestion.action)}"]
      else
        []
      end

    Enum.join(base_lines ++ action_line, "\n")
  end

  defp format_performance_context(%{performance_impact: :none}), do: nil

  defp format_performance_context(enhanced) do
    header = "\n#{Colors.subsection_header("Performance Context")}\n"

    lines = ["  Impact: #{enhanced.performance_impact}"]

    lines =
      case enhanced.context[:optimization_targets] do
        nil ->
          lines

        targets ->
          lines ++
            Enum.map(targets, fn {k, v} ->
              "  Target #{k}: #{v}"
            end)
      end

    header <> Enum.join(lines, "\n")
  end

  defp format_next_steps(enhanced) do
    header = "\n#{Colors.subsection_header("Next Steps")}\n"

    steps =
      enhanced.suggestions
      |> Enum.take(2)
      |> Enum.filter(& &1.action)
      |> Enum.map(fn s ->
        "  #{Colors.muted("->")} #{Colors.info(s.action)}"
      end)

    case steps do
      [] ->
        header <>
          "  #{Colors.muted("Run")} #{Colors.info("mix raxol.debug")} #{Colors.muted("for investigation")}"

      _ ->
        header <> Enum.join(steps, "\n")
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp severity_to_indicator(severity) do
    case severity do
      :critical -> Colors.error("[!!]")
      :error -> Colors.status_indicator(:error)
      :warning -> Colors.status_indicator(:warning)
      :info -> Colors.status_indicator(:info)
      :debug -> Colors.muted("[..]")
    end
  end

  defp impact_to_color(impact) do
    case impact do
      :critical -> &Colors.error/1
      :high -> &Colors.error/1
      :medium -> &Colors.warning/1
      :low -> &Colors.info/1
      :none -> &Colors.muted/1
    end
  end

  defp confidence_indicator(confidence) when confidence >= 0.8,
    do: Colors.success("***")

  defp confidence_indicator(confidence) when confidence >= 0.6,
    do: Colors.info("**")

  defp confidence_indicator(confidence) when confidence >= 0.4,
    do: Colors.warning("*")

  defp confidence_indicator(_), do: Colors.muted("*")
end
