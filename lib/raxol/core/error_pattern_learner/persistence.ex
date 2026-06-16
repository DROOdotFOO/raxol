defmodule Raxol.Core.ErrorPatternLearner.Persistence do
  @moduledoc """
  Load, save, import, and export functions for ErrorPatternLearner.
  All I/O is isolated here; the GenServer delegates persistence work to this module.
  """

  alias Raxol.Core.Runtime.Log

  @learning_storage "/tmp/raxol_pattern_learning"

  @doc "Returns the configured storage directory."
  def storage_dir, do: @learning_storage

  @doc "Loads learned patterns from disk, returning an initial learner state struct."
  def load_initial_state(struct_module) do
    File.mkdir_p!(@learning_storage)
    patterns = load_patterns_from_disk()

    struct(struct_module, %{
      patterns: patterns,
      suggestion_success_rates: %{},
      optimization_correlations: initial_optimization_correlations(),
      prediction_models: %{},
      learning_enabled: true,
      last_cleanup: DateTime.utc_now()
    })
  end

  @doc "Persists the current learner state to disk synchronously."
  def persist(state) do
    patterns_file = Path.join(@learning_storage, "patterns.json")

    data = %{
      patterns: state.patterns,
      suggestion_success_rates: state.suggestion_success_rates,
      optimization_correlations: state.optimization_correlations,
      last_updated: DateTime.utc_now()
    }

    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        File.write!(patterns_file, json)
        Log.debug("Error patterns persisted successfully")
        :ok

      {:error, reason} ->
        Log.error("Failed to persist error patterns: #{reason}")
        :ok
    end
  end

  @doc "Persists asynchronously in a Task."
  def persist_async(state) do
    {:ok, _pid} = Task.start(fn -> persist(state) end)
    :ok
  end

  @doc "Exports the learner state in the given format (:json | :csv | other)."
  def export(state, format) do
    data = %{
      patterns: state.patterns,
      suggestion_success_rates: state.suggestion_success_rates,
      optimization_correlations: state.optimization_correlations,
      export_timestamp: DateTime.utc_now()
    }

    case format do
      :json -> Jason.encode!(data, pretty: true)
      :csv -> export_to_csv(data)
      _ -> data
    end
  end

  @doc "Parses imported JSON pattern data, returning a patterns map."
  def parse_imported(patterns_data) do
    case Jason.decode(patterns_data) do
      {:ok, data} -> parse_stored_patterns(data)
      _ -> %{}
    end
  end

  @doc "Returns the initial optimization correlations map."
  def initial_optimization_correlations do
    %{parser: 0.0, memory: 0.0, render: 0.0, optimization: 0.0}
  end

  # --- private ---

  defp load_patterns_from_disk do
    patterns_file = Path.join(@learning_storage, "patterns.json")

    with true <- File.exists?(patterns_file),
         {:ok, content} <- File.read(patterns_file),
         {:ok, data} <- Jason.decode(content) do
      parse_stored_patterns(data)
    else
      _ -> %{}
    end
  end

  defp export_to_csv(data) do
    headers =
      "signature,frequency,successful_fixes,failure_modes,optimization_correlation\n"

    rows =
      data.patterns
      |> Enum.map_join("\n", fn {signature, pattern} ->
        "#{signature},#{pattern.frequency},#{length(pattern.successful_fixes)},#{length(pattern.failure_modes)},#{pattern.optimization_correlation}"
      end)

    headers <> rows
  end

  defp parse_stored_patterns(data) do
    Map.get(data, "patterns", %{})
    |> Enum.map(fn {signature, pattern_data} ->
      {signature, parse_pattern_data(pattern_data)}
    end)
    |> Map.new()
  end

  defp parse_pattern_data(data) do
    %{
      signature: data["signature"],
      frequency: data["frequency"] || 0,
      contexts: data["contexts"] || [],
      successful_fixes: data["successful_fixes"] || [],
      failure_modes: data["failure_modes"] || [],
      optimization_correlation: data["optimization_correlation"] || 0.0,
      prediction_confidence: data["prediction_confidence"] || 0.5,
      first_seen: parse_datetime(data["first_seen"]),
      last_seen: parse_datetime(data["last_seen"])
    }
  end

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime
  defp parse_datetime(_datetime), do: DateTime.utc_now()
end
