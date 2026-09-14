# Buffer throughput + per-cell memory gate.
#
#   mix run --no-start bench/core/buffer_gate.exs
#
# Exit codes: 0 = every budget met, 1 = a budget was breached, 2 = the gate
# could not measure what it claims to measure (see MEASUREMENT INTEGRITY).
# Exit 2 is NOT a pass.
#
# Why this exists: `test/raxol/core/buffer/buffer_performance_test.exs` was a
# benchmark living in the ExUnit suite (wall-clock `assert`s, `IO.puts`,
# `:erlang.memory(:total)` deltas) and was deleted for it. Nothing replaced it,
# so buffer fill/read/scroll cost and per-cell memory were gated nowhere
# (issue #1034). `bench/core/buffer_benchmark.exs` is a Benchee report for the
# `Raxol.Core.Buffer` compatibility shim; this gate measures the real
# `Raxol.Terminal.Buffer` with `Cell` structs and fails the build.
#
# ---------------------------------------------------------------------------
# WHAT THESE BUDGETS CAN AND CANNOT DETECT
# ---------------------------------------------------------------------------
# The throughput budgets carry ~5x headroom over the SLOWEST value observed
# while setting them, because a shared CI runner is both slower and noisier
# than a developer box. Six baseline runs on the same machine and the same
# code spread 3x (80x24 fill), 17x (200x100 read) and 9x (500x500 read), so
# "5x over the slowest" works out to 12-20x over a typical run on fill and
# more than that on read.
#
# State that plainly rather than dressing it up: these rows catch an
# order-of-magnitude regression -- an accidental O(n) -> O(n^2), a per-write
# whole-grid rebuild, an `inspect/1` or a sleep in a hot path. They do NOT
# catch a 2x regression, and a 10x per-write slowdown was measured to slip
# through the fill rows (verified: a row rebuild repeated 10 times per
# `set_cell/4` passes; repeated 50 times fails all three fill rows). A green
# run means "no blow-up", never "throughput did not change".
#
# The memory budget is the tight one: `:erts_debug.flat_size/1` is a pure
# function of the term's shape, so it returned 456.29 / 456.09 / 456.03
# bytes-per-cell across three sizes and every run, to the last decimal. It is
# gated at 1.5x, which does catch a `Cell` or `TextFormatting` struct growing
# a field.
#
# `:erts_debug.size/1` (the sharing-aware variant) is deliberately NOT used:
# it is affordable at 1920 and 20000 cells (240 B/cell there, since the one
# shared `TextFormatting` struct is counted once) but it did not finish in 49
# minutes on the 250000-cell buffer. `flat_size/1` is O(term), and as the copy
# footprint it is also the number that matters when a buffer crosses a process
# boundary.
#
# ---------------------------------------------------------------------------
# MEASUREMENT INTEGRITY
# ---------------------------------------------------------------------------
# A gate that passes when it measured nothing is worse than no gate (the same
# rule `scripts/check-quality-ratchet.sh` documents at length). Three ways
# this particular gate could lie, and the check that stops each:
#
#   1. `Buffer.scroll/2` has a `rescue` clause that logs and returns the
#      buffer UNCHANGED. A broken scroll is therefore fast and cheap, and
#      would read as a large improvement. Checked: the scrolled buffer's
#      `cells` must differ from the filled buffer's.
#   2. A `set_cell/4` that silently dropped writes would make `fill` fast.
#      Checked: cells are read back at four corners and the centre and must
#      carry the character the fill wrote.
#   3. A measurement that never ran leaves 0 us / 0 words behind, which beats
#      every budget. Checked: every duration must be > 0 us, `flat_size` must
#      exceed one word per cell, and the number of collected measurements must
#      equal sizes x metrics before any verdict is printed.
#
# Each failure aborts with exit 2 and the word ABORT, never a PASS row.
#
# ---------------------------------------------------------------------------
# BUDGETS
# ---------------------------------------------------------------------------
# Baseline: Apple M1 (aarch64-apple-darwin, 8 schedulers), OTP 29,
# Elixir 1.20.2, `mix run --no-start`, MIX_ENV=dev. Eight runs of this script,
# some with five other mix compiles on the box; "observed" is the range across
# all of them, and each budget is derived from the slow end.
#
#   size      metric            observed range   budget   x slowest
#   80x24     fill us/cell         0.68 -  2.28    12.0     5.3x
#   80x24     read us/get_cell     0.45 -  2.02    10.0     5.0x
#   80x24     scroll us/op         0.45 -  1.95    10.0     5.1x
#   80x24     bytes/cell                  456.29   685.0    1.5x
#   200x100   fill us/cell         2.08 - 10.37    50.0     4.8x
#   200x100   read us/get_cell     1.29 - 28.21   145.0     5.1x
#   200x100   scroll us/op         1.20 -  2.80    14.0     5.0x
#   200x100   bytes/cell                  456.09   685.0    1.5x
#   500x500   fill us/cell         6.43 - 50.16   250.0     5.0x
#   500x500   read us/get_cell     8.93 -100.03    500.0     5.0x
#   500x500   scroll us/op         5.10 - 17.65     90.0     5.1x
#   500x500   bytes/cell                  456.03   685.0    1.5x
#
# The read rows are the weakest of the four metrics and should not be read as
# a tight bound on anything. `get_cell/3` converts the whole buffer to a
# `ScreenBuffer` per call, so its cost is dominated by allocation and GC state
# rather than by the lookup: at 500x500 the same code measured 8.93 us on one
# run and 365.85 us on another (that outlier used fewer averaging passes than
# the current five, and 5x it would be a budget of 1830 us, gating nothing).
# 500.0 is 5x the slowest run at the current pass count and still sits above
# that outlier -- deliberately, because a budget that false-fails gets
# deleted, and because the metric is here to cover the deleted test's read
# case, not because it is sensitive.
#
# Runtime, once compiled: 7 s wall on an idle M1, ~4 s of it measurement,
# dominated by the two 500x500 fills, because `set_cell/4` rebuilds a list
# prefix per write -- which is also why 250000 cells is the row that would
# notice that getting worse. 40-60 s wall on the same box under five
# concurrent mix compiles.
#
# Regenerating these numbers: run the gate, take the printed "measured"
# column, and keep the same headroom factors. Do not widen a budget to make a
# red run green without saying what got slower and why that is acceptable.

