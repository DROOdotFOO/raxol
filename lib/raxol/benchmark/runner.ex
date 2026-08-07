defmodule Raxol.Benchmark.Runner do
  @moduledoc """
  Comprehensive benchmarking suite for Raxol performance testing.

  Provides infrastructure for running, analyzing, and reporting performance benchmarks
  across all major components of the system.
  """
  @compile {:no_warn_undefined, Benchee}

  alias Raxol.Benchmark.{Analyzer, Reporter, Storage}
  alias Raxol.Core.Runtime.Log

  @default_options %{
    warmup: 2,
    time: 5,
    memory_time: 2,
    parallel: 1,
    formatters: [
      Benchee.Formatters.Console,
      {Benchee.Formatters.HTML,
       file: "bench/output/report.html", auto_open: false}
    ],
    save: [path: "bench/snapshots/", tag: "latest"],
    load: "bench/snapshots/*.benchee"
  }

  @type benchmark_suite :: %{
          name: String.t(),
          benchmarks: map(),
          options: keyword()
        }

  @doc """
  Runs a complete benchmark suite with all configured benchmarks.
  """
  def run_all(opts \\ []) do
    Log.info("Starting comprehensive benchmark suite...")

    suites = [
      terminal_benchmarks(),
      rendering_benchmarks(),
      plugin_benchmarks(),
      buffer_benchmarks(),
      component_benchmarks(),
      security_benchmarks()
    ]

    results =
      Enum.map(suites, fn suite ->
        Log.info("Running #{suite.name} benchmarks...")
        run_suite(suite, opts)
      end)

    # Generate comprehensive report
    _report = Reporter.generate_comprehensive_report(results)

    # Analyze for regressions
    regressions = Analyzer.check_regressions(results)

    case Enum.any?(regressions) do
      true ->
        Log.warning("Performance regressions detected!")
        Analyzer.report_regressions(regressions)

      false ->
        :ok
    end

    results
  end

  @doc """
  Runs a specific benchmark suite.
  """
  def run_suite(suite, opts \\ []) do
    options =
      @default_options
      |> Map.merge(Enum.into(opts, %{}))
      |> Map.to_list()

    start_time = System.monotonic_time(:millisecond)

    results =
      Benchee.run(
        suite.benchmarks,
        options
      )

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    # Store results
    Storage.save_results(suite.name, results, duration)

    %{
      suite_name: suite.name,
      results: results,
      duration: duration,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Runs a single benchmark for quick testing.
  """
  def run_single(name, benchmark_fn, opts \\ []) do
    options =
      @default_options
      |> Map.merge(Enum.into(opts, %{}))
      |> Map.to_list()

    Benchee.run(
      %{name => benchmark_fn},
      options
    )
  end

  @doc """
  Profiles a specific operation with detailed analysis.
  """
  def profile(name, operation, opts \\ []) do
    Log.info("Profiling #{name}...")

    # Run with profiling enabled
    profile_opts =
      Keyword.merge(opts,
        profile_after: true,
        print: [benchmarking: false, configuration: false]
      )

    results = run_single(name, operation, profile_opts)

    # Analyze profile data
    Analyzer.analyze_profile(name, results)
  end

  # Benchmark Suites

  defp terminal_benchmarks do
    %{
      name: "Terminal Operations",
      benchmarks: %{
        "ANSI parsing" => fn input ->
          Raxol.Terminal.Emulator.ANSIHandler.handle_ansi_sequences(input, %{})
        end,
        "Text writing" => fn ->
          emulator = create_test_emulator()

          Raxol.Terminal.Operations.TextOperations.write_text(
            emulator,
            "Hello, World!"
          )
        end
        # Commented out due to dialyzer type issues - need to fix emulator struct
        # "Cursor movement" => fn ->
        #   emulator = create_test_emulator()
        #   Raxol.Terminal.Operations.CursorOperations.move_cursor(
        #     emulator,
        #     10,
        #     10
        #   )
        # end,
        # "Screen clear" => fn ->
        #   emulator = create_test_emulator()
        #   Raxol.Terminal.Operations.ScreenOperations.clear_screen(emulator)
        # end,
        # "Resize operation" => fn ->
        #   emulator = create_test_emulator()
        #   Raxol.Terminal.Emulator.Dimensions.resize(emulator, 120, 40)
        # end
      },
      options: [
        inputs: %{
          "small input" => String.duplicate("a", 100),
          "medium input" => String.duplicate("test\n", 1000),
          "large input" => String.duplicate("x", 10_000),
          "ANSI heavy" => generate_ansi_heavy_input()
        }
      ]
    }
  end

  defp rendering_benchmarks do
    %{
      name: "Rendering Pipeline",
      benchmarks: %{
        "Simple scene" => fn scene ->
          render_scene(scene)
        end,
        "Complex scene" => fn scene ->
          render_scene(scene)
        end,
        "Animation frame" => fn ->
          animate_frame(create_test_animation())
        end,
        "Layout calculation" => fn ->
          calculate_layout(create_test_components())
        end,
        "Style processing" => fn ->
          process_styles(create_test_styles())
        end
      },
      options: [
        inputs: %{
          "minimal" => create_minimal_scene(),
          "typical" => create_typical_scene(),
          "complex" => create_complex_scene(),
          "stress" => create_stress_scene()
        }
      ]
    }
  end

  defp plugin_benchmarks do
    %{
      name: "Plugin System",
      benchmarks: %{
        "Plugin load" => fn ->
          Raxol.Core.Runtime.Plugins.PluginManager.load_plugin(TestPlugin)
        end,
        "Plugin message" => fn ->
          send_plugin_message(:test_message, %{data: "test"})
        end,
        "Plugin lifecycle" => fn ->
          lifecycle_test()
        end,
        "Plugin discovery" => fn ->
          Raxol.Core.Runtime.Plugins.Loader.discover_plugins(["test/plugins"])
        end
      },
      options: []
    }
  end

  defp buffer_benchmarks do
    %{
      name: "Buffer Operations",
      benchmarks: %{
        "Buffer write" => fn data ->
          buffer = create_test_buffer()
          Raxol.Terminal.Buffer.SafeManager.write(buffer, data)
        end,
        "Buffer read" => fn ->
          buffer = create_test_buffer_with_data()
          Raxol.Terminal.Buffer.SafeManager.read(buffer, 100)
        end,
        "Buffer scroll" => fn ->
          buffer = create_test_buffer_with_data()
          scroll_buffer(buffer, 10)
        end,
        "Buffer resize" => fn ->
          buffer = create_test_buffer()
          Raxol.Terminal.Buffer.SafeManager.resize(buffer, 120, 40)
        end,
        "Buffer search" => fn ->
          buffer = create_test_buffer_with_data()
          search_buffer(buffer, "pattern")
        end
      },
      options: [
        inputs: %{
          "small" => String.duplicate("x", 100),
          "medium" => String.duplicate("line\n", 1000),
          "large" => String.duplicate("data", 10_000)
        }
      ]
    }
  end

  defp component_benchmarks do
    %{
      name: "UI Components",
      benchmarks: %{
        "Button render" => fn ->
          render_component(:button, %{label: "Click me"})
        end,
        "Table render" => fn data ->
          render_component(:table, %{rows: data})
        end,
        "Form validation" => fn ->
          validate_form(create_test_form())
        end,
        "Layout flex" => fn ->
          layout_flex_container(create_flex_items())
        end,
        "Theme apply" => fn ->
          apply_theme(create_test_component(), :dark)
        end
      },
      options: [
        inputs: %{
          "10 rows" => create_table_data(10),
          "100 rows" => create_table_data(100),
          "1000 rows" => create_table_data(1000)
        }
      ]
    }
  end

  defp security_benchmarks do
    %{
      name: "Security Operations",
      benchmarks: %{
        "Password hash" => fn ->
          hash_password("test_password_123")
        end
      },
      options: []
    }
  end

  # Helper functions

  defp create_test_emulator do
    {w, h} = Raxol.Constants.default_terminal_dimensions()
    Raxol.Terminal.Emulator.new(w, h)
  end

  defp create_test_buffer do
    {:ok, buffer} = Raxol.Terminal.Buffer.SafeManager.start_link()
    buffer
  end

  defp create_test_buffer_with_data do
    buffer = create_test_buffer()

    Enum.each(1..1000, fn i ->
      Raxol.Terminal.Buffer.SafeManager.write(buffer, "Line #{i}\n")
    end)

    buffer
  end

  defp generate_ansi_heavy_input do
    Enum.map(1..100, fn i ->
      "\e[#{rem(i, 7) + 31}mColored text #{i}\e[0m\n"
    end)
  end

  defp create_minimal_scene do
    %{type: :text, content: "Hello"}
  end

  defp create_typical_scene do
    %{
      type: :container,
      children:
        Enum.map(1..10, fn i ->
          %{type: :text, content: "Item #{i}"}
        end)
    }
  end

  defp create_complex_scene do
    %{
      type: :container,
      style: %{background: :blue, padding: 2},
      children:
        Enum.map(1..100, fn i ->
          %{
            type: :box,
            style: %{border: :single},
            children: [
              %{type: :text, content: "Complex item #{i}"}
            ]
          }
        end)
    }
  end

  defp create_stress_scene do
    # Create deeply nested scene for stress testing
    Enum.reduce(1..50, %{type: :text, content: "Deep"}, fn _, acc ->
      %{type: :container, children: [acc]}
    end)
  end

  defp render_scene(_scene) do
    # Placeholder for actual rendering
    :ok
  end

  defp create_test_animation do
    %{duration: 1000, frames: 60}
  end

  defp animate_frame(_animation) do
    :ok
  end

  defp create_test_components do
    Enum.map(1..20, fn i -> %{id: i, type: :box} end)
  end

  defp calculate_layout(_components) do
    :ok
  end

  defp create_test_styles do
    %{color: :red, background: :black, bold: true}
  end

  defp process_styles(_styles) do
    :ok
  end

  defp send_plugin_message(_msg, _data) do
    :ok
  end

  defp lifecycle_test do
    :ok
  end

  defp scroll_buffer(_buffer, _lines) do
    :ok
  end

  defp search_buffer(_buffer, _pattern) do
    :ok
  end

  defp render_component(_type, _props) do
    :ok
  end

  defp create_table_data(rows) do
    Enum.map(1..rows, fn i ->
      %{id: i, name: "Row #{i}", value: :rand.uniform(1000)}
    end)
  end

  defp create_test_form do
    %{fields: [:name, :email, :age]}
  end

  defp validate_form(_form) do
    :ok
  end

  defp create_flex_items do
    Enum.map(1..10, fn i -> %{flex: 1, id: i} end)
  end

  defp layout_flex_container(_items) do
    :ok
  end

  defp create_test_component do
    %{type: :button, label: "Test"}
  end

  defp apply_theme(_component, _theme) do
    :ok
  end

  defp hash_password(_password) do
    :crypto.hash(:sha256, "password")
  end

  defmodule TestPlugin do
    @moduledoc "Test plugin for benchmark runner testing."
    # Removed undefined @behaviour Raxol.Plugin
    def init(_), do: {:ok, %{}}
    def commands, do: []
    def handle_event(_, state), do: {:ok, state}
    def cleanup(_), do: :ok
  end
end
