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
# MERGE ENFORCEMENT
#
# The `buffer-gate` job fails on either non-zero exit and `ci-status` reads that
# job's result. `CI Status` is a required status check on `master`
# (`strict: false`), so a breach blocks an ordinary merge. Branch protection
# has `enforce_admins` disabled, so an administrator can bypass the check.
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
# Throughput budgets have roughly 5x headroom over the ubuntu-latest evidence
# below. They are blow-up detectors, not a promise that a 2x regression will
# fail. The 500x500 read row was removed: `get_cell/3` rebuilds a
# `ScreenBuffer`, making that row allocation/GC noise rather than a plausible
# guard on a lookup regression.
#
# The row-rebuild canary is concrete. Replacing the single pair of
# `List.update_at/3` calls in `set_cell/4` with ten identical pairs makes the
# timed operation perform ten target-row rebuilds per write. The 200x100 fill
# budget is five times the observed single-rebuild cost (1.52 -> 7.60
# us/cell), so N=10 breaches that row by construction. Fixture work cannot
# dilute the canary because it is outside the timer.
#
# Memory has two meanings:
#
#   flat bytes/cell  `:erts_debug.flat_size/1`, with sharing expanded
#   heap bytes/cell  `:erts_debug.size_shared/1`, with sharing counted once
#
# Both are pure functions of the retained filled buffer. No elapsed-time
# assertion is involved. The heap row is omitted at 500x500 because the two
# smaller sizes already cover per-cell sharing. Before sizing, dead timed
# results are garbage-collected; only the retained fixture is measured.
#
# The 460 and 244 B/cell ceilings are independent limits, not formulas derived
# from the current result. They catch, respectively, an added `%Cell{}` field
# (456.29 -> 472.29) and loss of sharing in its attributes (240.25 -> 352.25).
# Do not ratchet either ceiling mechanically when an implementation changes.
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
# measured_at      2026-09-15T19:49:36Z
# measured_at_sha  2f5516477
# workflow_run     35015431487
# workflow_job     104539040437
# runner           ubuntu-latest (Ubuntu 24.04.5, x86_64, 4 schedulers)
# runtime          OTP 29.0.3, Elixir 1.20.2, MIX_ENV=test
# command          MIX_ENV=test mix run --no-start bench/core/buffer_gate.exs
#
# The run log is the review evidence. Each throughput ceiling is five times
# the observed value, rounded up to one decimal:
#
#   size      metric             observed   budget   headroom
#   80x24     fill us/cell           0.81      4.1      5.06x
#   80x24     read us/get_cell       0.79      4.0      5.06x
#   80x24     scroll us/op           1.23      6.2      5.04x
#   200x100   fill us/cell           1.52      7.6      5.00x
#   200x100   read us/get_cell       1.64      8.2      5.00x
#   200x100   scroll us/op           3.25     16.3      5.02x
#   500x500   fill us/cell           4.13     20.7      5.01x
#   500x500   scroll us/op          11.40     57.0      5.00x
#
# Memory was 456.29/456.09/456.03 flat B/cell and 240.25/240.08 heap
# B/cell. Those budgets preserve the independent field-growth and
# sharing-loss limits above rather than applying the timing multiplier.
#
# The provenance run predates moving fixture construction out of the timed
# region. Its throughput observations therefore include strictly more work
# than the rows now measure, making the ceilings conservative. Replace this
# provenance only with retained ubuntu-latest log evidence from the current
# harness; never rebaseline by copying one green run into both observation
# and budget.
#
# BUDGET CHANGES
#
# 2026-09-14  initial gate for issue #1034
# 2026-09-15  added sharing-aware memory rows and integrity checks
# 2026-09-16  replaced M1 stand-ins with run 35015431487; set timing ceilings
#             to ~5x that ubuntu-latest evidence; removed the inert 500x500
#             read row; kept memory ceilings independent
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

  @alphabet for c <- ?a..?z, do: <<c>>
  @scroll_steps Enum.to_list(1..@scroll_reps)
  @wordsize :erlang.system_info(:wordsize)

  def run do
    style = TextFormatting.new(foreground: :red)
    warmup(style)

    print_header()

    rows = Enum.flat_map(@budgets, &measure(&1, style))

    Enum.each(rows, &print_row/1)
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

    read_rows = read_rows(budget, filled, width, height, label)

    scroll_ns =
      median_pass(
        @passes,
        fn -> scroll_sweep(filled, @scroll_steps) end,
        &verify_swept!(&1, filled, width, height)
      )

    positive!(scroll_ns, "#{label} scroll")

    # Timed fill and scroll results have been discarded. Collect them before
    # walking the retained fixture so large rows do not carry dead buffers
    # into the memory measurement.
    :erlang.garbage_collect()
    flat_words = :erts_debug.flat_size(filled)

    flat_words >= cells * @flat_words_per_cell_floor ||
      abort(
        "#{label} flat_size is #{flat_words} words, below the " <>
          "#{cells * @flat_words_per_cell_floor}-word fixed floor of " <>
          "#{cells} cells at #{@flat_words_per_cell_floor} words each; " <>
          "that is not a filled buffer"
      )

    [
      {label, "fill us/cell", fill_ns / 1000 / cells, budget.fill_us_per_cell}
    ] ++
      read_rows ++
      [
        {label, "scroll us/op", scroll_ns / 1000 / @scroll_reps,
         budget.scroll_us_per_op},
        {label, "flat bytes/cell", flat_words * @wordsize / cells,
         budget.flat_bytes_per_cell}
      ] ++ heap_row(budget, filled, flat_words, label, cells)
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
    coordinates =
      for i <- 0..(@read_samples - 1) do
        {rem(i * 37, width), rem(i * 53, height)}
      end

    read_ns = median_pass(@passes, fn -> read_sweep(filled, coordinates) end)
    positive!(read_ns, "#{label} read")

    [
      {label, "read us/get_cell", read_ns / 1000 / @read_samples, budget}
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
      {label, "heap bytes/cell", heap_words * @wordsize / cells,
       budget.heap_bytes_per_cell}
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
