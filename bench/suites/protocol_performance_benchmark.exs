defmodule Raxol.Bench.ProtocolPerformanceBenchmark do
  @moduledoc """
  Performance benchmark comparing protocol dispatch vs behaviour callbacks.

  This benchmark measures the performance difference between the new
  protocol-based approach and the traditional behaviour-based approach
  across various scenarios.
  """

  alias Raxol.Protocols.{Renderable, Styleable, EventHandler, Serializable}
  alias Raxol.Terminal.{ScreenBuffer, Renderer}
  alias Raxol.UI.Theming.Theme

  @doc """
  Run comprehensive protocol vs behaviour benchmarks.
  """
  def run_benchmark(opts \\ []) do
    config = %{
      time: Keyword.get(opts, :time, 5),
      warmup: Keyword.get(opts, :warmup, 2),
      memory_time: Keyword.get(opts, :memory_time, 1),
      formatters: [
        {Benchee.Formatters.HTML, auto_open: false},
        Benchee.Formatters.Console
      ]
    }

    Benchee.run(
      %{
        # Rendering benchmarks
        "Protocol: Render String" => fn data -> render_protocol_string(data) end,
        "Protocol: Render Map" => fn data -> render_protocol_map(data) end,
        "Protocol: Render ScreenBuffer" => fn data ->
          render_protocol_buffer(data)
        end,
        "Protocol: Render Theme" => fn data -> render_protocol_theme(data) end,

        # Styling benchmarks
        "Protocol: Apply Style" => fn data -> style_protocol_apply(data) end,
        "Protocol: Merge Styles" => fn data -> style_protocol_merge(data) end,
        "Protocol: Convert to ANSI" => fn data -> style_protocol_ansi(data) end,

        # Event handling benchmarks
        "Protocol: Handle Event" => fn data -> event_protocol_handle(data) end,
        "Protocol: Check Handler" => fn data -> event_protocol_check(data) end,
        "Protocol: Subscribe" => fn data -> event_protocol_subscribe(data) end,

        # Serialization benchmarks
        "Protocol: Serialize JSON" => fn data ->
          serialize_protocol_json(data)
        end,
        "Protocol: Serialize Binary" => fn data ->
          serialize_protocol_binary(data)
        end,

        # Traditional behaviour equivalents for comparison
        "Behaviour: Render Buffer" => fn data ->
          render_behaviour_buffer(data)
        end,
        "Behaviour: Apply Theme" => fn data -> style_behaviour_theme(data) end
      },
      [
        before_scenario: fn _input ->
          setup_benchmark_data()
        end,
        inputs: generate_benchmark_inputs()
      ] ++ Map.to_list(config)
    )
  end

  @doc """
  Setup test data for benchmarks.
  """
  def setup_benchmark_data do
    buffer = ScreenBuffer.new(80, 24)
    renderer = Renderer.new(buffer)

    theme =
      Theme.new(%{
        name: "Benchmark Theme",
        colors: %{
          primary: "#FF0000",
          secondary: "#00FF00",
          background: "#000000"
        },
        component_styles: %{
          button: %{background: :blue, foreground: :white},
          text: %{foreground: :black}
        }
      })

    component = %{
      type: :test_component,
      props: %{title: "Test", content: "Benchmark content"},
      style: %{bold: true, foreground: {255, 0, 0}},
      theme: theme,
      event_handlers: %{
        click: fn _, _, state -> {:ok, :clicked, state} end,
        keypress: fn _, _, state -> {:ok, :key_pressed, state} end
      }
    }

    event = %{
      type: :click,
      target: :component,
      timestamp: System.monotonic_time(:millisecond),
      data: %{x: 10, y: 5}
    }

    %{
      buffer: buffer,
      renderer: renderer,
      theme: theme,
      component: component,
      event: event,
      string_data: "Sample benchmark text with unicode: 测试",
      map_data: %{
        title: "Benchmark Data",
        content: "Long content for testing performance",
        metadata: %{created: DateTime.utc_now(), tags: [:test, :benchmark]}
      },
      style_data: %{
        foreground: {255, 128, 0},
        background: {0, 0, 0},
        bold: true,
        italic: false,
        underline: true
      }
    }
  end

  @doc """
  Generate various input sizes for scaling tests.
  """
  def generate_benchmark_inputs do
    %{
      "Small (10 items)" => generate_items(10),
      "Medium (100 items)" => generate_items(100),
      "Large (1000 items)" => generate_items(1000),
      "XLarge (10000 items)" => generate_items(10000)
    }
  end

  defp generate_items(count) do
    Enum.map(1..count, fn i ->
      %{
        id: i,
        text: "Item #{i}",
        style: %{foreground: {rem(i, 255), rem(i * 2, 255), rem(i * 3, 255)}},
        metadata: %{index: i, group: rem(i, 10)}
      }
    end)
  end

  # Protocol benchmark functions
  defp render_protocol_string(data) do
    Renderable.render(data[:string_data])
  end

  defp render_protocol_map(data) do
    Renderable.render(data[:map_data])
  end

  defp render_protocol_buffer(data) do
    Renderable.render(data[:buffer])
  end

  defp render_protocol_theme(data) do
    Renderable.render(data[:theme], format: :preview)
  end

  defp style_protocol_apply(data) do
    Styleable.apply_style(data[:map_data], data[:style_data])
  end

  defp style_protocol_merge(data) do
    styled = Styleable.apply_style(data[:map_data], %{bold: true})
    Styleable.merge_styles(styled, data[:style_data])
  end

  defp style_protocol_ansi(data) do
    styled = Styleable.apply_style(data[:map_data], data[:style_data])
    Styleable.to_ansi(styled)
  end

  defp event_protocol_handle(data) do
    EventHandler.handle_event(data[:component], data[:event], %{})
  end

  defp event_protocol_check(data) do
    EventHandler.can_handle?(data[:component], data[:event])
  end

  defp event_protocol_subscribe(data) do
    EventHandler.subscribe(data[:component], [:click, :keypress, :focus])
  end

  defp serialize_protocol_json(data) do
    Serializable.serialize(data[:theme], :json)
  end

  defp serialize_protocol_binary(data) do
    Serializable.serialize(data[:map_data], :binary)
  end

  # Traditional behaviour benchmark functions for comparison
  defp render_behaviour_buffer(data) do
    Renderer.render(data[:renderer])
  end

  defp style_behaviour_theme(data) do
    Theme.get_color(data[:theme], :primary)
  end

  @doc """
  Memory usage benchmark for protocols vs behaviours.
  """
  def memory_benchmark(opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 1000)

    # Protocol memory usage
    protocol_memory =
      measure_memory_usage(fn ->
        data = setup_benchmark_data()

        Enum.each(1..iterations, fn _i ->
          Renderable.render(data.string_data)
          Styleable.apply_style(data.map_data, data.style_data)
          EventHandler.handle_event(data.component, data.event, %{})
          Serializable.serialize(data.theme, :json)
        end)
      end)

    # Behaviour memory usage
    behaviour_memory =
      measure_memory_usage(fn ->
        data = setup_benchmark_data()

        Enum.each(1..iterations, fn _i ->
          Renderer.render(data.renderer)
          Theme.get_color(data.theme, :primary)
          # Traditional event handling would be function calls
          data.component.event_handlers.click.(data.component, data.event, %{})
          Jason.encode!(data.theme)
        end)
      end)

    %{
      protocol_memory: protocol_memory,
      behaviour_memory: behaviour_memory,
      difference: protocol_memory - behaviour_memory,
      ratio: protocol_memory / behaviour_memory
    }
  end

  @doc """
  Latency benchmark for different operation types.
  """
  def latency_benchmark(opts \\ []) do
    warmup_iterations = Keyword.get(opts, :warmup, 1000)
    test_iterations = Keyword.get(opts, :iterations, 10000)

    data = setup_benchmark_data()

    # Warmup
    Enum.each(1..warmup_iterations, fn _i ->
      Renderable.render(data.string_data)
      Styleable.apply_style(data.map_data, data.style_data)
    end)

    # Measure protocol dispatch latency
    protocol_times =
      Enum.map(1..test_iterations, fn _i ->
        start_time = System.monotonic_time(:nanosecond)
        Renderable.render(data.string_data)
        end_time = System.monotonic_time(:nanosecond)
        end_time - start_time
      end)

    # Measure function call latency for comparison
    function_times =
      Enum.map(1..test_iterations, fn _i ->
        start_time = System.monotonic_time(:nanosecond)
        # Direct function call
        to_string(data.string_data)
        end_time = System.monotonic_time(:nanosecond)
        end_time - start_time
      end)

    %{
      protocol_latency: calculate_stats(protocol_times),
      function_latency: calculate_stats(function_times),
      overhead: calculate_overhead(protocol_times, function_times)
    }
  end

  @doc """
  Scalability benchmark testing performance with different data sizes.
  """
  def scalability_benchmark do
    sizes = [10, 50, 100, 500, 1000, 5000, 10000]

    results =
      Enum.map(sizes, fn size ->
        items = generate_items(size)

        time =
          measure_time(fn ->
            Enum.each(items, fn item ->
              Renderable.render(item)
              Styleable.apply_style(item, %{bold: true})
            end)
          end)

        {size, time}
      end)

    %{
      results: results,
      scaling_factor: calculate_scaling_factor(results)
    }
  end

  # Helper functions
  defp measure_memory_usage(fun) do
    :erlang.garbage_collect()
    {memory_before, _} = :erlang.process_info(self(), :memory)

    fun.()

    :erlang.garbage_collect()
    {memory_after, _} = :erlang.process_info(self(), :memory)

    memory_after - memory_before
  end

  defp measure_time(fun) do
    start_time = System.monotonic_time(:microsecond)
    fun.()
    end_time = System.monotonic_time(:microsecond)
    end_time - start_time
  end

  defp calculate_stats(times) do
    sorted = Enum.sort(times)
    count = length(times)

    %{
      min: Enum.min(times),
      max: Enum.max(times),
      mean: Enum.sum(times) / count,
      median: Enum.at(sorted, div(count, 2)),
      p95: Enum.at(sorted, round(count * 0.95) - 1),
      p99: Enum.at(sorted, round(count * 0.99) - 1)
    }
  end

  defp calculate_overhead(protocol_times, function_times) do
    protocol_mean = Enum.sum(protocol_times) / length(protocol_times)
    function_mean = Enum.sum(function_times) / length(function_times)

    %{
      absolute: protocol_mean - function_mean,
      relative: (protocol_mean - function_mean) / function_mean * 100,
      ratio: protocol_mean / function_mean
    }
  end

  defp calculate_scaling_factor(results) do
    # Calculate if scaling is linear, logarithmic, etc.
    case length(results) do
      n when n < 2 ->
        :insufficient_data

      _ ->
        {sizes, times} = Enum.unzip(results)
        correlation = calculate_correlation(sizes, times)

        cond do
          correlation > 0.95 -> :linear
          correlation > 0.85 -> :near_linear
          correlation > 0.70 -> :moderate_correlation
          true -> :poor_correlation
        end
    end
  end

  defp calculate_correlation(xs, ys) do
    n = length(xs)
    mean_x = Enum.sum(xs) / n
    mean_y = Enum.sum(ys) / n

    numerator =
      xs
      |> Enum.zip(ys)
      |> Enum.map(fn {x, y} -> (x - mean_x) * (y - mean_y) end)
      |> Enum.sum()

    sum_sq_x =
      xs |> Enum.map(fn x -> (x - mean_x) * (x - mean_x) end) |> Enum.sum()

    sum_sq_y =
      ys |> Enum.map(fn y -> (y - mean_y) * (y - mean_y) end) |> Enum.sum()

    denominator = :math.sqrt(sum_sq_x * sum_sq_y)

    case denominator do
      0.0 -> 0.0
      _ -> numerator / denominator
    end
  end

  @doc """
  Generate a comprehensive performance report.
  """
  def generate_report(opts \\ []) do
    output_file = Keyword.get(opts, :output, "protocol_performance_report.html")

    IO.puts("Running protocol performance benchmarks...")

    basic_results = run_benchmark(time: 3, warmup: 1)
    memory_results = memory_benchmark(iterations: 500)
    latency_results = latency_benchmark(iterations: 5000)
    scaling_results = scalability_benchmark()

    report = %{
      timestamp: DateTime.utc_now(),
      basic_benchmark: basic_results,
      memory_benchmark: memory_results,
      latency_benchmark: latency_results,
      scalability_benchmark: scaling_results,
      summary:
        generate_summary(memory_results, latency_results, scaling_results)
    }

    case Jason.encode(report, pretty: true) do
      {:ok, json} ->
        File.write!(output_file <> ".json", json)
        IO.puts("Performance report saved to #{output_file}.json")

      {:error, reason} ->
        IO.puts("Failed to save report: #{inspect(reason)}")
    end

    report
  end

  defp generate_summary(memory_results, latency_results, scaling_results) do
    %{
      memory_overhead: "#{Float.round(memory_results.ratio, 2)}x",
      latency_overhead: "#{Float.round(latency_results.overhead.ratio, 2)}x",
      scaling_behavior: scaling_results.scaling_factor,
      recommendation: determine_recommendation(memory_results, latency_results)
    }
  end

  defp determine_recommendation(memory_results, latency_results) do
    cond do
      latency_results.overhead.ratio < 1.1 and memory_results.ratio < 1.2 ->
        "Protocols show excellent performance with minimal overhead. Recommended for new code."

      latency_results.overhead.ratio < 1.3 and memory_results.ratio < 1.5 ->
        "Protocols show good performance. Benefits outweigh costs for most use cases."

      true ->
        "Protocols show higher overhead. Consider on a case-by-case basis."
    end
  end
end
