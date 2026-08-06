defmodule Mix.Tasks.Raxol.Bench do
  @moduledoc """
  Enhanced benchmarking task for Raxol terminal emulator.

  Provides comprehensive performance benchmarking with multiple
  output formats, regression detection, and dashboard generation.

  ## Usage

      mix raxol.bench                    # Run all benchmarks
      mix raxol.bench parser             # Run parser benchmarks only
      mix raxol.bench terminal           # Run terminal component benchmarks
      mix raxol.bench rendering          # Run rendering benchmarks only
      mix raxol.bench memory             # Run memory benchmarks only
      mix raxol.bench dashboard          # Generate dashboard from latest results

  ## Options

    * `--quick`       - Quick benchmark run with reduced time
    * `--compare`     - Compare with previous benchmark results
    * `--dashboard`   - Generate full performance dashboard with charts
    * `--regression`  - Check for performance regressions (5% threshold)
    * `--help`        - Show detailed help

  ## Examples

      # Quick performance check
      mix raxol.bench --quick

      # Full benchmarks with regression detection
      mix raxol.bench --regression

  Note: `--regression` compares against `bench/output/enhanced/baseline.json`.
  A run with no baseline on disk saves one and passes -- in CI the baseline
  must be persisted (cache/artifact) across runs or the gate compares
  nothing. The comparison covers jobs present in both runs; renames are
  reported, not silently skipped.

      # Parser benchmarks with dashboard generation
      mix raxol.bench parser --dashboard

      # Compare current run with previous results
      mix raxol.bench --compare

  ## Output

  Results are saved to `bench/output/enhanced/` with:
    - HTML reports for interactive viewing
    - JSON data for programmatic analysis
    - Performance dashboard with charts
    - Regression analysis reports
    - Baseline metrics for future comparison
  """

  use Mix.Task

  @shortdoc "Run enhanced performance benchmarks"

  @compile {:no_warn_undefined, Raxol.Bench.Dashboard}
  @compile {:no_warn_undefined, Raxol.Bench.TestData}
  @compile {:no_warn_undefined, Benchee}

  alias Raxol.Bench.{Dashboard, TestData}

  @switches [
    quick: :boolean,
    compare: :boolean,
    dashboard: :boolean,
    regression: :boolean,
    help: :boolean,
    format: :string,
    output: :string,
    suite: :string
  ]

  def run(args) do
    {opts, args, _} = OptionParser.parse(args, switches: @switches)

    if opts[:help] do
      print_help()
    else
      Mix.Task.run("app.start")
      execute_benchmark(args, opts)
    end
  end

  defp execute_benchmark(args, opts) do
    # Handle --suite flag as primary routing for new framework suites
    if suite = opts[:suite] do
      run_framework_suite(suite, opts)
    else
      execute_benchmark_by_arg(args, opts)
    end
  end

  @framework_suites ~w(render latency memory_widgets startup comparison)

  defp execute_benchmark_by_arg([], opts), do: run_all_benchmarks(opts)

  defp execute_benchmark_by_arg([suite], opts) when suite in @framework_suites,
    do: run_framework_suite(suite, opts)

  defp execute_benchmark_by_arg(["parser"], opts), do: run_parser_only(opts)
  defp execute_benchmark_by_arg(["terminal"], opts), do: run_terminal_only(opts)

  defp execute_benchmark_by_arg(["rendering"], opts),
    do: run_rendering_only(opts)

  defp execute_benchmark_by_arg(["memory"], opts), do: run_memory_only(opts)

  defp execute_benchmark_by_arg(["dashboard"], opts),
    do: run_dashboard_only(opts)

  defp execute_benchmark_by_arg([benchmark], _opts) do
    Mix.shell().error("Unknown benchmark: #{benchmark}")
    print_help()
  end

  defp run_all_benchmarks(opts) do
    Mix.shell().info("Running Raxol Performance Benchmarks...")

    if opts[:quick] do
      ignored = Enum.filter([:regression, :compare, :dashboard], &opts[&1])

      if ignored != [] do
        flags = Enum.map_join(ignored, "/", &"--#{&1}")

        Mix.shell().info(
          "Note: #{flags} require a full run and are ignored with --quick"
        )
      end

      run_quick_benchmarks()
    else
      run_comprehensive_benchmarks(opts)
    end
  end

  defp run_quick_benchmarks do
    Mix.shell().info("Quick benchmark mode (reduced time)")

    benchmark_config = [
      time: 1,
      memory_time: 0.5,
      warmup: 0.2,
      formatters: [Benchee.Formatters.Console]
    ]

    _ = run_parser_benchmarks(benchmark_config, quick: true)
    _ = run_terminal_benchmarks(benchmark_config, quick: true)
  end

  defp run_comprehensive_benchmarks(opts) do
    Mix.shell().info("Running comprehensive benchmarks...")

    File.mkdir_p!("bench/output/enhanced")
    File.mkdir_p!("bench/output/enhanced/json")
    File.mkdir_p!("bench/output/enhanced/html")

    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    results =
      %{}
      |> Map.put(:parser, run_parser_benchmarks(standard_config(timestamp)))
      |> Map.put(:terminal, run_terminal_benchmarks(standard_config(timestamp)))
      |> Map.put(
        :rendering,
        run_rendering_benchmarks(standard_config(timestamp))
      )
      |> Map.put(:memory, run_memory_benchmarks(standard_config(timestamp)))
      |> Map.put(
        :concurrent,
        run_concurrent_benchmarks(standard_config(timestamp))
      )

    _metrics = Dashboard.snapshot_metrics(results, timestamp)

    if opts[:compare], do: Dashboard.run_comparison_analysis(results, timestamp)

    if opts[:dashboard],
      do: Dashboard.generate_enhanced_dashboard(results, timestamp)

    Dashboard.print_results_summary(results, timestamp)

    # Last: this raises on a regression, and the artifacts above should
    # exist for the post-mortem when it does.
    if opts[:regression], do: Dashboard.check_for_regressions(results)
  end

  defp run_parser_only(opts) do
    Mix.shell().info("Running Parser Benchmarks Only...")
    config = if opts[:quick], do: quick_config(), else: standard_config()
    run_parser_benchmarks(config)
  end

  defp run_terminal_only(opts) do
    Mix.shell().info("Running Terminal Component Benchmarks Only...")
    config = if opts[:quick], do: quick_config(), else: standard_config()
    run_terminal_benchmarks(config)
  end

  defp run_rendering_only(opts) do
    Mix.shell().info("Running Rendering Benchmarks Only...")
    config = if opts[:quick], do: quick_config(), else: standard_config()
    run_rendering_benchmarks(config)
  end

  defp run_memory_only(opts) do
    Mix.shell().info("Running Memory Benchmarks Only...")
    config = if opts[:quick], do: quick_config(), else: standard_config()
    run_memory_benchmarks(config)
  end

  defp run_dashboard_only(_opts) do
    Mix.shell().info("Generating Performance Dashboard...")
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    results = Dashboard.load_latest_results() || %{}
    Dashboard.generate_enhanced_dashboard(results, timestamp)

    Mix.shell().info(
      "Dashboard generated at bench/output/enhanced/dashboard.html"
    )
  end

  defp run_parser_benchmarks(config, opts \\ []) do
    alias Raxol.Terminal.ANSI.StateMachine
    alias Raxol.Terminal.ANSI.Utils.AnsiParser
    alias Raxol.Terminal.Emulator

    _emulator = Emulator.new(80, 24)

    scenarios =
      if opts[:quick] do
        %{
          "plain_text" => "Hello, World!",
          "ansi_basic" => "\e[31mRed Text\e[0m",
          "ansi_complex" => "\e[1;4;31mBold Red Underlined\e[0m"
        }
      else
        TestData.full_parser_scenarios()
      end

    jobs =
      Enum.into(scenarios, %{}, fn {name, content} ->
        {name,
         fn ->
           state_machine = StateMachine.new()
           AnsiParser.parse(state_machine, content)
         end}
      end)

    Benchee.run(jobs, config)
  end

  defp run_terminal_benchmarks(config, opts \\ []) do
    jobs =
      if opts[:quick],
        do: TestData.terminal_quick_jobs(),
        else: TestData.terminal_comprehensive_jobs()

    Benchee.run(jobs, config)
  end

  defp run_rendering_benchmarks(config) do
    alias Raxol.Terminal.ScreenBuffer
    alias Raxol.UI.Rendering.TreeDiffer

    {_small_buffer, medium_buffer, _large_buffer} =
      TestData.create_test_buffers()

    tree = %{
      type: :view,
      children:
        Enum.map(1..100, fn i ->
          %{type: :text, attrs: %{content: "Row #{i}"}}
        end)
    }

    modified =
      put_in(tree, [:children, Access.at(50), :attrs, :content], "Modified")

    jobs = %{
      "render_tree_diff_100_nodes" => fn ->
        TreeDiffer.diff_trees(tree, modified)
      end,
      "render_full_frame" => fn ->
        buf = ScreenBuffer.new(80, 24)

        _filled =
          Enum.reduce(0..23, buf, fn y, outer ->
            Enum.reduce(0..79, outer, fn x, b ->
              ScreenBuffer.write_char(b, x, y, "X")
            end)
          end)

        TreeDiffer.diff_trees(tree, modified)
      end,
      "render_partial_update" => fn ->
        Enum.reduce(0..9, medium_buffer, fn x, b ->
          Raxol.Terminal.ScreenBufferAdapter.write_char(b, x, 0, "Y")
        end)
      end
    }

    Benchee.run(jobs, config)
  end

  defp run_memory_benchmarks(config) do
    Benchee.run(memory_benchmark_jobs(), config)
  end

  defp memory_benchmark_jobs do
    alias Raxol.Terminal.ANSI.StateMachine
    alias Raxol.Terminal.ANSI.Utils.AnsiParser
    alias Raxol.Terminal.Cursor
    alias Raxol.Terminal.Emulator
    alias Raxol.Terminal.ScreenBufferAdapter, as: ScreenBuffer

    %{
      "memory_emulator_80x24" => fn -> Emulator.new(80, 24) end,
      "memory_emulator_200x50" => fn -> Emulator.new(200, 50) end,
      "memory_parser_session" => fn ->
        emulator = Emulator.new(80, 24)
        state_machine = StateMachine.new()
        content = TestData.generate_test_content()
        _ = AnsiParser.parse(state_machine, content)
        {emulator, state_machine}
      end,
      "memory_buffer_operations" => fn ->
        buffer = ScreenBuffer.new(100, 30)
        _cursor = Cursor.new()

        Enum.reduce(1..50, buffer, fn i, acc ->
          ScreenBuffer.write_string(acc, 0, rem(i, 30), "Test line #{i}")
        end)
      end,
      "memory_large_buffer_allocation" => fn -> ScreenBuffer.new(500, 500) end,
      "memory_plugin_system" => fn ->
        alias Raxol.Plugins.Manager
        {:ok, manager} = Manager.new()
        Manager.list_plugins(manager)
      end
    }
  end

  defp run_concurrent_benchmarks(config) do
    jobs = %{
      "concurrent_emulator_creation" => &bench_emulator_creation/0,
      "concurrent_buffer_writes" => &bench_buffer_writes/0,
      "concurrent_event_dispatch" => &bench_event_dispatch/0,
      "concurrent_plugin_operations" => &bench_plugin_operations/0
    }

    Benchee.run(jobs, config)
  end

  defp bench_emulator_creation do
    alias Raxol.Terminal.Emulator

    1..10
    |> Enum.map(fn _ -> Task.async(fn -> Emulator.new(80, 24) end) end)
    |> Task.await_many()
  end

  defp bench_buffer_writes do
    alias Raxol.Terminal.ScreenBufferAdapter, as: ScreenBuffer
    buffer = ScreenBuffer.new(80, 24)

    1..10
    |> Enum.map(fn i ->
      Task.async(fn -> ScreenBuffer.write_char(buffer, i, i, "X") end)
    end)
    |> Task.await_many()
  end

  defp bench_event_dispatch do
    alias Raxol.Core.Events.EventManager

    case EventManager.start_link(name: EventManager) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    1..20
    |> Enum.map(fn i ->
      Task.async(fn -> EventManager.dispatch(:test_event, %{id: i}) end)
    end)
    |> Task.await_many()
  end

  defp bench_plugin_operations do
    alias Raxol.Plugins.Manager

    {:ok, manager} = Manager.new()

    1..5
    |> Enum.map(fn _ ->
      Task.async(fn ->
        _plugins = Manager.list_plugins(manager)
        Manager.get_plugin_state(manager, "test_plugin")
      end)
    end)
    |> Task.await_many()
  end

  defp standard_config(timestamp \\ nil) do
    ts = timestamp || DateTime.utc_now() |> DateTime.to_iso8601()

    [
      time: 5,
      memory_time: 2,
      warmup: 1,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.JSON,
         file: "bench/output/enhanced/json/benchmark_#{ts}.json"},
        {Benchee.Formatters.HTML,
         file: "bench/output/enhanced/html/benchmark_#{ts}.html",
         auto_open: false}
      ],
      save: [path: "bench/output/enhanced/benchee_#{ts}.benchee"],
      load: "bench/output/enhanced/*.benchee"
    ]
  end

  defp quick_config do
    [
      time: 1,
      memory_time: 0.5,
      warmup: 0.2,
      formatters: [Benchee.Formatters.Console]
    ]
  end

  # -- Framework-level suites --

  @compile {:no_warn_undefined, Raxol.Benchmark.Formatter}

  defp run_framework_suite(suite, opts) do
    quick = opts[:quick] || false

    case resolve_suite(suite, quick) do
      {:run, jobs, config} ->
        prev_level = Logger.level()
        if suite == "startup", do: Logger.configure(level: :error)

        result = Benchee.run(jobs, config)

        if suite == "startup", do: Logger.configure(level: prev_level)
        maybe_write_output(result, suite, opts)

      :skip ->
        handle_non_benchee_suite(suite, opts)
    end
  end

  defp resolve_suite(suite, quick) do
    config = if quick, do: quick_config(), else: framework_config()

    case suite do
      "render" ->
        {:run, Raxol.Benchmark.Suites.RenderThroughput.jobs(quick: quick),
         config}

      "latency" ->
        {:run, Raxol.Benchmark.Suites.InputLatency.jobs(quick: quick), config}

      "memory_widgets" ->
        config = Keyword.put(config, :memory_time, 2)
        {:run, Raxol.Benchmark.Suites.WidgetMemory.jobs(quick: quick), config}

      "startup" ->
        {:run, Raxol.Benchmark.Suites.Startup.jobs(quick: quick), config}

      _ ->
        :skip
    end
  end

  defp handle_non_benchee_suite("comparison", _opts),
    do: print_comparison_table()

  defp handle_non_benchee_suite("all", opts), do: run_all_framework_suites(opts)

  defp handle_non_benchee_suite(other, _opts) do
    Mix.shell().error("Unknown suite: #{other}")
  end

  defp run_all_framework_suites(opts) do
    for suite <- ~w(render latency memory_widgets startup) do
      Mix.shell().info("\n--- Suite: #{suite} ---")
      run_framework_suite(suite, opts)
    end

    print_comparison_table()
  end

  defp print_comparison_table do
    Mix.shell().info("\n=== COMPETITOR COMPARISON (static reference) ===")

    shell = Mix.shell()

    Raxol.Benchmark.Suites.Comparison.comparison_table()
    |> Enum.each(fn line -> shell.info(line) end)

    Mix.shell().info(
      "\nNote: Competitor numbers are published estimates. Raxol numbers are measured above."
    )
  end

  defp maybe_write_output(result, suite, opts) do
    case opts[:format] do
      nil ->
        :ok

      format ->
        write_formatted_output(format, opts[:output], %{suite => result})
    end
  end

  defp write_formatted_output("json", path, data) when is_binary(path) do
    content = Raxol.Benchmark.Formatter.json(data, include_system: true)
    :ok = Raxol.Benchmark.Formatter.write(content, path)
    Mix.shell().info("JSON results written to #{path}")
  end

  defp write_formatted_output("markdown", path, data) when is_binary(path) do
    content = Raxol.Benchmark.Formatter.markdown(data)
    :ok = Raxol.Benchmark.Formatter.write(content, path)
    Mix.shell().info("Markdown results written to #{path}")
  end

  defp write_formatted_output("json", nil, data),
    do: IO.puts(Raxol.Benchmark.Formatter.json(data))

  defp write_formatted_output("markdown", nil, data),
    do: IO.puts(Raxol.Benchmark.Formatter.markdown(data))

  defp write_formatted_output(_format, _path, _data), do: :ok

  defp framework_config do
    [
      time: 3,
      memory_time: 1,
      warmup: 0.5,
      formatters: [Benchee.Formatters.Console]
    ]
  end

  defp print_help do
    Mix.shell().info("""

    Raxol Enhanced Benchmarking Tool

    Usage:
      mix raxol.bench                    # Run all benchmarks
      mix raxol.bench render             # Framework render throughput
      mix raxol.bench latency            # Framework input latency
      mix raxol.bench memory_widgets     # Widget memory profiling
      mix raxol.bench startup            # Lifecycle startup timing
      mix raxol.bench comparison         # Show competitor reference data
      mix raxol.bench parser             # Legacy: parser benchmarks
      mix raxol.bench terminal           # Legacy: terminal benchmarks
      mix raxol.bench rendering          # Legacy: rendering benchmarks
      mix raxol.bench memory             # Legacy: memory benchmarks
      mix raxol.bench dashboard          # Generate dashboard from latest results

    Options:
      --suite NAME                       # Run a specific suite (render, latency, etc.)
      --quick                            # Quick benchmark run (reduced time)
      --format FORMAT                    # Output format: json, markdown
      --output PATH                      # Write formatted output to file
      --compare                          # Compare with previous results
      --dashboard                        # Generate full performance dashboard
      --regression                       # Check for performance regressions (5% threshold)
      --help                             # Show this help

    Examples:
      mix raxol.bench --quick            # Quick performance check
      mix raxol.bench render             # Render throughput only
      mix raxol.bench --suite render --format markdown --output BENCHMARKS.md
      mix raxol.bench parser --dashboard # Parser benchmarks + dashboard
      mix raxol.bench --regression       # Full benchmarks with regression detection

    Output:
      Results are saved to bench/output/enhanced/ with:
      * HTML reports for interactive viewing
      * JSON data for programmatic analysis
      * Performance dashboard with charts
      * Regression analysis reports
      * Baseline metrics for comparison
    """)
  end
end
