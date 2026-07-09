defmodule Raxol.Benchmark.Config do
  @moduledoc """
  Configuration and utilities for Raxol performance benchmarking.
  Centralizes benchmark settings, performance targets, and reporting configuration.

  ## Features
  - Profile-based configuration (quick, standard, comprehensive, ci)
  - Dynamic performance targets with statistical thresholds
  - Environment-aware settings
  - Regression detection with configurable sensitivity
  - Benchmark metadata and tagging
  """

  require Logger

  # Environment-based configuration overrides
  @env_overrides %{
    "CI" => %{
      time_multiplier: 0.5,
      warmup_multiplier: 0.3,
      parallel: System.schedulers_online(),
      save_results: true
    },
    "BENCHMARK_PROFILE" => %{
      "quick" => :quick,
      "standard" => :standard,
      "comprehensive" => :comprehensive,
      "ci" => :ci
    }
  }

  # Statistical significance thresholds
  @statistical_config %{
    confidence_level: 0.95,
    min_sample_size: 30,
    outlier_percentile: 95,
    stability_coefficient: 0.05
  }

  # Benchmark metadata tags
  @metadata_tags %{
    categories: ["parser", "terminal", "rendering", "memory", "integration"],
    priorities: [:critical, :high, :medium, :low],
    stability: [:stable, :unstable, :flaky],
    platforms: [:linux, :macos, :windows]
  }

  @performance_targets %{
    # Parser performance targets (microseconds)
    "parser" => %{
      "plain_text_parse" => 50,
      "ansi_basic_parse" => 10,
      "ansi_complex_parse" => 15,
      "mixed_content_parse" => 25
    },

    # Terminal component targets (microseconds)
    "terminal" => %{
      "emulator_creation" => 1000,
      "buffer_write_char" => 5,
      "buffer_write_string" => 20,
      "cursor_movement" => 3,
      "sgr_processing" => 1
    },

    # Rendering targets (milliseconds)
    "rendering" => %{
      "small_buffer_render" => 0.5,
      "medium_buffer_render" => 1.0,
      "large_buffer_render" => 2.0,
      "colored_render" => 1.5,
      "unicode_render" => 2.0
    },

    # Memory targets (MB)
    "memory" => %{
      "emulator_80x24" => 3.0,
      "emulator_200x50" => 8.0,
      "buffer_operations" => 5.0
    }
  }

  @regression_thresholds %{
    # Percentage increase that triggers a regression warning
    "parser" => 10,
    "terminal" => 15,
    "rendering" => 5,
    "memory" => 20
  }

  @benchmark_configs %{
    quick: [
      time: 1,
      memory_time: 0.5,
      warmup: 0.2,
      parallel: 1
    ],
    standard: [
      time: 5,
      memory_time: 2,
      warmup: 1,
      parallel: 1
    ],
    comprehensive: [
      time: 10,
      memory_time: 5,
      warmup: 2,
      parallel: 1
    ],
    ci: [
      time: 3,
      memory_time: 1,
      warmup: 0.5,
      parallel: 1
    ]
  }

  @doc """
  Get performance targets for a specific benchmark category.
  Applies environment-based adjustments if configured.
  """
  def get_targets(category, opts \\ [])

  def get_targets(category, opts)
      when category in ["parser", "terminal", "rendering", "memory"] do
    base_targets = Map.get(@performance_targets, category, %{})

    if Keyword.get(opts, :adjust_for_env, true) do
      apply_env_adjustments(base_targets)
    else
      base_targets
    end
  end

  def get_targets(_, _), do: %{}

  @doc """
  Get all performance targets.
  """
  def all_targets, do: @performance_targets

  @doc """
  Get regression threshold for a category (percentage).
  """
  def regression_threshold(category) do
    Map.get(@regression_thresholds, category, 10)
  end

  @doc """
  Get benchmark configuration by type.
  Supports environment variable overrides and profile inheritance.
  """
  def benchmark_config(type \\ nil) do
    type = resolve_profile(type)

    unless type in [:quick, :standard, :comprehensive, :ci] do
      raise ArgumentError, "Invalid benchmark type: #{inspect(type)}"
    end

    base_config = Map.get(@benchmark_configs, type)

    # Apply environment-based adjustments
    config = apply_env_config(base_config, type)

    # Add formatters based on type
    formatters = get_formatters(type)

    config
    |> Keyword.put(:formatters, formatters)
    |> Keyword.put(:profile, type)
    |> add_metadata()
  end

  @doc """
  Generate timestamped output paths for benchmark results.
  """
  def output_paths(timestamp \\ nil) do
    ts = timestamp || DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      json: "bench/output/enhanced/json/benchmark_#{ts}.json",
      html: "bench/output/enhanced/html/benchmark_#{ts}.html",
      dashboard: "bench/output/enhanced/dashboard_#{ts}.html",
      regression: "bench/output/enhanced/regression_#{ts}.md",
      insights: "bench/output/enhanced/insights_#{ts}.md"
    }
  end

  @doc """
  Ensure output directories exist.
  Creates profile-specific subdirectories if needed.
  """
  def ensure_output_dirs(profile \\ nil) do
    base_dirs = [
      "bench/output/enhanced",
      "bench/output/enhanced/json",
      "bench/output/enhanced/html",
      "bench/output/enhanced/assets",
      "bench/output/snapshots",
      "bench/output/comparisons"
    ]

    profile_dirs =
      if profile do
        Enum.map(base_dirs, &"#{&1}/#{profile}")
      else
        []
      end

    (base_dirs ++ profile_dirs)
    |> Enum.each(&File.mkdir_p!/1)
  end

  @doc """
  Check if a benchmark result meets performance targets.
  Includes statistical significance check when sufficient samples available.
  """
  def meets_target?(category, benchmark_name, result_us, opts \\ []) do
    targets = get_targets(category)
    target = Map.get(targets, benchmark_name)

    case target do
      nil ->
        {:unknown, "No target defined for #{benchmark_name}"}

      target_us ->
        deviation_pct = (result_us / target_us - 1) * 100

        # Check statistical significance if samples provided
        significance =
          if samples = Keyword.get(opts, :samples) do
            check_statistical_significance(samples, target_us)
          else
            nil
          end

        cond do
          result_us <= target_us ->
            {:pass,
             format_target_result(
               result_us,
               target_us,
               deviation_pct,
               significance
             )}

          significance == :not_significant ->
            {:warning,
             "#{result_us}μs vs #{target_us}μs target (not statistically significant)"}

          true ->
            {:fail,
             format_target_result(
               result_us,
               target_us,
               deviation_pct,
               significance
             )}
        end
    end
  end

  @doc """
  Detect performance regressions by comparing results.
  """
  def detect_regression(category, old_result_us, new_result_us) do
    threshold = regression_threshold(category)
    increase_percent = (new_result_us / old_result_us - 1) * 100

    cond do
      increase_percent > threshold ->
        {:regression,
         "#{Float.round(increase_percent, 1)}% increase (threshold: #{threshold}%)"}

      increase_percent > threshold / 2 ->
        {:warning,
         "#{Float.round(increase_percent, 1)}% increase (watch for regression)"}

      increase_percent < -10 ->
        {:improvement, "#{Float.round(-increase_percent, 1)}% improvement"}

      true ->
        {:stable,
         "#{Float.round(increase_percent, 1)}% change (within threshold)"}
    end
  end

  @doc """
  Generate test scenarios for different benchmark categories.
  """
  def test_scenarios(category) do
    case category do
      :parser -> parser_scenarios()
      :terminal -> terminal_scenarios()
      :rendering -> rendering_scenarios()
      :memory -> memory_scenarios()
      _ -> %{}
    end
  end

  @doc """
  Load previous benchmark results for comparison.
  """
  def load_previous_results(category) do
    pattern = "bench/output/enhanced/json/*_#{category}_*.json"

    Path.wildcard(pattern)
    |> Enum.sort()
    |> Enum.reverse()
    |> List.first()
    |> case do
      nil -> nil
      file -> read_and_parse_baseline_file(file)
    end
  end

  @doc """
  Validate benchmark configuration.
  Ensures all required settings are present and valid.
  """
  def validate_config(config) do
    required_keys = [:time, :warmup]

    missing_keys =
      required_keys
      |> Enum.reject(&Keyword.has_key?(config, &1))

    if Enum.empty?(missing_keys) do
      {:ok, config}
    else
      {:error, "Missing required config keys: #{inspect(missing_keys)}"}
    end
  end

  @doc """
  Get statistical configuration.
  """
  def statistical_config, do: @statistical_config

  @doc """
  Get available metadata tags.
  """
  def metadata_tags, do: @metadata_tags

  @doc """
  Calculate dynamic threshold based on historical data.
  """
  def calculate_dynamic_threshold(category, _benchmark_name, history \\ []) do
    if Enum.empty?(history) do
      # Fallback to static threshold
      regression_threshold(category)
    else
      # Calculate based on historical variance
      mean = Enum.sum(history) / length(history)
      variance = calculate_variance(history, mean)
      std_dev = :math.sqrt(variance)

      # Dynamic threshold: mean + (2 * standard deviation)
      min_threshold = regression_threshold(category) / 2
      max_threshold = regression_threshold(category) * 2

      threshold_pct = std_dev / mean * 200

      threshold_pct
      |> max(min_threshold)
      |> min(max_threshold)
    end
  end

  # Private helper functions

  @spec resolve_profile(nil | atom() | binary()) :: atom()
  defp resolve_profile(nil) do
    case System.get_env("BENCHMARK_PROFILE") do
      nil -> :standard
      profile -> String.to_existing_atom(profile)
    end
  end

  defp resolve_profile(type) when is_atom(type), do: type

  defp resolve_profile(type) when is_binary(type),
    do: String.to_existing_atom(type)

  @spec apply_env_config(Keyword.t(), atom()) :: Keyword.t()
  defp apply_env_config(config, _type) do
    if System.get_env("CI") do
      %{
        time_multiplier: time_mult,
        warmup_multiplier: warmup_mult,
        parallel: parallel
      } =
        Map.fetch!(@env_overrides, "CI")

      config
      |> Keyword.update(:time, config[:time], &(&1 * time_mult))
      |> Keyword.update(:warmup, config[:warmup], &(&1 * warmup_mult))
      |> Keyword.put(:parallel, parallel)
    else
      config
    end
  end

  defp apply_env_adjustments(targets) do
    if System.get_env("CI") do
      # Relax targets by 20% in CI environment
      Map.new(targets, fn {k, v} -> {k, v * 1.2} end)
    else
      targets
    end
  end

  defp get_formatters(type) do
    case type do
      :quick ->
        [Benchee.Formatters.Console]

      :ci ->
        [
          Benchee.Formatters.Console,
          {Benchee.Formatters.JSON, file: "bench/output/ci_results.json"}
        ]

      _ ->
        default_formatters()
    end
  end

  defp add_metadata(config) do
    metadata = %{
      timestamp: DateTime.utc_now(),
      elixir_version: System.version(),
      otp_version: :erlang.system_info(:otp_release) |> to_string(),
      system: %{
        os: :os.type(),
        cpus: System.schedulers_online(),
        arch: :erlang.system_info(:system_architecture)
      },
      git_sha: get_git_sha()
    }

    Keyword.put(config, :metadata, metadata)
  end

  defp get_git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"]) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  rescue
    e ->
      Logger.warning("Failed to get git SHA: #{Exception.message(e)}")
      "unknown"
  end

  defp check_statistical_significance(samples, target) when is_list(samples) do
    if length(samples) >= @statistical_config.min_sample_size do
      mean = Enum.sum(samples) / length(samples)
      variance = calculate_variance(samples, mean)
      std_dev = :math.sqrt(variance)

      # Calculate z-score
      z_score = abs(mean - target) / (std_dev / :math.sqrt(length(samples)))

      # Check against critical value for 95% confidence
      if z_score > 1.96 do
        :significant
      else
        :not_significant
      end
    else
      :insufficient_samples
    end
  end

  defp check_statistical_significance(_, _), do: nil

  defp calculate_variance(samples, mean) do
    sum_squared_diff =
      samples
      |> Enum.map(fn x -> :math.pow(x - mean, 2) end)
      |> Enum.sum()

    sum_squared_diff / length(samples)
  end

  defp format_target_result(result_us, target_us, deviation_pct, significance) do
    base_msg =
      "#{result_us}μs vs #{target_us}μs target (#{Float.round(abs(deviation_pct), 1)}%"

    significance_suffix =
      case significance do
        :significant -> ", statistically significant"
        :not_significant -> ", not significant"
        :insufficient_samples -> ", insufficient samples"
        _ -> ""
      end

    direction = if deviation_pct > 0, do: "over", else: "under"

    "#{base_msg} #{direction}#{significance_suffix})"
  end

  defp default_formatters do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    paths = output_paths(timestamp)

    [
      Benchee.Formatters.Console,
      {Benchee.Formatters.JSON, file: paths.json},
      {Benchee.Formatters.HTML,
       file: paths.html, title: "Raxol Performance Report"}
    ]
  end

  defp parser_scenarios do
    %{
      "plain_text_short" => "Hello, World!",
      "plain_text_medium" =>
        String.duplicate("Lorem ipsum dolor sit amet. ", 20),
      "plain_text_long" =>
        String.duplicate("Performance testing content. ", 100),
      "ansi_basic_color" => "\e[31mRed Text\e[0m",
      "ansi_complex_sgr" =>
        "\e[1;4;31;48;5;196mBold Underlined Red on Bright Red\e[0m",
      "ansi_cursor_commands" => "\e[2J\e[H\e[10;20H\e[K\e[2K\e[J",
      "ansi_scroll_region" =>
        "\e[5;20r\e[?25l\e[33mScrolling text\e[?25h\e[0;0r",
      "ansi_device_control" => "\e]0;Window Title\e\\\e[?1049h\e[?2004h",
      "mixed_realistic" => realistic_terminal_content(),
      "rapid_color_changes" => rapid_color_sequence(),
      "large_ansi_dump" => large_ansi_content(),
      "terminal_app_simulation" => terminal_app_content()
    }
  end

  defp terminal_scenarios do
    %{
      "emulator_80x24" => {80, 24},
      "emulator_132x43" => {132, 43},
      "emulator_200x50" => {200, 50},
      "buffer_small" => {20, 10},
      "buffer_medium" => {80, 24},
      "buffer_large" => {200, 50}
    }
  end

  defp rendering_scenarios do
    %{
      "empty_buffer" => :empty,
      "text_only" => :text_only,
      "colors_basic" => :colors_basic,
      "colors_complex" => :colors_complex,
      "unicode_mixed" => :unicode_mixed,
      "large_content" => :large_content
    }
  end

  defp memory_scenarios do
    %{
      "baseline_emulator" => :baseline,
      "filled_buffer" => :filled,
      "long_session" => :long_session,
      "rapid_updates" => :rapid_updates
    }
  end

  defp realistic_terminal_content do
    """
    \e[2J\e[H\e[1;37;44m Raxol Terminal Session \e[0m
    \e[2;1H\e[32mStatus:\e[0m Connected to server
    \e[3;1H\e[33mProgress:\e[0m \e[32m████████████\e[37m░░░░░░░░\e[0m 60%
    \e[5;1H\e[1mAvailable Commands:\e[0m
    \e[6;3H\e[36m1.\e[0m Process data files
    \e[7;3H\e[36m2.\e[0m Generate reports
    \e[8;3H\e[36m3.\e[0m View system status
    \e[9;3H\e[36m4.\e[0m Exit application
    \e[11;1H\e[33mLast operation:\e[0m File processing completed
    \e[12;1H\e[32mMemory usage:\e[0m 45% of available
    \e[13;1H\e[31mWarnings:\e[0m 0 issues detected
    \e[15;1H\e[7m Press [ENTER] to continue \e[0m
    """
  end

  defp rapid_color_sequence do
    Enum.map_join(1..50, " ", fn i ->
      color = rem(i, 8) + 30
      "\e[#{color}m#{i}\e[0m"
    end)
  end

  defp large_ansi_content do
    Enum.map_join(1..200, "", fn i ->
      row = rem(i, 24) + 1
      col = rem(i * 3, 70) + 1
      color = rem(i, 8) + 30
      bg_color = rem(i, 8) + 40

      "\e[#{row};#{col}H\e[#{color};#{bg_color}mItem #{i}\e[0m"
    end)
  end

  defp terminal_app_content do
    """
    \e[?1049h\e[2J\e[H\e[?25l
    \e[1;1H\e[37;44m Terminal Application v#{Raxol.version()} \e[0m\e[1;25H\e[37;44m [Help: F1] \e[0m
    \e[3;1H\e[1mSystem Monitoring Dashboard\e[0m
    \e[5;1H\e[33mCPU Usage:\e[0m
    \e[6;3H\e[32m██████████████\e[37m░░░░░░░░░░░░░░░░\e[0m 47%
    \e[8;1H\e[33mMemory Usage:\e[0m
    \e[9;3H\e[31m████████████████████\e[37m░░░░░░░░░░\e[0m 67%
    \e[11;1H\e[33mDisk I/O:\e[0m
    \e[12;3H\e[36mRead:  ████\e[37m░░░░░░░░░░░░░░░░░░░░░░░░░░\e[0m 15%
    \e[13;3H\e[36mWrite: ██████████\e[37m░░░░░░░░░░░░░░░░░░░░\e[0m 33%
    \e[15;1H\e[33mNetwork:\e[0m
    \e[16;3H\e[35mUp:   \e[32m15.2 MB/s\e[0m
    \e[17;3H\e[35mDown: \e[32m43.7 MB/s\e[0m
    \e[19;1H\e[1mActive Processes:\e[0m \e[32m127\e[0m
    \e[20;1H\e[1mSystem Load:\e[0m \e[33m2.34\e[0m
    \e[22;1H\e[7m F1:Help F2:Config F5:Refresh F10:Exit \e[0m
    \e[?25h
    """
  end

  defp read_and_parse_baseline_file(file) do
    case File.read(file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> data
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
