defmodule Mix.Tasks.Raxol.Perf do
  @moduledoc """
  Performance analysis and optimization tools for development.

  This task provides various performance analysis capabilities:

  ## Commands

      mix raxol.perf analyze           # Analyze current performance
      mix raxol.perf profile <module>  # Profile a specific module
      mix raxol.perf hints             # Show performance hints
      mix raxol.perf monitor           # Start continuous monitoring
      mix raxol.perf memory            # Memory usage analysis
      mix raxol.perf report            # Generate performance report

  ## Related Commands

      mix raxol.flamegraph <module>    # Generate flame graph SVG
      mix raxol.bench.advanced         # Advanced benchmarking suite

  ## Options

    * `--format, -f`    - Output format: text, html, json (default: text)
    * `--interval, -i`  - Monitoring interval in seconds (default: 30)
    * `--duration, -d`  - Profiling duration in seconds (default: 10)
    * `--memory, -m`    - Include memory profiling in output
    * `--processes, -p` - Include process analysis in output
    * `--call-graph`    - Generate call graph visualization (expensive)
    * `--help, -h`      - Show detailed help

  ## Examples

      # Quick performance analysis
      mix raxol.perf analyze

      # Profile terminal operations
      mix raxol.perf profile Raxol.Terminal.Buffer

      # Profile with memory analysis
      mix raxol.perf profile Raxol.Terminal.Buffer --memory

      # Start continuous monitoring every 60 seconds
      mix raxol.perf monitor --interval 60

      # Generate HTML report for 30 seconds
      mix raxol.perf report --format html --duration 30

      # Memory profiling for 30 seconds
      mix raxol.perf memory --duration 30
  """

  use Mix.Task

  @shortdoc "Performance analysis and optimization tools"

  @switches [
    format: :string,
    interval: :integer,
    duration: :integer,
    memory: :boolean,
    processes: :boolean,
    call_graph: :boolean,
    help: :boolean
  ]

  @aliases [
    f: :format,
    i: :interval,
    d: :duration,
    m: :memory,
    p: :processes,
    h: :help
  ]

  def run(args) do
    {opts, args, _} =
      OptionParser.parse(args, switches: @switches, aliases: @aliases)

    if opts[:help] do
      show_help()
    else
      ensure_started()
      handle_command(args, opts)
    end
  end

  defp handle_command([], _opts), do: handle_command(["analyze"], [])

  defp handle_command(["analyze"], _opts) do
    Mix.shell().info("[SEARCH] Analyzing current performance...")

    analysis = Raxol.Performance.DevProfiler.analyze_current_performance()

    Mix.shell().info("\n[STATS] Performance Analysis Results:")
    Mix.shell().info("Memory: #{analysis.memory.total_mb}MB total")
    Mix.shell().info("Processes: #{analysis.processes.count}")

    if analysis.memory.issues != [] do
      Mix.shell().info("\n[WARN]  Issues detected:")

      Enum.each(
        analysis.memory.issues ++
          analysis.processes.issues ++ analysis.system.issues,
        fn issue ->
          Mix.shell().info("  • #{issue}")
        end
      )
    else
      Mix.shell().info("\n[OK] No performance issues detected")
    end
  end

  defp handle_command(["profile", module_name], opts)
       when is_binary(module_name) do
    module = Module.concat([module_name])

    if Code.ensure_loaded?(module) do
      Mix.shell().info("[PROF] Profiling module: #{module}")

      profile_opts = build_profile_opts(opts)

      # Profile module functions
      _result =
        Raxol.Performance.DevProfiler.profile(profile_opts, fn ->
          # Call some representative functions if they exist
          profile_module_functions(module)
        end)

      Mix.shell().info("[OK] Profiling complete")
    else
      Mix.shell().error("Module #{module} not found or not loaded")
    end
  rescue
    ArgumentError ->
      Mix.shell().error("Invalid module name: #{module_name}")
  end

  defp handle_command(["profile"], _opts) do
    Mix.shell().error("Usage: mix raxol.perf profile <module_name>")
  end

  defp handle_command(["hints"], _opts) do
    Mix.shell().info("[TIP] Current Performance Hints:")

    case Raxol.Performance.DevHints.enabled?() do
      true ->
        stats = Raxol.Performance.DevHints.stats()

        Mix.shell().info(
          "Hints system: Enabled (#{stats.total_hints} hints shown)"
        )

        Mix.shell().info("Uptime: #{Float.round(stats.uptime_ms / 1000, 1)}s")
        display_hint_categories(stats.hint_categories)

      false ->
        Mix.shell().info("Performance hints are not enabled")

        Mix.shell().info(
          "Enable with: config :raxol, Raxol.Performance.DevHints, enabled: true"
        )
    end
  end

  defp handle_command(["monitor"], opts) do
    interval = Keyword.get(opts, :interval, 30) * 1000
    duration = Keyword.get(opts, :duration, 5) * 1000

    Mix.shell().info("[STATS] Starting continuous performance monitoring...")

    Mix.shell().info(
      "Interval: #{interval / 1000}s, Duration: #{duration / 1000}s per session"
    )

    Mix.shell().info("Press Ctrl+C to stop")

    _ =
      Raxol.Performance.DevProfiler.start_continuous(
        interval: interval,
        duration: duration,
        auto_hints: true
      )

    # Keep the task running
    receive do
      :never -> :ok
    end
  end

  defp handle_command(["memory"], opts) do
    duration = Keyword.get(opts, :duration, 10) * 1000

    Mix.shell().info(
      "[BRAIN] Profiling memory usage for #{duration / 1000}s..."
    )

    Raxol.Performance.DevProfiler.profile_memory(duration)
  end

  defp handle_command(["report"], opts) do
    format = Keyword.get(opts, :format, "text")

    Mix.shell().info("[LIST] Generating performance report...")

    profile_opts = build_profile_opts(opts)

    profile_opts =
      Keyword.put(profile_opts, :output_format, String.to_atom(format))

    # Generate comprehensive report
    Raxol.Performance.DevProfiler.profile(profile_opts, fn ->
      # Simulate typical workload
      simulate_workload()
    end)
  end

  defp handle_command([command], _opts) do
    Mix.shell().error("Unknown command: #{command}")
    show_help()
  end

  defp handle_command(command, _opts) do
    Mix.shell().error("Invalid command: #{inspect(command)}")
    show_help()
  end

  defp build_profile_opts(opts) do
    profile_opts = []

    profile_opts =
      if duration = opts[:duration] do
        Keyword.put(profile_opts, :duration, duration * 1000)
      else
        profile_opts
      end

    profile_opts =
      if opts[:memory] do
        Keyword.put(profile_opts, :memory, true)
      else
        profile_opts
      end

    profile_opts =
      if opts[:processes] do
        Keyword.put(profile_opts, :processes, true)
      else
        profile_opts
      end

    profile_opts =
      if opts[:call_graph] do
        Keyword.put(profile_opts, :call_graph, true)
      else
        profile_opts
      end

    profile_opts
  end

  defp profile_module_functions(module) do
    # Try to call some common functions to generate profile data
    functions = module.__info__(:functions)

    # Look for common patterns and call them safely
    Enum.each(functions, fn {name, arity} ->
      case {name, arity} do
        {:new, 0} ->
          try do
            module.new()
          catch
            _, _ -> :ok
          end

        {:new, 1} ->
          try do
            module.new(%{})
          catch
            _, _ -> :ok
          end

        {:start_link, 0} ->
          # Skip GenServer start_link calls in profiling
          :skip

        _ ->
          :skip
      end
    end)
  end

  defp simulate_workload do
    # Simulate typical Raxol operations for comprehensive profiling
    # Terminal operations
    _ =
      if Code.ensure_loaded?(Raxol.Terminal.Emulator) do
        emulator = Raxol.Terminal.Emulator.new(80, 24)
        _ = Raxol.Terminal.Emulator.process_input(emulator, "Hello, World!")
      end

    # Buffer operations
    _ =
      if Code.ensure_loaded?(Raxol.Terminal.ScreenBuffer) do
        alias Raxol.Terminal.ScreenBuffer
        buffer = ScreenBuffer.new(80, 24)
        _ = ScreenBuffer.write_string(buffer, 0, 0, "Test content", nil)
        :ok
      end
  catch
    _, _ -> :ok
  end

  defp ensure_started do
    # Ensure the application is started for profiling
    Mix.Task.run("app.start")
  end

  defp show_help do
    Mix.shell().info("""
    Performance analysis and optimization tools for Raxol development.

    ## Commands

        mix raxol.perf analyze                    # Quick performance analysis
        mix raxol.perf profile <module>          # Profile specific module
        mix raxol.perf hints                     # Show performance hints status
        mix raxol.perf monitor [options]         # Start continuous monitoring
        mix raxol.perf memory [options]          # Memory usage analysis
        mix raxol.perf report [options]          # Generate performance report

    ## Options

        --format, -f      Output format (text, html, json)
        --interval, -i    Monitoring interval in seconds (default: 30)
        --duration, -d    Profiling duration in seconds (default: 10)
        --memory, -m      Include memory profiling
        --processes, -p   Include process analysis
        --call-graph      Generate call graph (expensive)
        --help, -h        Show this help

    ## Examples

        # Quick analysis
        mix raxol.perf analyze

        # Profile with memory analysis
        mix raxol.perf profile Raxol.Terminal.Buffer --memory

        # Continuous monitoring every 60 seconds
        mix raxol.perf monitor --interval 60

        # Generate HTML report
        mix raxol.perf report --format html --duration 30

        # Memory profiling for 30 seconds
        mix raxol.perf memory --duration 30
    """)
  end

  defp display_hint_categories(hint_categories) do
    case map_size(hint_categories) > 0 do
      true ->
        Mix.shell().info("\nHint categories:")

        Enum.each(hint_categories, fn {category, count} ->
          Mix.shell().info("  #{category}: #{count}")
        end)

      false ->
        :ok
    end
  end
end
