defmodule Mix.Tasks.Raxol.Memory.Debug do
  @moduledoc """
  Memory debugging tools for detecting leaks, hotspots, and optimization opportunities.

  This task provides comprehensive memory debugging capabilities including
  leak detection, hotspot analysis, allocation tracking, and optimization
  guidance.

  ## Usage

      mix raxol.memory.debug
      mix raxol.memory.debug --command analyze
      mix raxol.memory.debug --command hotspots
      mix raxol.memory.debug --command leaks

  ## Commands

  ### analyze
  Comprehensive memory analysis including:
  - Current memory usage breakdown
  - Process memory consumption
  - ETS table analysis
  - Binary reference analysis
  - Potential optimization opportunities

  ### hotspots
  Identify memory hotspots:
  - Top memory-consuming processes
  - Large ETS tables
  - Binary memory usage
  - Atom table growth
  - Port memory usage

  ### leaks
  Memory leak detection:
  - Process memory growth monitoring
  - Reference leak detection
  - ETS table growth analysis
  - Binary accumulation detection
  - Port leak detection

  ### optimize
  Memory optimization guidance:
  - Recommend memory optimizations
  - Identify inefficient patterns
  - Suggest configuration changes
  - Binary optimization tips
  - Process pool recommendations

  ## Options

    * `--command` - Debug command to run (analyze, hotspots, leaks, optimize)
    * `--target` - Target module or process to focus on
    * `--threshold` - Memory threshold in MB for reporting (default: 1)
    * `--output` - Output file for detailed results
    * `--format` - Output format (text, json, markdown) (default: text)
    * `--monitoring-duration` - Duration for leak monitoring in seconds (default: 300)

  ## Examples

      # General memory analysis
      mix raxol.memory.debug --command analyze

      # Find memory hotspots
      mix raxol.memory.debug --command hotspots --threshold 5

      # Monitor for memory leaks for 10 minutes
      mix raxol.memory.debug --command leaks --monitoring-duration 600

      # Get optimization recommendations
      mix raxol.memory.debug --command optimize --output memory_report.md
  """

  use Mix.Task

  @compile {:no_warn_undefined, Raxol.Memory.Collector}
  @compile {:no_warn_undefined, Raxol.Memory.Formatter}
  @compile {:no_warn_undefined, Raxol.Memory.LeakDetector}
  @compile {:no_warn_undefined, Raxol.Memory.Optimizer}

  alias Raxol.Memory.{Collector, Formatter, LeakDetector, Optimizer}

  @shortdoc "Memory debugging tools for leak detection and optimization"

  @spec run(list()) :: no_return()
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          command: :string,
          target: :string,
          threshold: :float,
          output: :string,
          format: :string,
          monitoring_duration: :integer,
          help: :boolean
        ],
        aliases: [c: :command, t: :target, h: :help, o: :output, f: :format]
      )

    if opts[:help] do
      print_help()
      System.halt(0)
    end

    _ = Application.ensure_all_started(:raxol)

    config = build_config(opts)

    case config.command do
      "analyze" ->
        run_memory_analysis(config)

      "hotspots" ->
        run_hotspot_analysis(config)

      "leaks" ->
        run_leak_detection(config)

      "optimize" ->
        run_optimization_analysis(config)

      _ ->
        Mix.shell().error("Unknown command: #{config.command}")

        Mix.shell().info(
          "Available commands: analyze, hotspots, leaks, optimize"
        )

        System.halt(1)
    end
  end

  defp build_config(opts) do
    %{
      command: Keyword.get(opts, :command, "analyze"),
      target: Keyword.get(opts, :target),
      threshold: Keyword.get(opts, :threshold, 1.0),
      output: Keyword.get(opts, :output),
      format: Keyword.get(opts, :format, "text"),
      monitoring_duration: Keyword.get(opts, :monitoring_duration, 300)
    }
  end

  defp run_memory_analysis(config) do
    Mix.shell().info("Running comprehensive memory analysis...")

    analysis = %{
      timestamp: DateTime.utc_now(),
      memory_overview: Collector.analyze_memory_overview(),
      process_analysis: Collector.analyze_processes(config),
      ets_analysis: Collector.analyze_ets_tables(config),
      binary_analysis: Collector.analyze_binary_usage(),
      atom_analysis: Collector.analyze_atom_usage(),
      system_analysis: Collector.analyze_system_memory()
    }

    Formatter.format_and_output_analysis(analysis, config)
  end

  defp run_hotspot_analysis(config) do
    Mix.shell().info("Analyzing memory hotspots...")

    hotspots = %{
      timestamp: DateTime.utc_now(),
      top_processes: Collector.analyze_processes(config).top_consumers,
      large_ets_tables: Collector.analyze_ets_tables(config).top_consumers,
      binary_hotspots: Collector.find_binary_hotspots(config),
      atom_growth: Collector.analyze_atom_growth(),
      port_usage: Collector.analyze_port_memory()
    }

    Formatter.format_and_output_hotspots(hotspots, config)
  end

  defp run_leak_detection(config) do
    Mix.shell().info("Starting memory leak detection...")
    Mix.shell().info("Monitoring for #{config.monitoring_duration} seconds...")

    initial_state = Collector.capture_memory_state()

    monitoring_results =
      LeakDetector.monitor_memory_growth(
        config.monitoring_duration,
        initial_state
      )

    leak_analysis =
      LeakDetector.analyze_potential_leaks(
        initial_state,
        monitoring_results,
        config
      )

    Formatter.format_and_output_leaks(leak_analysis, config)
  end

  defp run_optimization_analysis(config) do
    Mix.shell().info("Analyzing memory optimization opportunities...")
    optimizations = Optimizer.run_optimization_analysis(config)
    Formatter.format_and_output_optimizations(optimizations, config)
  end

  defp print_help do
    Mix.shell().info(@moduledoc)
  end
end
