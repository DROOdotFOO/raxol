# Buffer throughput + per-cell memory gate.
#
#   MIX_ENV=test mix run --no-start bench/core/buffer_gate.exs
#
# Exit codes: 0 = every budget met, 1 = a budget was breached, 2 = the gate
# could not measure what it claims to measure. Exit 2 is not a pass.
#
# This replaces the wall-clock assertions and whole-VM memory deltas formerly
# kept in ExUnit. It measures the real `Raxol.Terminal.Buffer`, not the
# `Raxol.Core.Buffer` compatibility shim measured by buffer_benchmark.exs.
#
# WHAT THE GATE MEASURES
#
# Fixtures are built before each timed sweep. `Buffer.new/1`, coordinates,
# characters, and `Cell` structs are not part of a fill timing; a fill row
# measures only repeated `Buffer.set_cell/4` calls. Read coordinates are also
# prepared before the timer. Scroll timings contain only `Buffer.scroll/2`.
#
# Five passes are taken for every throughput row and the median is reported.
# A minimum is deliberately not used: choosing the fastest pass can hide a
# regression, and the former two-pass 500x500 fill did exactly that. Each
# pass's result is checked and then discarded before the next pass, so the
# process never retains a list of large result buffers.
#
# Throughput budgets are blow-up detectors, not a promise that a 2x
# regression will fail. Against the ubuntu-latest evidence below they hold
# between 4.08x and 9.32x, not the uniform 5x an earlier version of this
# header claimed; ACCEPTED FLAKE FLOOR explains why the two narrow rows stay
# where they are. The 500x500 read row was removed: `get_cell/3` rebuilds a
# `ScreenBuffer`, making that row allocation/GC noise rather than a plausible
# guard on a lookup regression.
#
# The row-rebuild canary is concrete and is measured, not assumed. Replacing
# the single pair of `List.update_at/3` calls in `set_cell/4` with ten
# identical pairs makes the timed operation perform ten target-row rebuilds
# per write. On this harness that multiplied the 200x100 fill row by 12.7x
# (1.91 -> 24.30 us/cell, measured on an M1 with 8 schedulers on
# 2026-09-20); the multiplier is a property of `set_cell/4` rather than of
# the host. Applied to the 0.94 us/cell ubuntu-latest observation below it
# predicts about 12 us/cell against the 7.6 ceiling, so N=10 breaches the
# 200x100 fill row with roughly 1.6x to spare. It is not a general-purpose
# canary: the same edit multiplied the 80x24 fill row by only 5.2x
# (0.94 -> 4.92 us/cell), which would stay under that row's 4.1 ceiling on
# ubuntu-latest. Fixture work cannot dilute the canary because it is outside
# the timer.
#
# Memory has two meanings:
#
#   flat bytes/cell  `:erts_debug.flat_size/1`, with sharing expanded
#   heap bytes/cell  `:erts_debug.size_shared/1`, with sharing counted once
#
# Both are pure functions of the retained filled buffer: they walk the term,
# so no elapsed time and no garbage-collection timing enters either number.
# The heap row is omitted at 500x500 because the two smaller sizes already
# cover per-cell sharing.
#
# The 460 and 244 B/cell ceilings are independent limits, not formulas derived
# from the current result. They catch, respectively, an added `%Cell{}` field
# (456.29 -> 472.29) and loss of sharing in its attributes (240.25 -> 352.25).
# Do not ratchet either ceiling mechanically when an implementation changes.
#
# Those two ceilings sit only 0.8% and 1.5% over the observed values, which
# is deterministic today but encodes the OTP 29 x86_64 term layout of
# `%Cell{}`. If an OTP or architecture bump in an unrelated toolchain PR
# moves the observed figures, re-record the provenance block from a green
# run on the new toolchain and say that the toolchain moved it; do not
# ratchet the ceiling up by the difference to make the gate green.
#
# MEASUREMENT INTEGRITY
#
# A fast no-op must not pass:
#
#   * Every duration must be positive.
#   * Five written cells are read back after every timed fill.
#   * Every timed scroll result must preserve shape, move row 20 to row 0, and
#     blank the last row.
#   * Flat size must remain above 40 words/cell and sharing-aware size above
#     16 words/cell and no greater than flat size.
#
# Those fixed word floors distinguish a populated grid from the shared blank
# grid (about 24 flat and 2 heap words/cell). They intentionally do not call
# `Cell.new/2` or size `%Cell{}`: a floor derived from the structure being
# guarded would move with the regression and cease to be an independent
# integrity check. Integrity failures print ABORT and stop with status 2.
#
# BUDGET PROVENANCE
#
# measured_at      2026-09-16T16:24:43Z
# measured_at_sha  fe4744c
# workflow_run     35118537486
# workflow_job     104876564996
# runner           ubuntu-latest (x86_64-pc-linux-gnu, 4 schedulers)
# runtime          OTP 29, Elixir 1.20.2, MIX_ENV=test
# command          MIX_ENV=test mix run --no-start bench/core/buffer_gate.exs
#
# The run log is the review evidence. This is a green run of this branch on
# the harness that ships here, with fixture construction outside the timed
# region. The ceilings are NOT five times these values and were not derived
# from them: they come from run 35015431487 on the older harness, which
# timed fixture construction as well, and they are unchanged. Only the
# observation and headroom columns were re-recorded.
#
#   size      metric             observed   budget   headroom
#   80x24     fill us/cell           0.44      4.1      9.32x
#   80x24     read us/get_cell       0.77      4.0      5.19x
#   80x24     scroll us/op           1.00      6.2      6.20x
#   200x100   fill us/cell           0.94      7.6      8.09x
#   200x100   read us/get_cell       2.01      8.2      4.08x
#   200x100   scroll us/op           2.87     16.3      5.68x
#   500x500   fill us/cell           3.11     20.7      6.66x
#   500x500   scroll us/op          12.75     57.0      4.47x
#
# Memory in the same run was 456.29/456.09/456.03 flat B/cell and
# 240.25/240.08 heap B/cell, identical to run 35015431487 and to a local M1
# run: the two sizing functions are pure and the fixture is fixed, so those
# rows do not drift between runs or hosts. Their budgets preserve the
# independent field-growth and sharing-loss limits above rather than
# applying a timing multiplier.
#
# The timing rows do drift. Read and scroll were untouched by moving fixture
# construction out of the timer, yet they still differ between the two green
# runs (200x100 read 1.64 -> 2.01, +22%; 500x500 scroll 11.40 -> 12.75,
# +12%). Treat one run as evidence of an order of magnitude, not of a stable
# number. Replace this provenance only with retained ubuntu-latest log
# evidence from the current harness; never rebaseline by copying one green
# run into both observation and budget, and when a budget does move, name
# the observation that moved it.
#
# ACCEPTED FLAKE FLOOR
#
# Two rows carry less headroom than the rest: 200x100 read at 4.08x and
# 500x500 scroll at 4.47x. Both ceilings are deliberately left alone. Raising
# them to 5x of the observations above would rebaseline a budget from a
# single green run, which the rule above forbids, and would spend real
# sensitivity on the two rows that have the most of it.
#
# 4x is therefore the accepted floor for this table, not 5x. Because each row
# is the median of five contiguous timed windows, a false FAIL on those two
# rows needs three of the five windows stalled past 4x, or a runner that is
# sustained more than 4x slower. A noisy neighbour on ubuntu-latest typically
# costs 1.3x-3x on a window, which the median absorbs. If a green master run
# ever reports one of these rows above 4x its recorded observation, re-record
# the provenance from that run and decide from two runs, never from the run
# that failed.
#
# The read row is the one to distrust first. `get_cell/3` rebuilds a whole
# `ScreenBuffer` per lookup at every size, so the row is allocation-bound and
# tracks host load rather than lookup cost: a local M1 reported 2.29 and 7.10
# us/get_cell at 200x100 when otherwise idle, and 17.08 to 26.11 on the same
# machine at load averages of 27 to 49. A FAIL on that row must be reproduced
# on an unloaded runner before anyone calls it a regression.
#
# BUDGET CHANGES
#
# 2026-09-14  initial gate for issue #1034
# 2026-09-15  added sharing-aware memory rows and integrity checks
# 2026-09-16  replaced M1 stand-ins with run 35015431487; set timing ceilings
#             to ~5x that ubuntu-latest evidence; removed the inert 500x500
#             read row; kept memory ceilings independent
# 2026-09-20  re-recorded the observations from run 35118537486 on the
#             shipped harness. No budget moved; headroom is 4.08x-9.32x, and
#             4x is stated as the accepted floor
defmodule BufferGate do
  @moduledoc false

  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Buffer
  alias Raxol.Terminal.Buffer.Cell

  # A missing read budget omits that row. Heap sizing is likewise omitted
  # when its budget is nil.
  @budgets [
    %{
      size: {80, 24},
      fill_us_per_cell: 4.1,
      read_us_per_get_cell: 4.0,
      scroll_us_per_op: 6.2,
      flat_bytes_per_cell: 460.0,
      heap_bytes_per_cell: 244.0
    },
    %{
      size: {200, 100},
      fill_us_per_cell: 7.6,
      read_us_per_get_cell: 8.2,
      scroll_us_per_op: 16.3,
      flat_bytes_per_cell: 460.0,
      heap_bytes_per_cell: 244.0
    },
    %{
      size: {500, 500},
      fill_us_per_cell: 20.7,
      scroll_us_per_op: 57.0,
      flat_bytes_per_cell: 460.0,
      heap_bytes_per_cell: nil
    }
  ]

  @read_samples 256
  @scroll_reps 20
  @passes 5
  @flat_words_per_cell_floor 40
  @heap_words_per_cell_floor 16

  # `median_pass/3` reports the element at div(@passes, 2) of the sorted
  # timings, which is the UPPER of the two middle values when the count is
  # even -- a biased number, not a median. Refuse to load rather than report
  # it.
  rem(@passes, 2) == 1 ||
    raise "@passes must be odd; got #{@passes}. An even count makes " <>
            "median_pass/3 report the upper middle timing, not the median."

  @alphabet for c <- ?a..?z, do: <<c>>
  @scroll_steps Enum.to_list(1..@scroll_reps)
  @wordsize :erlang.system_info(:wordsize)

  def run do
    style = TextFormatting.new(foreground: :red)
    warmup(style)

    print_header()

    # Rows print as they are measured rather than in one block at the end, so
    # a superlinear regression that runs into the job's timeout still leaves
    # the completed rows in the log.
    rows = Enum.flat_map(@budgets, &measure(&1, style))

    verdict(rows)
  end

  # Load each target before the first measured pass.
  defp warmup(style) do
    blank = Buffer.new({20, 10})
    buffer = fill(blank, fill_fixture(20, 10, style))
    _ = Buffer.get_cell(buffer, 1, 1)
    _ = Buffer.scroll(buffer, 1)
    _ = :erts_debug.flat_size(buffer)
    _ = :erts_debug.size_shared(buffer)
    :ok
  end

  defp print_header do
    IO.puts("=== Raxol.Terminal.Buffer throughput + memory gate ===")

    IO.puts(
      "host: #{:erlang.system_info(:system_architecture)}, " <>
        "OTP #{:erlang.system_info(:otp_release)}, " <>
        "Elixir #{System.version()}, " <>
        "#{:erlang.system_info(:schedulers_online)} schedulers, " <>
        "MIX_ENV=#{Mix.env()}, commit #{commit()}"
    )

    IO.puts(
      "repro: MIX_ENV=#{Mix.env()} mix run --no-start bench/core/buffer_gate.exs"
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

  defp measure(budget, style) do
    %{size: {width, height}} = budget
    cells = width * height
    label = "#{width}x#{height}"

    {fill_ns, filled} = measure_fill(width, height, style)
    positive!(fill_ns, "#{label} fill")

    fill_row =
      emit(
        {label, "fill us/cell", fill_ns / 1000 / cells, budget.fill_us_per_cell}
      )

    read_rows = read_rows(budget, filled, width, height, label)

    scroll_ns =
      median_pass(
        @passes,
        fn -> scroll_sweep(filled, @scroll_steps) end,
        &verify_swept!(&1, filled, width, height)
      )

    positive!(scroll_ns, "#{label} scroll")

    scroll_row =
      emit(
        {label, "scroll us/op", scroll_ns / 1000 / @scroll_reps,
         budget.scroll_us_per_op}
      )

    # `flat_size/1` and `size_shared/1` walk the retained term, so collecting
    # cannot change what they return. This collect only drops the discarded
    # timed buffers from the process heap before walking a 250k-cell fixture,
    # keeping the gate's own footprint down; no row below depends on it or on
    # when it runs.
    :erlang.garbage_collect()
    flat_words = :erts_debug.flat_size(filled)

    flat_words >= cells * @flat_words_per_cell_floor ||
      abort(
        "#{label} flat_size is #{flat_words} words, below the " <>
          "#{cells * @flat_words_per_cell_floor}-word fixed floor of " <>
          "#{cells} cells at #{@flat_words_per_cell_floor} words each; " <>
          "that is not a filled buffer"
      )

    flat_row =
      emit(
        {label, "flat bytes/cell", flat_words * @wordsize / cells,
         budget.flat_bytes_per_cell}
      )

    [fill_row] ++
      read_rows ++
      [scroll_row, flat_row] ++
      heap_row(budget, filled, flat_words, label, cells)
  end

  defp measure_fill(width, height, style) do
    blank = Buffer.new({width, height})
    fixture = fill_fixture(width, height, style)
    verify = &verify_written!(&1, width, height)

    fill_ns =
      median_pass(@passes, fn -> fill(blank, fixture) end, verify)

    # The retained buffer is built outside the timer. Returning from this
    # function also drops the large fixture list before memory is measured.
    filled = fill(blank, fixture)
    verify.(filled)
    {fill_ns, filled}
  end

  defp read_rows(
         %{read_us_per_get_cell: budget},
         filled,
         width,
         height,
         label
       ) do
    # 37 and 53 are coprime to every width (80, 200) and height (24, 100)
    # read here, so the 256 samples walk both axes instead of collapsing onto
    # a handful of rows or columns.
    coordinates =
      for i <- 0..(@read_samples - 1) do
        {rem(i * 37, width), rem(i * 53, height)}
      end

    read_ns = median_pass(@passes, fn -> read_sweep(filled, coordinates) end)
    positive!(read_ns, "#{label} read")

    [
      emit({label, "read us/get_cell", read_ns / 1000 / @read_samples, budget})
    ]
  end

  defp read_rows(_budget, _filled, _width, _height, _label), do: []

  # The sharing-aware row is omitted at sizes where its budget is nil.
  defp heap_row(%{heap_bytes_per_cell: nil}, _filled, _flat, _label, _cells),
    do: []

  defp heap_row(budget, filled, flat_words, label, cells) do
    heap_words = :erts_debug.size_shared(filled)

    (heap_words >= cells * @heap_words_per_cell_floor and
       heap_words <= flat_words) ||
      abort(
        "#{label} size_shared is #{heap_words} words against flat_size " <>
          "#{flat_words} and a fixed floor of " <>
          "#{cells * @heap_words_per_cell_floor} " <>
          "(#{cells} x #{@heap_words_per_cell_floor}); either the buffer is " <>
          "not filled or one of the two functions does not mean what this " <>
          "gate assumes"
      )

    [
      emit(
        {label, "heap bytes/cell", heap_words * @wordsize / cells,
         budget.heap_bytes_per_cell}
      )
    ]
  end

  # Report the median of an odd pass count. Only durations are retained;
  # large buffer results are verified, discarded, and collected between
  # passes instead of accumulating in a list or surviving as a running
  # minimum.
  defp median_pass(passes, fun),
    do: median_pass(passes, fun, fn _result -> :ok end)

  defp median_pass(passes, fun, verify) do
    timings =
      Enum.map(1..passes, fn _ ->
        {ns, result} = :timer.tc(fun, :nanosecond)
        verify.(result)
        :erlang.garbage_collect()
        ns
      end)

    timings
    |> Enum.sort()
    |> Enum.at(div(passes, 2))
  end

  defp fill(buffer, fixture) do
    Enum.reduce(fixture, buffer, fn {x, y, cell}, acc ->
      Buffer.set_cell(acc, x, y, cell)
    end)
  end

  # Coordinates, characters, and cells are fixture data, not target work.
  # Distinct characters also keep whole-cell sharing from hiding per-cell
  # memory and let the write integrity check distinguish every sampled cell.
  defp fill_fixture(width, height, style) do
    for y <- 0..(height - 1),
        x <- 0..(width - 1) do
      {x, y, Cell.new(char_at(x, y), style)}
    end
  end

  defp char_at(x, y), do: Enum.at(@alphabet, rem(x + y, 26))

  defp read_sweep(buffer, coordinates) do
    Enum.each(coordinates, fn {x, y} ->
      Buffer.get_cell(buffer, x, y)
    end)
  end

  defp scroll_sweep(buffer, steps) do
    Enum.reduce(steps, buffer, fn _, acc -> Buffer.scroll(acc, 1) end)
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

    :ok
  end

  # Integrity check 1: scroll/2 rescues its own failures and returns the
  # buffer unchanged, which would read as a free operation -- and the gate
  # used to time a sweep of @scroll_reps scrolls while validating a single
  # separate scroll of the unscrolled buffer, so reps 2..@scroll_reps could
  # each be a rescued no-op and read FASTER than a working scroll.
  #
  # This runs on the buffer the timed sweep actually produced. "The cells
  # differ" alone is too weak -- a scroll that dropped a row, truncated one,
  # or blanked the whole grid also differs -- so assert the shape and the
  # cumulative movement: after @scroll_reps single-line scrolls, row 0 must
  # be the filled buffer's row @scroll_reps, which no subset of no-op reps
  # can produce.
  defp verify_swept!(swept, filled, width, height) do
    height > @scroll_reps ||
      abort(
        "#{width}x#{height} is not taller than @scroll_reps " <>
          "(#{@scroll_reps}); the row-#{@scroll_reps} identity below would " <>
          "compare against a blanked row and stop proving anything"
      )

    rows = swept.cells

    swept != filled ||
      abort(
        "the #{@scroll_reps}-scroll sweep returned the filled buffer " <>
          "unchanged; every rep was a rescued no-op and the timing is of " <>
          "nothing"
      )

    length(rows) == height ||
      abort(
        "the sweep returned #{length(rows)} rows for a #{width}x#{height} " <>
          "buffer; scroll/2 did not preserve height"
      )

    Enum.all?(rows, &(length(&1) == width)) ||
      abort(
        "the sweep returned rows of width " <>
          "#{inspect(rows |> Enum.map(&length/1) |> Enum.uniq())} for a " <>
          "#{width}-wide buffer"
      )

    Enum.at(rows, 0) == Enum.at(filled.cells, @scroll_reps) ||
      abort(
        "after #{@scroll_reps} scrolls row 0 is not the filled buffer's " <>
          "row #{@scroll_reps}; some of the reps did not move content"
      )

    Enum.at(rows, height - 1) != Enum.at(filled.cells, height - 1) ||
      abort("the sweep left the last row in place; it did not blank it")
  end

  # Integrity check 3, timing leg: a measurement that never ran costs 0 ns.
  defp positive!(ns, what) do
    ns > 0 || abort("#{what} measured #{ns} ns; nothing ran")
  end

  # Printed with the table so a CI log can be reconciled against the
  # provenance block.
  defp commit do
    case System.find_executable("git") do
      nil ->
        "unknown (git unavailable)"

      git ->
        case System.cmd(git, ["rev-parse", "--short", "HEAD"],
               stderr_to_stdout: true
             ) do
          {sha, 0} -> String.trim(sha)
          {_output, status} -> "unknown (git exit #{status})"
        end
    end
  end

  # Print a row the moment its measurement lands, then hand it to the caller
  # for the final verdict.
  defp emit(row) do
    print_row(row)
    row
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

        stop(1)
    end
  end

  defp abort(reason) do
    IO.puts(:stderr, "ABORT: #{reason}")
    IO.puts(:stderr, "The gate measured nothing it can vouch for; not a pass.")
    stop(2)
  end

  # `System.stop/1` initiates an orderly VM shutdown and returns immediately.
  # Keep the script process from returning into Mix while the code server is
  # stopping; init terminates this wait after standard IO has been flushed.
  defp stop(status) do
    System.stop(status)
    Process.sleep(:infinity)
  end
end

BufferGate.run()
