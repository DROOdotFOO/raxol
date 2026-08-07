defmodule Mix.Tasks.Raxol.Bench.Memory do
  @compile {:no_warn_undefined, Benchee}

  @moduledoc """
  Enhanced memory benchmarking task for Raxol terminal emulator.

  Terminal-specific memory scenarios with meaningful allocations.

  Usage:
    mix raxol.bench.memory                    # Run all memory benchmarks
    mix raxol.bench.memory terminal           # Run terminal component benchmarks
    mix raxol.bench.memory buffer             # Run buffer operation benchmarks
    mix raxol.bench.memory simulation         # Run realistic usage simulations
    mix raxol.bench.memory --profile          # Include memory profiling integration
    mix raxol.bench.memory --quick            # Quick memory benchmark run
  """

  use Mix.Task

  @shortdoc "Run enhanced memory performance benchmarks"

  @switches [
    quick: :boolean,
    profile: :boolean,
    help: :boolean
  ]

  def run(args) do
    {opts, args, _} = OptionParser.parse(args, switches: @switches)

    if opts[:help] do
      print_help()
    else
      Mix.Task.run("app.start")

      case args do
        [] ->
          run_all_memory_benchmarks(opts)

        ["terminal"] ->
          run_terminal_memory_benchmarks(opts)

        ["buffer"] ->
          run_buffer_memory_benchmarks(opts)

        ["simulation"] ->
          run_simulation_memory_benchmarks(opts)

        [benchmark] ->
          Mix.shell().error("Unknown memory benchmark: #{benchmark}")
          print_help()
      end
    end
  end

  # =============================================================================
  # Benchmark Suites
  # =============================================================================

  defp run_all_memory_benchmarks(opts) do
    Mix.shell().info("Running Enhanced Memory Benchmarks...")

    results = %{}

    results = Map.put(results, :terminal, run_terminal_memory_benchmarks(opts))
    results = Map.put(results, :buffer, run_buffer_memory_benchmarks(opts))

    results =
      Map.put(results, :simulation, run_simulation_memory_benchmarks(opts))

    if opts[:profile] do
      run_memory_profiling_integration(results)
    end

    print_memory_analysis(results)
  end

  # =============================================================================
  # Terminal Component Memory Benchmarks
  # =============================================================================

  defp run_terminal_memory_benchmarks(opts) do
    Mix.shell().info("Running Terminal Component Memory Benchmarks...")

    config = memory_benchmark_config(opts)
    jobs = build_terminal_memory_jobs()

    Benchee.run(jobs, config)
  end

  defp build_terminal_memory_jobs do
    %{
      "large_terminal_1000x1000" => &benchmark_large_terminal/0,
      "huge_terminal_2000x2000" => &benchmark_huge_terminal/0,
      "multiple_terminal_buffers" => &benchmark_multiple_buffers/0,
      "memory_manager_stress" => &benchmark_memory_manager/0,
      "scrollback_buffer_large" => &benchmark_scrollback_buffer/0
    }
  end

  defp benchmark_large_terminal do
    # Allocate a very large terminal buffer
    _cells = create_terminal_cells(1000, 1000, " ", :white, :black, %{})
    :ok
  end

  defp benchmark_huge_terminal do
    # Massive terminal allocation
    _cells = create_terminal_cells(2000, 2000, "█", :red, :blue, %{bold: true})
    :ok
  end

  defp benchmark_multiple_buffers do
    # Simulate multiple terminal sessions
    _buffers =
      for _i <- 1..10 do
        create_terminal_cells(100, 100, "X", :green, :black, %{})
      end

    :ok
  end

  defp benchmark_memory_manager do
    # Test memory manager with heavy allocations
    {:ok, manager} = Raxol.Terminal.MemoryManager.start_link()

    _ = allocate_memory_chunks(100, 10_000)

    GenServer.stop(manager)
    :ok
  end

  defp benchmark_scrollback_buffer do
    # Simulate large scrollback history
    _scrollback = create_scrollback_history(10_000, 120)
    :ok
  end

  defp create_terminal_cells(rows, cols, char, fg, bg, style) do
    for _row <- 1..rows, _col <- 1..cols do
      %{char: char, fg: fg, bg: bg, style: style}
    end
  end

  defp allocate_memory_chunks(iterations, size) do
    for _i <- 1..iterations do
      _large_chunk = Enum.map(1..size, fn j -> "Memory chunk #{j}" end)
    end
  end

  defp create_scrollback_history(lines, width) do
    for line <- 1..lines do
      line_content =
        Enum.map(1..width, fn col ->
          %{char: "#{rem(col, 10)}", fg: :white, bg: :black}
        end)

      {line, line_content}
    end
  end

  # =============================================================================
  # Buffer Operations Memory Benchmarks
  # =============================================================================

  defp run_buffer_memory_benchmarks(opts) do
    Mix.shell().info("Running Buffer Operations Memory Benchmarks...")

    config = memory_benchmark_config(opts)
    jobs = build_buffer_memory_jobs()

    Benchee.run(jobs, config)
  end

  defp build_buffer_memory_jobs do
    %{
      "buffer_heavy_writes" => &benchmark_heavy_writes/0,
      "unicode_heavy_buffer" => &benchmark_unicode_buffer/0,
      "buffer_fragmentation" => &benchmark_fragmentation/0,
      "graphics_memory_simulation" => &benchmark_graphics_memory/0
    }
  end

  defp benchmark_heavy_writes do
    # Simulate heavy writing to buffer
    buffer_content = create_buffer_content(1000, 200)
    _buffer_with_metadata = add_buffer_metadata(buffer_content)
    :ok
  end

  defp benchmark_unicode_buffer do
    # Test with complex Unicode characters (higher memory per char)
    _unicode_buffer = create_unicode_buffer(500, 100)
    :ok
  end

  defp benchmark_fragmentation do
    # Create many small allocations to test fragmentation
    _fragments = create_memory_fragments(10_000)
    :ok
  end

  defp benchmark_graphics_memory do
    # Simulate graphics/image data in terminal
    _image_data = create_image_data(800, 600)
    :ok
  end

  defp create_buffer_content(lines, cols) do
    for line <- 1..lines do
      for col <- 1..cols do
        %{
          char: "#{rem(line + col, 10)}",
          fg: :cyan,
          bg: :black,
          style: %{italic: true}
        }
      end
    end
  end

  defp add_buffer_metadata(buffer_content) do
    Enum.map(buffer_content, fn line ->
      %{
        content: line,
        timestamp: System.monotonic_time(),
        metadata: %{dirty: true, rendered: false}
      }
    end)
  end

  defp create_unicode_buffer(rows, cols) do
    unicode_chars = get_unicode_test_chars()

    for _row <- 1..rows, _col <- 1..cols do
      build_unicode_cell(unicode_chars)
    end
  end

  defp get_unicode_test_chars do
    [
      "[STAR2]",
      "[FAST]",
      "[GEM]",
      "[HOT]",
      "[POWER]",
      "[TARGET]",
      "[COLOR]",
      "[STYLE]",
      "[THEATER]",
      "[CIRCUS]"
    ]
  end

  defp build_unicode_cell(unicode_chars) do
    char = Enum.random(unicode_chars)

    %{
      char: char,
      fg: Enum.random([:red, :green, :blue, :yellow, :magenta]),
      bg: :black,
      style: %{bold: true, underline: true},
      unicode_data: build_unicode_data(char)
    }
  end

  defp build_unicode_data(char) do
    %{
      codepoint: String.to_charlist(char) |> hd(),
      width: 2,
      combining: false
    }
  end

  defp create_memory_fragments(count) do
    for _i <- 1..count do
      size = Enum.random(10..100)
      Enum.map(1..size, fn j -> "Fragment #{j}" end)
    end
  end

  defp create_image_data(width, height) do
    for _y <- 1..height do
      for _x <- 1..width do
        %{
          r: Enum.random(0..255),
          g: Enum.random(0..255),
          b: Enum.random(0..255),
          a: 255,
          palette_index: Enum.random(0..255)
        }
      end
    end
  end

  # =============================================================================
  # Realistic Usage Simulation Benchmarks
  # =============================================================================

  defp run_simulation_memory_benchmarks(opts) do
    Mix.shell().info("Running Realistic Usage Simulation Memory Benchmarks...")

    config = memory_benchmark_config(opts)
    jobs = build_simulation_memory_jobs()

    Benchee.run(jobs, config)
  end

  defp build_simulation_memory_jobs do
    %{
      "vim_editing_simulation" => &benchmark_vim_session/0,
      "log_streaming_simulation" => &benchmark_log_streaming/0,
      "shell_session_simulation" => &benchmark_shell_session/0,
      "multi_pane_simulation" => &benchmark_multi_pane/0
    }
  end

  defp benchmark_vim_session do
    # Simulate editing a large file in vim
    _file_buffer = generate_vim_file_buffer(5000, 120)
    :ok
  end

  defp benchmark_log_streaming do
    # Simulate continuous log output
    _log_buffer = generate_log_buffer(20_000)
    :ok
  end

  defp benchmark_shell_session do
    # Simulate an interactive shell with command history
    _shell_state = generate_shell_state(1000)
    :ok
  end

  defp benchmark_multi_pane do
    # Simulate tmux/screen with multiple panes
    _panes = generate_terminal_panes(8)
    :ok
  end

  defp generate_vim_file_buffer(file_lines, line_length) do
    for line_num <- 1..file_lines do
      generate_vim_line_data(line_num, line_length)
    end
  end

  defp generate_vim_line_data(line_num, line_length) do
    line_content = generate_code_line(line_num, line_length)
    syntax_highlighting = generate_syntax_data(line_content)

    %{
      line_number: line_num,
      content: line_content,
      highlighting: syntax_highlighting,
      metadata: build_vim_line_metadata(line_num)
    }
  end

  defp build_vim_line_metadata(line_num) do
    %{
      modified: Enum.random([true, false]),
      dirty: false,
      folded: line_num > 100 && rem(line_num, 50) == 0
    }
  end

  defp generate_log_buffer(log_entries) do
    for i <- 1..log_entries do
      generate_log_entry(i)
    end
  end

  defp generate_log_entry(index) do
    timestamp = System.system_time(:millisecond)
    level = Enum.random([:debug, :info, :warn, :error])
    message = generate_log_message(index, level)

    %{
      timestamp: timestamp,
      level: level,
      message: message,
      formatted: format_log_entry(timestamp, level, message),
      metadata: build_log_metadata(index)
    }
  end

  defp build_log_metadata(index) do
    %{
      source: "application.#{rem(index, 10)}",
      thread: "thread-#{rem(index, 4)}",
      correlation_id: generate_uuid()
    }
  end

  defp generate_shell_state(command_history_size) do
    %{
      history: generate_command_history(command_history_size),
      current_directory: "/very/long/path/to/current/working/directory",
      environment: generate_environment_variables(),
      output_buffer: generate_shell_output_buffer(),
      prompt_state: build_prompt_state()
    }
  end

  defp build_prompt_state do
    %{
      user: "developer",
      hostname: "development-machine",
      git_branch: "feature/memory-benchmarking-enhancement",
      last_command_duration: 1234
    }
  end

  defp generate_terminal_panes(pane_count) do
    for pane_id <- 1..pane_count do
      generate_pane_data(pane_id)
    end
  end

  defp generate_pane_data(pane_id) do
    %{
      id: pane_id,
      dimensions: {80, 24},
      buffer: generate_pane_buffer(pane_id),
      scrollback: generate_scrollback(pane_id),
      application: Enum.random([:vim, :htop, :tail, :ssh, :git, :shell]),
      active: pane_id == 1
    }
  end

  # =============================================================================
  # Memory Profiling Integration
  # =============================================================================

  defp run_memory_profiling_integration(results) do
    Mix.shell().info("Running Memory Profiling Integration...")

    # Integrate with existing memory utilities
    if Code.ensure_loaded?(Raxol.Terminal.MemoryManager) do
      analyze_memory_patterns(results)
    end

    if Code.ensure_loaded?(Raxol.Terminal.ScreenBuffer.MemoryUtils) do
      analyze_buffer_memory_patterns(results)
    end
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  defp memory_benchmark_config(opts) do
    base_config = [
      time: if(opts[:quick], do: 1, else: 3),
      memory_time: if(opts[:quick], do: 1, else: 2),
      warmup: if(opts[:quick], do: 0.5, else: 1),
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.HTML,
         file: "bench/output/memory_benchmarks.html", auto_open: false}
      ]
    ]

    if opts[:profile] do
      base_config ++
        [
          pre_check: true,
          save: [path: "bench/snapshots/memory_#{timestamp()}.benchee"]
        ]
    else
      base_config
    end
  end

  defp generate_code_line(line_num, length) do
    code_line_template(rem(line_num, 10), line_num)
    |> pad_code_line(length)
  end

  defp code_line_template(0, line_num), do: "def function_#{line_num}(param) do"
  defp code_line_template(1, line_num), do: "  # Comment for line #{line_num}"

  defp code_line_template(2, _line_num),
    do: "  @spec some_function(integer()) :: {:ok, term()}"

  defp code_line_template(3, _line_num),
    do: "  result = expensive_operation(param)"

  defp code_line_template(4, line_num),
    do: "  Log.info(\"Processing #{line_num}\")"

  defp code_line_template(5, _line_num), do: "  {:ok, result}"
  defp code_line_template(6, _line_num), do: "end"
  defp code_line_template(7, _line_num), do: ""
  defp code_line_template(8, _line_num), do: "# Module documentation"

  defp code_line_template(9, line_num),
    do: "defmodule MyModule.SubModule#{line_num} do"

  defp pad_code_line("", _length), do: ""
  defp pad_code_line(line, length), do: String.pad_trailing(line, length)

  defp generate_syntax_data(line_content) do
    # Simulate syntax highlighting tokens
    words = String.split(line_content)

    Enum.map(words, fn word ->
      color =
        case word do
          "def" -> :magenta
          "end" -> :magenta
          word when word in ["Logger", "String", "Enum"] -> :blue
          "@" <> _ -> :cyan
          "#" <> _ -> :green
          _ -> :white
        end

      %{text: word, color: color, style: []}
    end)
  end

  defp generate_log_message(i, level) do
    templates = [
      "User action completed successfully for user_id: #{i}",
      "Database query executed in #{Enum.random(1..100)}ms",
      "Cache hit for key: application.cache.#{rem(i, 1000)}",
      "Processing request #{i} from IP 192.168.1.#{rem(i, 255)}",
      "Background job #{i} completed with status: #{Enum.random([:success, :failed, :retrying])}",
      "Memory usage: #{Enum.random(50..95)}% of available heap"
    ]

    base_message = Enum.random(templates)

    if level == :error do
      base_message <>
        " | Error: #{Enum.random(["timeout", "connection_refused", "invalid_input"])}"
    else
      base_message
    end
  end

  defp format_log_entry(timestamp, level, message) do
    formatted_time =
      DateTime.from_unix!(timestamp, :millisecond) |> DateTime.to_iso8601()

    level_str = String.upcase(to_string(level))
    "[#{formatted_time}] #{level_str}: #{message}"
  end

  defp generate_command_history(count) do
    commands = [
      "ls -la",
      "cd /usr/local/bin",
      "git status",
      "git add .",
      "git commit -m 'Update'",
      "mix test",
      "mix compile",
      "docker ps",
      "docker logs -f container_name",
      "tail -f /var/log/application.log",
      "htop",
      "ps aux | grep elixir",
      "find . -name '*.ex' | xargs grep -l 'defmodule'",
      "cat config.exs"
    ]

    for i <- 1..count do
      %{
        command: Enum.random(commands),
        timestamp: System.system_time(:millisecond) - (count - i) * 1000,
        # Most commands succeed
        exit_code: Enum.random([0, 0, 0, 1]),
        duration: Enum.random(10..5000)
      }
    end
  end

  defp generate_environment_variables do
    %{
      "PATH" => "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      "HOME" => "/Users/developer",
      "SHELL" => "/bin/zsh",
      "TERM" => "xterm-256color",
      "EDITOR" => "vim",
      "LANG" => "en_US.UTF-8",
      "MIX_ENV" => "dev",
      "ELIXIR_VERSION" => "1.17.1",
      "ERLANG_VERSION" => "25.3.2.7"
    }
  end

  defp generate_shell_output_buffer do
    # Generate realistic shell output
    for _i <- 1..500 do
      Enum.random([
        "Compiling 15 files (.ex)",
        "Generated raxol app",
        "Running ExUnit with seed: 123456",
        "...................................................................................................",
        "Finished in 2.5 seconds",
        "158 tests, 0 failures",
        "Coverage: 98.7%"
      ])
    end
  end

  defp generate_pane_buffer(pane_id) do
    case rem(pane_id, 4) do
      0 -> generate_vim_buffer()
      1 -> generate_htop_buffer()
      2 -> generate_log_tail_buffer()
      3 -> generate_shell_buffer()
    end
  end

  defp generate_vim_buffer do
    # Simulate vim interface
    for line <- 1..24 do
      case line do
        24 ->
          "-- INSERT --                                    100%    Col 42"

        _ ->
          String.pad_trailing("  #{line}  | Code line #{line} with syntax", 80)
      end
    end
  end

  defp generate_htop_buffer do
    # Simulate htop output
    for line <- 1..24 do
      case line do
        1 ->
          "  CPU[||||||||||                         45.2%]"

        2 ->
          "  Mem[||||||||||||||||               2.1G/8.0G]"

        3 ->
          "  Swp[                                  0K/2.0G]"

        _ ->
          "#{String.pad_leading("#{line * 100}", 5)} user    20   0  #{Enum.random(100..999)}M  #{Enum.random(10..99)}M   #{Enum.random(1..10)}M S   0.7   1.2   0:#{Enum.random(10..59)}.#{Enum.random(10..99)} beam.smp"
      end
    end
  end

  defp generate_log_tail_buffer do
    # Simulate tail -f output
    for i <- 1..24 do
      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      "[#{timestamp}] INFO: Log entry #{i} - Processing request"
    end
  end

  defp generate_shell_buffer do
    # Simulate shell session
    for i <- 1..12 do
      if rem(i, 2) == 1 do
        "developer@machine:~/project $ command_#{i}"
      else
        "Output from command #{i - 1}"
      end
    end
  end

  defp generate_scrollback(pane_id) do
    # Generate scrollback history for pane
    history_size = Enum.random(100..1000)

    for i <- 1..history_size do
      "Pane #{pane_id} history line #{i} - #{DateTime.utc_now() |> DateTime.to_iso8601()}"
    end
  end

  defp analyze_memory_patterns(_results) do
    Mix.shell().info("Analyzing memory usage patterns...")
    # Integration point for memory analysis
  end

  defp analyze_buffer_memory_patterns(_results) do
    Mix.shell().info("Analyzing buffer memory patterns...")
    # Integration point for buffer memory analysis
  end

  defp print_memory_analysis(results) do
    Mix.shell().info("\n=== Memory Benchmark Analysis ===")

    Mix.shell().info(
      "Terminal component benchmarks: #{map_size(results[:terminal] || %{})} scenarios"
    )

    Mix.shell().info(
      "Buffer operation benchmarks: #{map_size(results[:buffer] || %{})} scenarios"
    )

    Mix.shell().info(
      "Simulation benchmarks: #{map_size(results[:simulation] || %{})} scenarios"
    )

    Mix.shell().info("Results saved to: bench/output/memory_benchmarks.html")
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:-]/, "")
  end

  defp generate_uuid do
    # Simple UUID-like string generator
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> String.replace(
      ~r/(.{8})(.{4})(.{4})(.{4})(.{12})/,
      "\\1-\\2-\\3-\\4-\\5"
    )
  end

  defp print_help do
    Mix.shell().info("""
    Raxol Enhanced Memory Benchmarking Tool

    Usage:
      mix raxol.bench.memory                    # Run all memory benchmarks
      mix raxol.bench.memory terminal           # Terminal component benchmarks
      mix raxol.bench.memory buffer             # Buffer operation benchmarks
      mix raxol.bench.memory simulation         # Realistic usage simulations

    Options:
      --quick                                   # Quick benchmark run (reduced time)
      --profile                                 # Include memory profiling integration
      --help                                    # Show this help

    Examples:
      mix raxol.bench.memory --quick            # Quick memory performance check
      mix raxol.bench.memory terminal --profile # Terminal benchmarks with profiling
      mix raxol.bench.memory simulation         # Test realistic memory usage patterns

    Output:
      Results are saved to bench/output/memory_benchmarks.html with:
      • Memory allocation patterns and peak usage
      • Memory efficiency comparisons across scenarios
      • Realistic usage simulation results
      • Memory profiling integration data
    """)
  end
end
