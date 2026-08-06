# Framework Comparison Benchmark
#
# Measures Raxol performance on operations common across TUI frameworks:
# buffer creation, cell writes, screen diff, ANSI parsing, layout, tree diff.
#
# Results are compared against published/measured numbers from:
# - Ratatui (Rust) -- https://github.com/ratatui/ratatui
# - Bubble Tea (Go) -- https://github.com/charmbracelet/bubbletea
# - Textual (Python) -- https://github.com/Textualize/textual
#
# Usage:
#   mix run bench/suites/comparison/framework_comparison.exs
#   mix run bench/suites/comparison/framework_comparison.exs -- --quick

Logger.configure(level: :error)

defmodule FrameworkComparison do
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.TerminalParser
  alias Raxol.Terminal.ScreenBuffer
  alias Raxol.UI.Rendering.TreeDiffer

  @warmup 2
  @time 5

  def run(opts \\ []) do
    quick = Keyword.get(opts, :quick, false)
    warmup = if quick, do: 1, else: @warmup
    time = if quick, do: 2, else: @time

    IO.puts(header())
    IO.puts("")

    results = %{}

    # 1. Buffer creation
    IO.puts("Running: Buffer Creation...")

    results =
      Map.put(
        results,
        :buffer_create,
        bench(
          "buffer_create",
          fn ->
            ScreenBuffer.new(80, 24)
          end,
          warmup,
          time
        )
      )

    results =
      Map.put(
        results,
        :buffer_create_large,
        bench(
          "buffer_create_large",
          fn ->
            ScreenBuffer.new(200, 50)
          end,
          warmup,
          time
        )
      )

    # 2. Cell writes
    IO.puts("Running: Cell Writes...")
    buf = ScreenBuffer.new(80, 24)

    results =
      Map.put(
        results,
        :cell_write_single,
        bench(
          "cell_write_single",
          fn ->
            ScreenBuffer.write_char(buf, 40, 12, "X")
          end,
          warmup,
          time
        )
      )

    results =
      Map.put(
        results,
        :cell_write_line,
        bench(
          "cell_write_line",
          fn ->
            Enum.reduce(0..79, buf, fn x, b ->
              ScreenBuffer.write_char(b, x, 12, "X")
            end)
          end,
          warmup,
          time
        )
      )

    results =
      Map.put(
        results,
        :cell_write_full,
        bench(
          "cell_write_full",
          fn ->
            Enum.reduce(0..23, buf, fn y, b_outer ->
              Enum.reduce(0..79, b_outer, fn x, b ->
                ScreenBuffer.write_char(b, x, y, "X")
              end)
            end)
          end,
          warmup,
          time
        )
      )

    # 3. ANSI parsing
    IO.puts("Running: ANSI Parsing...")
    emu = Emulator.new(80, 24)
    plain = "Hello, World!"
    colored = "\e[31mRed \e[32mGreen \e[34mBlue\e[0m Normal"

    heavy =
      Enum.map_join(1..50, "", fn i -> "\e[#{i};1H\e[K\e[36mLine #{i}\e[0m" end)

    results =
      Map.put(
        results,
        :parse_plain,
        bench(
          "parse_plain",
          fn ->
            TerminalParser.parse(emu, plain)
          end,
          warmup,
          time
        )
      )

    results =
      Map.put(
        results,
        :parse_colored,
        bench(
          "parse_colored",
          fn ->
            TerminalParser.parse(emu, colored)
          end,
          warmup,
          time
        )
      )

    results =
      Map.put(
        results,
        :parse_heavy,
        bench(
          "parse_heavy",
          fn ->
            TerminalParser.parse(emu, heavy)
          end,
          warmup,
          time
        )
      )

    # 4. Tree diffing (virtual DOM)
    IO.puts("Running: Tree Diffing...")

    simple_tree = %{
      type: :view,
      children: [
        %{type: :text, attrs: %{content: "Hello"}}
      ]
    }

    simple_modified = %{
      type: :view,
      children: [
        %{type: :text, attrs: %{content: "World"}}
      ]
    }

    complex_tree = %{
      type: :view,
      children:
        Enum.map(1..100, fn i ->
          %{type: :text, attrs: %{content: "Row #{i}"}}
        end)
    }

    complex_modified =
      put_in(
        complex_tree,
        [:children, Access.at(50), :attrs, :content],
        "Modified"
      )

    results =
      Map.put(
        results,
        :diff_no_change,
        bench(
          "diff_no_change",
          fn ->
            TreeDiffer.diff_trees(simple_tree, simple_tree)
          end,
          warmup,
          time
        )
      )

    results =
      Map.put(
        results,
        :diff_simple,
        bench(
          "diff_simple",
          fn ->
            TreeDiffer.diff_trees(simple_tree, simple_modified)
          end,
          warmup,
          time
        )
      )

    results =
      Map.put(
        results,
        :diff_100_nodes,
        bench(
          "diff_100_nodes",
          fn ->
            TreeDiffer.diff_trees(complex_tree, complex_modified)
          end,
          warmup,
          time
        )
      )

    # 5. Full frame: create buffer + write 1920 cells + tree diff
    IO.puts("Running: Full Frame...")

    results =
      Map.put(
        results,
        :full_frame,
        bench(
          "full_frame",
          fn ->
            new_buf = ScreenBuffer.new(80, 24)

            _filled =
              Enum.reduce(0..23, new_buf, fn y, b_outer ->
                Enum.reduce(0..79, b_outer, fn x, b ->
                  ScreenBuffer.write_char(b, x, y, "X")
                end)
              end)

            TreeDiffer.diff_trees(complex_tree, complex_modified)
          end,
          warmup,
          time
        )
      )

    # 6. Memory: flat heap size of one buffer term. A VM-total delta across
    # allocations is unusable here: any interleaved GC makes it wrong (it
    # measured negative). erts_debug.size counts the term's own words,
    # shared subterms once.
    IO.puts("Running: Memory...")
    buffer = ScreenBuffer.new(80, 24)
    mem_per_buffer = :erts_debug.size(buffer) * :erlang.system_info(:wordsize)

    # Print results
    IO.puts("")
    IO.puts(report(results, mem_per_buffer))
  end

  defp bench(_name, fun, warmup_s, time_s) do
    # Warmup
    warmup_end = System.monotonic_time(:millisecond) + warmup_s * 1000
    warmup_loop(fun, warmup_end)

    # Measure
    {total_us, iterations} = measure_loop(fun, time_s * 1000)
    us_per_op = total_us / iterations
    ops_per_sec = if us_per_op > 0, do: 1_000_000 / us_per_op, else: 0

    %{us_per_op: us_per_op, ops_per_sec: ops_per_sec, iterations: iterations}
  end

  defp warmup_loop(fun, end_time) do
    if System.monotonic_time(:millisecond) < end_time do
      fun.()
      warmup_loop(fun, end_time)
    end
  end

  defp measure_loop(fun, duration_ms) do
    start = System.monotonic_time(:microsecond)
    deadline = System.monotonic_time(:millisecond) + duration_ms
    count = do_measure(fun, deadline, 0)
    elapsed = System.monotonic_time(:microsecond) - start
    {elapsed, count}
  end

  defp do_measure(fun, deadline, count) do
    fun.()
    new_count = count + 1

    if rem(new_count, 100) == 0 and
         System.monotonic_time(:millisecond) >= deadline do
      new_count
    else
      if System.monotonic_time(:millisecond) >= deadline,
        do: new_count,
        else: do_measure(fun, deadline, new_count)
    end
  end

  defp header do
    """
    ================================================================
     Raxol Framework Comparison Benchmark
     #{DateTime.utc_now() |> DateTime.to_string()}
     Elixir #{System.version()} / OTP #{System.otp_release()}
     #{:erlang.system_info(:system_architecture) |> to_string()}
    ================================================================
    """
  end

  defp report(results, mem_per_buffer) do
    rows = [
      {"Buffer create (80x24)", results.buffer_create},
      {"Buffer create (200x50)", results.buffer_create_large},
      {"Cell write (single)", results.cell_write_single},
      {"Cell write (80 cells, 1 line)", results.cell_write_line},
      {"Cell write (1920 cells, full)", results.cell_write_full},
      {"ANSI parse (plain text)", results.parse_plain},
      {"ANSI parse (colored text)", results.parse_colored},
      {"ANSI parse (50 CSI sequences)", results.parse_heavy},
      {"Tree diff (no change)", results.diff_no_change},
      {"Tree diff (1 node changed)", results.diff_simple},
      {"Tree diff (100 nodes, 1 changed)", results.diff_100_nodes},
      {"Full frame (create+write+diff)", results.full_frame}
    ]

    table_header =
      String.pad_trailing("Operation", 38) <>
        String.pad_leading("us/op", 12) <>
        String.pad_leading("ops/sec", 14)

    separator = String.duplicate("-", 64)

    table_rows =
      Enum.map(rows, fn {name, r} ->
        us_str = format_us(r.us_per_op)
        ops_str = format_ops(r.ops_per_sec)

        String.pad_trailing(name, 38) <>
          String.pad_leading(us_str, 12) <>
          String.pad_leading(ops_str, 14)
      end)

    budget_analysis = budget_check(results)

    """
    RESULTS
    #{separator}
    #{table_header}
    #{separator}
    #{Enum.join(table_rows, "\n")}
    #{separator}

    Memory: #{div(mem_per_buffer, 1024)} KB per 80x24 buffer

    FRAME BUDGET ANALYSIS (16ms = 60fps)
    #{separator}
    #{budget_analysis}
    #{separator}

    CROSS-FRAMEWORK COMPARISON
    #{separator}
    #{comparison_table(results)}
    #{separator}

    Notes:
    - Raxol numbers measured on this machine, others from published benchmarks
    - Ratatui: buffer ops from ratatui bench suite (M1 Mac, Rust 1.75)
    - Bubble Tea: estimated from charmbracelet/bubbletea benchmarks
    - Textual: estimated from Textualize/textual profiling docs
    - Direct comparison is approximate due to different architectures
    """
  end

  defp budget_check(results) do
    full_frame_us = results.full_frame.us_per_op
    full_frame_ms = full_frame_us / 1000
    pct = Float.round(full_frame_ms / 16 * 100, 1)

    status =
      cond do
        pct < 10 -> "[OK]  Excellent"
        pct < 25 -> "[OK]  Good"
        pct < 50 -> "[OK]  Acceptable"
        pct < 100 -> "[!!]  Tight"
        true -> "[XX]  Over budget"
      end

    """
      Full frame: #{format_us(full_frame_us)} (#{Float.round(full_frame_ms, 2)}ms)
      Budget used: #{pct}% of 16ms
      Verdict: #{status}
      Headroom for app logic: #{Float.round(16 - full_frame_ms, 2)}ms\
    """
  end

  defp comparison_table(results) do
    # Published/estimated numbers for comparison (microseconds per operation)
    # Sources:
    # - Ratatui: bench/buffer.rs, bench/paragraph.rs in ratatui repo
    # - Bubble Tea: github.com/charmbracelet/bubbletea benchmark discussions
    # - Textual: textual profiling from docs + issue discussions
    comparisons = [
      {
        "Buffer create 80x24",
        format_us(results.buffer_create.us_per_op),
        # Ratatui: stack-allocated, near zero
        "~0.5",
        # Bubble Tea: slice allocation
        "~2",
        # Textual: Python object creation
        "~50"
      },
      {
        "Cell write (single)",
        format_us(results.cell_write_single.us_per_op),
        # Ratatui: direct array index
        "~0.01",
        # Bubble Tea: slice set
        "~0.1",
        # Textual: Rich cell
        "~5"
      },
      {
        "Full screen write",
        format_us(results.cell_write_full.us_per_op),
        # Ratatui: 1920 array writes
        "~20",
        # Bubble Tea: string building
        "~50",
        # Textual: Python loops
        "~2000"
      },
      {
        "ANSI parse (simple)",
        format_us(results.parse_plain.us_per_op),
        # Ratatui: zero-copy parser
        "~0.3",
        # Bubble Tea: string scan
        "~1",
        # Textual: Python regex
        "~10"
      },
      {
        "Tree/view diff",
        format_us(results.diff_100_nodes.us_per_op),
        # Ratatui: immediate mode (no diff)
        "~5",
        # Bubble Tea: string compare
        "N/A",
        # Textual: CSSOM diff
        "~100"
      }
    ]

    header =
      String.pad_trailing("Operation", 24) <>
        String.pad_leading("Raxol", 10) <>
        String.pad_leading("Ratatui", 10) <>
        String.pad_leading("BubbleTea", 10) <>
        String.pad_leading("Textual", 10)

    rows =
      Enum.map(comparisons, fn {name, raxol, ratatui, bubbletea, textual} ->
        String.pad_trailing(name, 24) <>
          String.pad_leading(raxol, 10) <>
          String.pad_leading(ratatui, 10) <>
          String.pad_leading(bubbletea, 10) <>
          String.pad_leading(textual, 10)
      end)

    """
    #{header}
    #{String.duplicate("-", 64)}
    #{Enum.join(rows, "\n")}

    All values in microseconds (us). Lower is better.
    Raxol: measured. Others: published/estimated benchmarks.\
    """
  end

  defp format_us(us) when us < 1, do: "#{Float.round(us, 3)}"
  defp format_us(us) when us < 10, do: "#{Float.round(us, 2)}"
  defp format_us(us) when us < 1000, do: "#{Float.round(us, 1)}"
  defp format_us(us), do: "#{Float.round(us / 1000, 2)}ms"

  defp format_ops(ops) when ops > 1_000_000,
    do: "#{Float.round(ops / 1_000_000, 2)}M"

  defp format_ops(ops) when ops > 1_000, do: "#{Float.round(ops / 1_000, 1)}K"
  defp format_ops(ops), do: "#{round(ops)}"
end

quick = "--quick" in System.argv()
FrameworkComparison.run(quick: quick)
