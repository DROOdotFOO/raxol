defmodule Mix.Tasks.Raxol.Bench.MemoryAnalysis do
  @compile {:no_warn_undefined, Benchee}

  @moduledoc """
  Advanced memory analysis task.

  This task showcases the integration of:
  - MemoryAnalyzer for pattern analysis
  - MemoryDSL for enhanced assertions
  - MemoryDashboard for visual reporting

  Usage:
    mix raxol.bench.memory_analysis
    mix raxol.bench.memory_analysis --scenario terminal_operations
    mix raxol.bench.memory_analysis --with-dashboard
  """

  use Mix.Task
  alias Raxol.Benchmark.{MemoryAnalyzer, MemoryDashboard}

  @shortdoc "Run advanced memory analysis benchmarks with pattern detection"

  @spec run(list()) :: no_return()
  def run(args) do
    opts = parse_options(args)
    _ = Application.ensure_all_started(:raxol)

    config = build_config(opts)
    print_config_info(config)

    results = run_scenario(config.scenario, config.benchmark_config)
    process_results(results, config)
  end

  defp parse_options(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          scenario: :string,
          with_dashboard: :boolean,
          time: :integer,
          memory_time: :integer,
          output: :string
        ],
        aliases: [
          s: :scenario,
          d: :with_dashboard,
          t: :time,
          m: :memory_time,
          o: :output
        ]
      )

    opts
  end

  defp build_config(opts) do
    %{
      scenario: Keyword.get(opts, :scenario, "all"),
      time: Keyword.get(opts, :time, 2),
      memory_time: Keyword.get(opts, :memory_time, 1),
      output_path:
        Keyword.get(opts, :output, "bench/output/memory_analysis_report.html"),
      with_dashboard: Keyword.get(opts, :with_dashboard, false),
      benchmark_config: build_benchmark_config(opts)
    }
  end

  defp build_benchmark_config(opts) do
    time = Keyword.get(opts, :time, 2)
    memory_time = Keyword.get(opts, :memory_time, 1)

    output_path =
      Keyword.get(opts, :output, "bench/output/memory_analysis_report.html")

    [
      time: time,
      memory_time: memory_time,
      warmup: 0.5,
      formatters: [
        Benchee.Formatters.Console,
        output_formatter(output_path)
      ]
    ]
  end

  # Honour the extension the caller asked for. The regression workflow passes
  # a .json path and feeds the result to analyze_memory_regression.exs, so
  # writing an HTML report there produced a file that could never parse.
  defp output_formatter(path) do
    case Path.extname(path) do
      ".json" -> {Benchee.Formatters.JSON, file: path}
      _ -> {Benchee.Formatters.HTML, file: path}
    end
  end

  defp print_config_info(config) do
    Mix.shell().info("Running Memory Analysis Benchmarks...")
    Mix.shell().info("Scenario: #{config.scenario}")

    Mix.shell().info(
      "Time: #{config.time}s, Memory Time: #{config.memory_time}s"
    )
  end

  defp run_scenario(scenario, benchmark_config) do
    case scenario do
      "terminal_operations" ->
        run_terminal_operations_analysis(benchmark_config)

      "buffer_management" ->
        run_buffer_management_analysis(benchmark_config)

      "realistic_usage" ->
        run_realistic_usage_analysis(benchmark_config)

      "memory_patterns" ->
        run_memory_pattern_analysis(benchmark_config)

      "all" ->
        run_comprehensive_analysis(benchmark_config)

      _ ->
        handle_unknown_scenario(scenario)
    end
  end

  @spec handle_unknown_scenario(term()) :: no_return()
  defp handle_unknown_scenario(scenario) do
    Mix.shell().error("Unknown scenario: #{scenario}")

    Mix.shell().info(
      "Available scenarios: terminal_operations, buffer_management, realistic_usage, memory_patterns, all"
    )

    System.halt(1)
  end

  defp process_results(results, config) do
    Mix.shell().info("\nAnalyzing Memory Patterns...")
    analysis = MemoryAnalyzer.analyze_memory_patterns(results)
    print_analysis_summary(analysis)

    recommendations = MemoryAnalyzer.generate_recommendations(analysis)
    print_recommendations(recommendations)

    if config.with_dashboard do
      generate_dashboard(results, analysis, recommendations, config.scenario)
    end
  end

  defp generate_dashboard(results, analysis, recommendations, scenario) do
    Mix.shell().info("\nGenerating Interactive Dashboard...")
    dashboard_path = "bench/output/memory_analysis_dashboard.html"

    dashboard_config = %{
      title: "Raxol Memory Analysis Dashboard",
      subtitle: "Advanced Memory Pattern Analysis - Scenario: #{scenario}",
      benchmark_results: results,
      analysis: analysis,
      recommendations: recommendations
    }

    case MemoryDashboard.generate_dashboard(results,
           output_path: dashboard_path,
           config: dashboard_config
         ) do
      {:ok, _} ->
        Mix.shell().info("Dashboard generated: #{dashboard_path}")

        Mix.shell().info(
          "Open in browser: file://#{Path.expand(dashboard_path)}"
        )

      {:error, error} ->
        Mix.shell().error("Dashboard generation failed: #{inspect(error)}")
    end
  end

  # =============================================================================
  # Benchmark Scenarios
  # =============================================================================

  defp run_terminal_operations_analysis(config) do
    jobs = %{
      "small_terminal_80x24" => fn ->
        create_terminal_buffer(80, 24)
      end,
      "medium_terminal_132x43" => fn ->
        create_terminal_buffer(132, 43)
      end,
      "large_terminal_1000x1000" => fn ->
        create_terminal_buffer(1000, 1000)
      end,
      "multiple_buffers_5x" => fn ->
        for _i <- 1..5 do
          create_terminal_buffer(80, 24)
        end
      end
    }

    Benchee.run(jobs, config)
  end

  defp run_buffer_management_analysis(config) do
    jobs = %{
      "buffer_creation_destruction" => fn ->
        buffer = create_terminal_buffer(100, 100)
        clear_buffer(buffer)
      end,
      "buffer_modification_heavy" => fn ->
        buffer = create_terminal_buffer(50, 50)

        for row <- 1..50, col <- 1..50 do
          update_cell(buffer, row, col, "X")
        end
      end,
      "ansi_sequence_processing" => fn ->
        sequences = [
          # Clear screen
          "\e[2J",
          # Move to home
          "\e[1;1H",
          # Color text
          "\e[31mRed\e[0m",
          # Alternative buffer
          "\e[?1049h",
          # Normal buffer
          "\e[?1049l"
        ]

        for seq <- sequences do
          process_ansi_sequence(seq)
        end
      end,
      "scroll_operations_heavy" => fn ->
        buffer = create_terminal_buffer(80, 24)

        for _i <- 1..100 do
          scroll_buffer_up(buffer)
        end
      end
    }

    Benchee.run(jobs, config)
  end

  defp run_realistic_usage_analysis(config) do
    jobs = %{
      "vim_session_simulation" => fn ->
        simulate_vim_session()
      end,
      "log_streaming_simulation" => fn ->
        simulate_log_streaming(1000)
      end,
      "multi_pane_terminal" => fn ->
        simulate_multi_pane_terminal(4)
      end,
      "rapid_output_processing" => fn ->
        process_rapid_output(500)
      end
    }

    Benchee.run(jobs, config)
  end

  defp run_memory_pattern_analysis(config) do
    jobs = %{
      "linear_growth_pattern" => &benchmark_linear_growth/0,
      "exponential_growth_pattern" => &benchmark_exponential_growth/0,
      "constant_memory_pattern" => &benchmark_constant_memory/0,
      "gc_pressure_pattern" => &benchmark_gc_pressure/0
    }

    Benchee.run(jobs, config)
  end

  defp benchmark_linear_growth do
    data = for i <- 1..100, do: String.duplicate("data", i)
    Enum.reduce(data, [], &[&1 | &2])
  end

  defp benchmark_exponential_growth do
    Enum.reduce(1..10, ["start"], fn _i, acc ->
      expanded = Enum.map(acc, &String.duplicate(&1, 2))
      acc ++ expanded
    end)
  end

  defp benchmark_constant_memory do
    data = for _i <- 1..1000, do: "constant"
    Enum.take(data, 100)
  end

  defp benchmark_gc_pressure do
    large_data =
      for _i <- 1..1000 do
        :crypto.strong_rand_bytes(1024)
      end

    Enum.chunk_every(large_data, 100)
    |> Enum.map(&length/1)
  end

  defp run_comprehensive_analysis(config) do
    # Run a subset of all scenarios for comprehensive analysis
    jobs = %{
      "terminal_80x24" => fn -> create_terminal_buffer(80, 24) end,
      "terminal_1000x1000" => fn -> create_terminal_buffer(1000, 1000) end,
      "buffer_heavy_modification" => fn ->
        buffer = create_terminal_buffer(50, 50)
        for row <- 1..50, col <- 1..50, do: update_cell(buffer, row, col, "X")
      end,
      "vim_simulation" => fn -> simulate_vim_session() end,
      "log_streaming" => fn -> simulate_log_streaming(500) end,
      "exponential_growth" => fn ->
        Enum.reduce(1..8, ["start"], fn _i, acc ->
          expanded = Enum.map(acc, &String.duplicate(&1, 2))
          acc ++ expanded
        end)
      end
    }

    Benchee.run(jobs, config)
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  defp create_terminal_buffer(width, height) do
    for _row <- 1..height do
      for _col <- 1..width do
        %{
          char: " ",
          fg: :white,
          bg: :black,
          style: %{bold: false, italic: false, underline: false}
        }
      end
    end
  end

  defp clear_buffer(buffer) when is_list(buffer) do
    Enum.map(buffer, fn row ->
      Enum.map(row, fn _cell ->
        %{char: " ", fg: :white, bg: :black, style: %{}}
      end)
    end)
  end

  defp update_cell(buffer, row, col, char) when is_list(buffer) do
    case row <= length(buffer) do
      true ->
        buffer_row = Enum.at(buffer, row - 1)
        update_cell_in_row(buffer, buffer_row, row, col, char)

      false ->
        buffer
    end
  end

  defp process_ansi_sequence(sequence) do
    # Simulate ANSI sequence processing
    case sequence do
      "\e[2J" -> :clear_screen
      "\e[1;1H" -> :move_cursor_home
      "\e[31m" <> rest -> {:set_color, :red, rest}
      "\e[0m" -> :reset_attributes
      "\e[?1049h" -> :enter_alt_buffer
      "\e[?1049l" -> :exit_alt_buffer
      _ -> {:unknown_sequence, sequence}
    end
  end

  defp scroll_buffer_up(buffer) when is_list(buffer) do
    case buffer do
      [] ->
        []

      [_first | rest] ->
        empty_row =
          for _col <- 1..80,
              do: %{char: " ", fg: :white, bg: :black, style: %{}}

        # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
        rest ++ [empty_row]
    end
  end

  defp simulate_vim_session do
    # Simulate vim operations: file loading, editing, syntax highlighting
    file_content =
      for _i <- 1..1000, do: "def function_#{:rand.uniform(1000)}, do: :ok"

    # Simulate syntax highlighting (create colored tokens)
    highlighted =
      Enum.map(file_content, fn line ->
        tokens = String.split(line, " ")
        Enum.map(tokens, &colorize_token/1)
      end)

    # Simulate editing operations
    modified =
      Enum.take(highlighted, 500) ++
        [%{text: "# New comment", color: :gray}] ++
        Enum.drop(highlighted, 500)

    modified
  end

  defp simulate_log_streaming(num_lines) do
    # Simulate continuous log output
    timestamps =
      for i <- 1..num_lines do
        {{2024, 1, 1}, {12, 0, i}} |> NaiveDateTime.from_erl!()
      end

    log_levels = [:info, :warn, :error, :debug]

    for {timestamp, i} <- Enum.with_index(timestamps, 1) do
      level = Enum.random(log_levels)

      message =
        "Log message #{i} with some detailed information about system state"

      %{
        timestamp: timestamp,
        level: level,
        message: message,
        metadata: %{module: "System.Logger", pid: self()}
      }
    end
  end

  defp simulate_multi_pane_terminal(num_panes) do
    # Simulate multiple terminal panes
    for pane_id <- 1..num_panes do
      %{
        id: pane_id,
        buffer: create_terminal_buffer(40, 12),
        cursor: %{row: 1, col: 1},
        title: "Pane #{pane_id}",
        active: pane_id == 1
      }
    end
  end

  defp process_rapid_output(num_outputs) do
    # Simulate rapid terminal output processing
    outputs =
      for i <- 1..num_outputs do
        case rem(i, 4) do
          0 -> "\e[31mError: Something went wrong #{i}\e[0m\n"
          1 -> "\e[32mSuccess: Operation #{i} completed\e[0m\n"
          2 -> "\e[33mWarning: Check configuration #{i}\e[0m\n"
          3 -> "Info: Processing item #{i}\n"
        end
      end

    # Process each output (simulate parsing and buffer updates)
    for output <- outputs do
      process_ansi_sequence(output)
    end
  end

  # =============================================================================
  # Analysis Reporting
  # =============================================================================

  defp print_analysis_summary(analysis) do
    Mix.shell().info("\n=== Memory Analysis Summary ===")
    Mix.shell().info("Peak Memory: #{format_bytes(analysis.peak_memory)}")

    Mix.shell().info(
      "Sustained Memory: #{format_bytes(analysis.sustained_memory)}"
    )

    Mix.shell().info("GC Collections: #{analysis.gc_collections}")

    Mix.shell().info(
      "Fragmentation Ratio: #{Float.round(analysis.fragmentation_ratio, 3)}"
    )

    Mix.shell().info(
      "Efficiency Score: #{Float.round(analysis.efficiency_score, 3)}"
    )

    Mix.shell().info("Regression Detected: #{analysis.regression_detected}")

    platform_info = analysis.platform_differences
    Mix.shell().info("\nPlatform: #{platform_info.platform}")
    Mix.shell().info("Architecture: #{platform_info.architecture}")
    Mix.shell().info("Memory Allocator: #{platform_info.memory_allocator}")
  end

  defp print_recommendations(recommendations) do
    if recommendations != [] do
      Mix.shell().info("\n=== Optimization Recommendations ===")

      for {recommendation, index} <- Enum.with_index(recommendations, 1) do
        Mix.shell().info("#{index}. #{recommendation}")
      end
    else
      Mix.shell().info("\n=== No Optimization Recommendations ===")
      Mix.shell().info("Memory usage patterns appear optimal.")
    end
  end

  defp format_bytes(bytes), do: Raxol.Utils.Format.format_bytes(bytes)

  defp update_cell_in_row(buffer, buffer_row, row, col, char) do
    case col <= length(buffer_row) do
      true ->
        updated_row =
          List.update_at(buffer_row, col - 1, fn cell ->
            %{cell | char: char}
          end)

        List.update_at(buffer, row - 1, fn _ -> updated_row end)

      false ->
        buffer
    end
  end

  defp colorize_token(token) do
    color =
      case token do
        "def" -> :blue
        "do:" -> :green
        _ -> :white
      end

    %{text: token, color: color}
  end
end