defmodule BufferGate do
  @moduledoc false

  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Buffer
  alias Raxol.Terminal.Buffer.Cell

  # {width, height, fill_us_per_cell, read_us_per_get_cell, scroll_us_per_op,
  #  bytes_per_cell}
  @budgets [
    {80, 24, 12.0, 10.0, 10.0, 685.0},
    {200, 100, 50.0, 145.0, 14.0, 685.0},
    {500, 500, 250.0, 500.0, 90.0, 685.0}
  ]

  # get_cell/scroll are cheap in aggregate, so they are repeated and the
  # minimum taken; CPU contention can only ever make a pass slower.
  @read_samples 256
  @scroll_reps 20
  @passes 5
  # fill is the expensive one (500x500 is seconds), so it gets fewer passes
  # and, as the budget table records, a wider spread to absorb.
  @fill_passes 2

  @alphabet for c <- ?a..?z, do: <<c>>
  @wordsize :erlang.system_info(:wordsize)

  def run do
    style = TextFormatting.new(foreground: :red)
    warmup(style)

    print_header()

    rows = Enum.flat_map(@budgets, &measure(&1, style))
    expected = length(@budgets) * 4

    length(rows) == expected ||
      abort(
        "collected #{length(rows)} measurements, expected #{expected}; " <>
          "a size was skipped"
      )

    Enum.each(rows, &print_row/1)
    verdict(rows)
  end

  # Loads every module and lets the JIT settle, so the first measured size is
  # not an outlier. Measured cold, one 80x24 scroll reads as 58000 us instead
  # of 2 us -- a 29000x artifact of module loading.
  defp warmup(style) do
    buffer = fill(Buffer.new({20, 10}), 20, 10, style)
    _ = Buffer.get_cell(buffer, 1, 1)
    _ = Buffer.scroll(buffer, 1)
    _ = :erts_debug.flat_size(buffer)
    :ok
  end

  defp print_header do
    IO.puts("=== Raxol.Terminal.Buffer throughput + memory gate ===")

    IO.puts(
      "host: #{:erlang.system_info(:system_architecture)}, " <>
        "OTP #{:erlang.system_info(:otp_release)}, " <>
        "Elixir #{System.version()}, " <>
        "#{:erlang.system_info(:schedulers_online)} schedulers"
    )

    IO.puts("")

    IO.puts(
      String.pad_trailing("size", 10) <>
        String.pad_trailing("metric", 18) <>
        String.pad_leading("measured", 12) <>
        String.pad_leading("budget", 12) <>
        "  status"
    )
  end

  defp measure(
         {width, height, fill_budget, read_budget, scroll_budget, mem_budget},
         style
       ) do
    cells = width * height
    label = "#{width}x#{height}"

    {fill_us, filled} =
      min_pass(@fill_passes, fn ->
        fill(Buffer.new({width, height}), width, height, style)
      end)

    positive!(fill_us, "#{label} fill")
    verify_written!(filled, width, height)

    {read_us, _} =
      min_pass(@passes, fn -> read_sweep(filled, width, height) end)

    positive!(read_us, "#{label} read")

    {scroll_us, _} = min_pass(@passes, fn -> scroll_sweep(filled) end)
    positive!(scroll_us, "#{label} scroll")

    words = :erts_debug.flat_size(filled)

    words > cells ||
      abort(
        "#{label} flat_size is #{words} words for #{cells} cells; " <>
          "that is not a filled buffer"
      )

    [
      {label, "fill us/cell", fill_us / cells, fill_budget},
      {label, "read us/get_cell", read_us / @read_samples, read_budget},
      {label, "scroll us/op", scroll_us / @scroll_reps, scroll_budget},
      {label, "bytes/cell", words * @wordsize / cells, mem_budget}
    ]
  end

  # Minimum of `passes` timings, with that pass's result: CPU contention can
  # only make a measurement slower, so the minimum is the least noisy
  # estimator available without a statistics library.
  defp min_pass(passes, fun) do
    1..passes
    |> Enum.map(fn _ -> :timer.tc(fun) end)
    |> Enum.min_by(fn {us, _} -> us end)
  end

  defp fill(buffer, width, height, style) do
    Enum.reduce(0..(height - 1), buffer, fn y, acc ->
      Enum.reduce(0..(width - 1), acc, fn x, acc ->
        Buffer.set_cell(acc, x, y, Cell.new(char_at(x, y), style))
      end)
    end)
  end

  # Distinct characters per cell, so whole-cell structural sharing cannot hide
  # per-cell cost from flat_size, and so the read-back check below can tell a
  # dropped write from a lucky one. The style struct stays shared, which is
  # what real terminal content looks like.
  defp char_at(x, y), do: Enum.at(@alphabet, rem(x + y, 26))

  defp read_sweep(buffer, width, height) do
    Enum.each(0..(@read_samples - 1), fn i ->
      Buffer.get_cell(buffer, rem(i * 37, width), rem(i * 53, height))
    end)
  end

  defp scroll_sweep(buffer) do
    Enum.reduce(1..@scroll_reps, buffer, fn _, acc -> Buffer.scroll(acc, 1) end)
  end

  # Integrity check 2: the fill actually wrote cells.
  defp verify_written!(buffer, width, height) do
    coords = [
      {0, 0},
      {width - 1, 0},
      {0, height - 1},
      {width - 1, height - 1},
      {div(width, 2), div(height, 2)}
    ]

    Enum.each(coords, fn {x, y} ->
      case Buffer.get_cell(buffer, x, y) do
        %Cell{char: char} ->
          char == char_at(x, y) ||
            abort("fill did not write (#{x}, #{y}): got #{inspect(char)}")

        other ->
          abort("get_cell(#{x}, #{y}) returned #{inspect(other)}")
      end
    end)

    # Integrity check 1: scroll/2 rescues its own failures and returns the
    # buffer unchanged, which would read as a free operation.
    scrolled = Buffer.scroll(buffer, 1)

    scrolled.cells != buffer.cells ||
      abort("scroll/2 left the buffer unchanged; it is not moving content")
  end

  # Integrity check 3: a measurement that never ran costs 0 us.
  defp positive!(us, what) do
    us > 0 || abort("#{what} measured #{us} us; nothing ran")
  end

  defp print_row({label, metric, measured, budget}) do
    IO.puts(
      String.pad_trailing(label, 10) <>
        String.pad_trailing(metric, 18) <>
        String.pad_leading(fmt(measured), 12) <>
        String.pad_leading(fmt(budget), 12) <>
        "  " <> status(measured, budget)
    )
  end

  defp status(measured, budget) when measured <= budget, do: "PASS"
  defp status(_measured, _budget), do: "FAIL"

  defp fmt(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp verdict(rows) do
    breaches = Enum.reject(rows, fn {_, _, m, b} -> m <= b end)

    IO.puts("")

    case breaches do
      [] ->
        IO.puts("RESULT: PASS (#{length(rows)} budgets)")

      _ ->
        Enum.each(breaches, fn {label, metric, measured, budget} ->
          IO.puts(
            "BREACH: #{label} #{metric} = #{fmt(measured)}, " <>
              "budget #{fmt(budget)} (#{fmt(measured / budget)}x)"
          )
        end)

        IO.puts(
          "RESULT: FAIL (#{length(breaches)} of #{length(rows)} budgets breached)"
        )

        System.halt(1)
    end
  end

  defp abort(reason) do
    IO.puts(:stderr, "ABORT: #{reason}")
    IO.puts(:stderr, "The gate measured nothing it can vouch for; not a pass.")
    System.halt(2)
  end
end

BufferGate.run()
