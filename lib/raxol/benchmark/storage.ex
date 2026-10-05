defmodule Raxol.Benchmark.Storage do
  alias Raxol.Core.Runtime.Log

  @moduledoc """
  Handles storage and retrieval of benchmark results for historical analysis.

  Provides functionality for saving benchmarks, creating baselines, and
  tracking performance over time.
  """
  @storage_path "bench/results"
  @baseline_path "bench/baselines"
  @snapshot_path "bench/snapshots"

  @doc """
  Saves benchmark results to storage.
  """
  def save_results(suite_name, results, duration) do
    ensure_directories()

    timestamp = DateTime.utc_now()

    # Save raw results
    save_raw_results(suite_name, results, timestamp)

    # Save summary for quick access
    save_summary(suite_name, results, duration, timestamp)

    # Update baseline if requested
    maybe_update_baseline(suite_name, results)

    :ok
  end

  @doc """
  Loads historical results for a suite.
  """
  def load_historical(suite_name, opts \\ []) do
    days = Keyword.get(opts, :days, 30)
    limit = Keyword.get(opts, :limit, 100)

    cutoff_date =
      DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)

    list_result_files(suite_name)
    |> Enum.filter(&after_date?(&1, cutoff_date))
    |> Enum.sort(:desc)
    |> Enum.take(limit)
    |> Enum.map(&load_result_file/1)
    |> Enum.filter(& &1)
  end

  @doc """
  Saves a baseline for comparison.
  """
  def save_baseline(suite_name, results) do
    ensure_directories()

    path = baseline_path(suite_name)
    data = serialize_baseline(results)

    File.write!(path, data)
    Log.info("Baseline saved for #{suite_name}")

    :ok
  end

  @doc """
  Loads a baseline for comparison.
  """
  def load_baseline(suite_name) do
    path = baseline_path(suite_name)

    case File.exists?(path) do
      true -> deserialize_baseline(File.read!(path))
      false -> nil
    end
  end

  @doc """
  Creates a performance snapshot for version tracking.
  """
  def create_snapshot(version, results) do
    ensure_directories()

    snapshot = %{
      version: version,
      timestamp: DateTime.utc_now(),
      results: results,
      metadata: collect_metadata()
    }

    path = snapshot_path(version)
    File.write!(path, :erlang.term_to_binary(snapshot))

    Log.info("Snapshot created for version #{version}")

    :ok
  end

  @doc """
  Loads a snapshot by version.
  """
  def load_snapshot(version) do
    path = snapshot_path(version)

    case File.exists?(path) do
      true -> :erlang.binary_to_term(File.read!(path))
      false -> nil
    end
  end

  @doc """
  Lists available snapshots.
  """
  def list_snapshots do
    ensure_directories()

    Path.wildcard(Path.join(@snapshot_path, "*.snapshot"))
    |> Enum.map(fn path ->
      version = Path.basename(path, ".snapshot")
      {version, File.stat!(path).mtime}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  @doc """
  Exports results to CSV format.
  """
  def export_to_csv(suite_name, output_file) do
    results = load_historical(suite_name, days: 365)

    csv_content = generate_csv(results)
    File.write!(output_file, csv_content)

    Log.info("Results exported to #{output_file}")

    :ok
  end

  @doc """
  Cleans up old benchmark data.
  """
  def cleanup(days_to_keep \\ 90) do
    cutoff_date =
      DateTime.add(DateTime.utc_now(), -days_to_keep * 24 * 60 * 60, :second)

    deleted_count =
      Path.wildcard(Path.join(@storage_path, "**/*.benchee"))
      |> Enum.filter(&before_date?(&1, cutoff_date))
      |> Enum.map(&File.rm/1)
      |> Enum.count(&(&1 == :ok))

    Log.info("Cleaned up #{deleted_count} old benchmark files")

    {:ok, deleted_count}
  end

  # Private functions

  defp ensure_directories do
    [@storage_path, @baseline_path, @snapshot_path]
    |> Enum.each(&File.mkdir_p!/1)
  end

  defp save_raw_results(suite_name, results, timestamp) do
    suite_dir = Path.join(@storage_path, suite_name)
    File.mkdir_p!(suite_dir)

    filename = "#{format_timestamp(timestamp)}.benchee"
    path = Path.join(suite_dir, filename)

    File.write!(path, :erlang.term_to_binary(results))
  end

  defp save_summary(suite_name, results, duration, timestamp) do
    summary = %{
      suite_name: suite_name,
      timestamp: timestamp,
      duration: duration,
      scenarios: Enum.map(results.scenarios, &extract_scenario_summary/1),
      environment: collect_environment()
    }

    suite_dir = Path.join(@storage_path, suite_name)
    filename = "#{format_timestamp(timestamp)}_summary.json"
    path = Path.join(suite_dir, filename)

    File.write!(path, Jason.encode!(summary, pretty: true))
  end

  defp extract_scenario_summary(scenario) do
    %{
      name: scenario.name,
      average: scenario.run_time_data.statistics.average,
      min: scenario.run_time_data.statistics.minimum,
      max: scenario.run_time_data.statistics.maximum,
      std_dev: scenario.run_time_data.statistics.std_dev,
      memory_average: scenario.memory_usage_data.statistics.average
    }
  end

  defp maybe_update_baseline(suite_name, results) do
    case should_update_baseline?(suite_name) do
      true -> update_baseline(suite_name, results)
      false -> :ok
    end
  end

  defp should_update_baseline?(suite_name) do
    # Check if baseline update was requested via environment variable
    System.get_env("UPDATE_BASELINE") == "true" ||
      System.get_env("UPDATE_BASELINE_#{suite_name}") == "true"
  end

  defp update_baseline(suite_name, results) do
    # Backup existing baseline
    backup_baseline(suite_name)

    # Save new baseline
    save_baseline(suite_name, results)
  end

  defp backup_baseline(suite_name) do
    current_path = baseline_path(suite_name)

    case File.exists?(current_path) do
      true ->
        backup_path =
          "#{current_path}.backup.#{DateTime.utc_now() |> DateTime.to_unix()}"

        File.rename!(current_path, backup_path)

      false ->
        :ok
    end
  end

  defp baseline_path(suite_name) do
    Path.join(@baseline_path, "#{suite_name}.baseline")
  end

  defp snapshot_path(version) do
    Path.join(@snapshot_path, "#{version}.snapshot")
  end

  defp serialize_baseline(results) do
    :erlang.term_to_binary(results)
  end

  defp deserialize_baseline(data) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           :erlang.binary_to_term(data)
         end) do
      {:ok, result} -> result
      {:error, _} -> nil
    end
  end

  defp list_result_files(suite_name) do
    suite_dir = Path.join(@storage_path, suite_name)

    case File.dir?(suite_dir) do
      true -> Raxol.Utils.Glob.under(suite_dir, "*.benchee")
      false -> []
    end
  end

  defp after_date?(file_path, date) do
    case extract_timestamp_from_path(file_path) do
      {:ok, file_date} -> DateTime.compare(file_date, date) == :gt
      _ -> false
    end
  end

  defp before_date?(file_path, date) do
    case extract_timestamp_from_path(file_path) do
      {:ok, file_date} -> DateTime.compare(file_date, date) == :lt
      _ -> false
    end
  end

  defp extract_timestamp_from_path(path) do
    filename = Path.basename(path, ".benchee")

    case parse_timestamp(filename) do
      {:ok, datetime} -> {:ok, datetime}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp load_result_file(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_binary_term(content)

      _ ->
        nil
    end
  end

  defp collect_metadata do
    %{
      elixir_version: System.version(),
      otp_version: :erlang.system_info(:otp_release) |> List.to_string(),
      git_sha: get_git_sha(),
      branch: get_git_branch()
    }
  end

  defp collect_environment do
    {family, name} = :os.type()

    %{
      os: "#{family}_#{name}",
      cpu_count: System.schedulers_online(),
      total_memory: :erlang.memory(:total)
    }
  end

  defp get_git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"]) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp get_git_branch do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {branch, 0} -> String.trim(branch)
      _ -> "unknown"
    end
  end

  defp format_timestamp(datetime) do
    datetime
    |> DateTime.to_string()
    |> String.replace(~r/[^\d]/, "_")
  end

  defp parse_timestamp(string) do
    # Parse timestamp from format: "2024_01_15_10_30_45_123456Z"
    case Regex.run(~r/(\d{4})_(\d{2})_(\d{2})_(\d{2})_(\d{2})_(\d{2})/, string) do
      [_, year, month, day, hour, minute, second] ->
        DateTime.new(
          Date.new!(
            String.to_integer(year),
            String.to_integer(month),
            String.to_integer(day)
          ),
          Time.new!(
            String.to_integer(hour),
            String.to_integer(minute),
            String.to_integer(second)
          )
        )

      _ ->
        :error
    end
  end

  defp generate_csv(results) do
    headers = "Timestamp,Suite,Scenario,Average,Min,Max,StdDev,Memory\n"

    rows =
      Enum.flat_map(results, fn result ->
        Enum.map(result.scenarios, fn scenario ->
          [
            result.timestamp,
            result.suite_name,
            scenario.name,
            scenario.run_time_data.statistics.average,
            scenario.run_time_data.statistics.minimum,
            scenario.run_time_data.statistics.maximum,
            scenario.run_time_data.statistics.std_dev,
            scenario.memory_usage_data.statistics.average
          ]
          |> Enum.join(",")
        end)
      end)

    headers <> Enum.join(rows, "\n")
  end

  defp parse_binary_term(content) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           :erlang.binary_to_term(content)
         end) do
      {:ok, result} -> result
      {:error, _} -> nil
    end
  end
end
