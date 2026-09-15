# Buffer throughput + per-cell memory gate.
#
#   MIX_ENV=test mix run --no-start bench/core/buffer_gate.exs
#
# MIX_ENV matters: CI sets `MIX_ENV: test` workflow-wide, so the budgets below
# are measured in `test` and the command above is the one to reproduce them.
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
# `Raxol.Terminal.Buffer` with `Cell` structs and fails its CI job. That job
# is reported by `ci-status` but is not a required check, so it informs a
# review rather than mechanically blocking a merge.
#
# ---------------------------------------------------------------------------
# WHAT THESE BUDGETS CAN AND CANNOT DETECT
# ---------------------------------------------------------------------------
# The throughput budgets carry ~5x headroom over the SLOWEST value observed
# while setting them, because a shared CI runner is both slower and noisier
# than a developer box. Across the ten runs in the BUDGETS block below, the
# same code on one machine spread 8x (80x24 fill), 11x (200x100 read) and 7x
# (500x500 read), nearly all of it from CPU contention.
#
# State that plainly rather than dressing it up: these rows catch a large
# regression -- an accidental O(n) -> O(n^2), a per-write whole-grid rebuild,
# an `inspect/1` or a sleep in a hot path. They do NOT catch a 2x regression.
# Measured on the budgets below, rebuilding the target row an extra N times
# inside `set_cell/4` breaches:
#
#   N=10  200x100 fill only (36.27 vs 29.00, 1.25x)
#   N=30  all three fill rows (28.44/1.05x, 81.01/2.79x, 233.36/2.29x)
#
# A green run means "no blow-up", never "throughput did not change".
#
# The two memory rows are the sensitive ones, and there are two per size
# because one number cannot answer both questions:
#
#   `flat bytes/cell` is `:erts_debug.flat_size/1`: the term's shape with
#   sharing EXPANDED. It is the copy footprint -- what the buffer costs to
#   send across a process boundary -- and it is a pure function of shape, so
#   it returned 456.29 / 456.09 / 456.03 across the three sizes on all ten
#   runs, to the last decimal.
#
#   `heap bytes/cell` is `:erts_debug.size_shared/1`: the same term with
#   sharing COUNTED ONCE, i.e. the resident heap. Equally deterministic:
#   240.25 / 240.08 B/cell on all ten runs, 47% below the flat number,
#   because every cell's 13-key `attributes` map is a compile-time literal in
#   `Raxol.Terminal.Buffer.Cell.extract_attributes/1` and all 20000 of them
#   point at one shared keys tuple.
#
# Because both are exact, both are gated tight enough to catch ONE added
# struct field, which is the smallest regression either can see. Measured by
# adding one field to `%Cell{}`:
#
#   flat 456.29 -> 472.29 B/cell (+2 words: the field plus its slot in the
#        per-cell keys tuple, which flat_size expands per cell)
#   heap 240.25 -> 248.25 B/cell (+1 word: the keys tuple is shared, so only
#        the value slot is paid per cell)
#
# Both breach (1.03x and 1.02x of budget) at every size that declares them.
# The earlier 1.5x / 685.0 budget did not: it needed +229 B/cell, ~28 added
# fields, so the claim that it "catches a struct growing a field" was wrong
# by a factor of 28. A tight budget is only safe because these functions do
# not vary run to run; do not copy that tightness onto a timing row.
#
# The blind spot the heap row closes, measured rather than asserted: build
# that same attributes map at runtime instead (`Map.new(keys, ...)` -- an
# ordinary-looking refactor) and each cell allocates its own keys tuple.
# Resident heap goes 240.25 -> 352.25 B/cell at 80x24 (+112.00, 1.47x, and
# 1.44x of budget), while `flat bytes/cell` moves by 0.00 -- it stays 456.29
# to the last decimal, because sharing is exactly what `flat_size/1` cannot
# see. A gate with only the flat row would have passed that diff. Sharing
# changes in the other direction are equally invisible to it.
#
# `:erts_debug.size/1` is the function usually named for this and is NOT
# used: measured on this buffer it took 612 ms at 1920 cells and 49.5 s at
# 20000 cells, which is minutes of CI for one row. `size_shared/1` answers
# the same question -- 240.25 vs 240.72 B/cell at 80x24, 240.08 vs 240.13 at
# 200x100, a 0.2% gap from literal-pool handling -- in 0.14 ms and 8.8 ms.
# The heap row is nonetheless declared only at 80x24 and 200x100: those two
# sizes are where per-cell sharing is worth gating, and 250000 cells adds
# ~50 ms of walk for a number the smaller sizes already carry.
#
# Still outside what either row can see:
#   - Neither function counts refcounted binary PAYLOADS, only the 6-word
#     on-heap header. Cell chars here are 1-byte heap binaries, so this does
#     not bite today; a change that parked a >64-byte binary per cell would
#     be invisible to both rows.
#   - Process heap fragmentation and GC behaviour are not measured at all.
#
# ---------------------------------------------------------------------------
# MEASUREMENT INTEGRITY
# ---------------------------------------------------------------------------
# A gate that passes when it measured nothing is worse than no gate (the same
# rule `scripts/check-quality-ratchet.sh` documents at length). Four ways
# this particular gate could lie, and the check that stops each. A check that
# cannot fail is not advertised here, it is deleted -- the previous version
# also claimed to count its own rows before printing a verdict, which was
# tautological because `measure/2` has one return path, and that claim and
# its code are gone:
#
#   1. `Buffer.scroll/2` has a `rescue` clause that logs and returns the
#      buffer UNCHANGED, so a broken scroll is fast and reads as a large
#      improvement -- and the timed sweep is @scroll_reps scrolls, of which
#      any subset could be rescued no-ops. Checked on the buffer the timed
#      sweep actually produced, not on a separate throwaway scroll: it must
#      differ from the filled buffer, keep its height and row widths, blank
#      its last row, and its row 0 must be term-equal to the filled buffer's
#      row @scroll_reps -- which only a sweep where every rep moved content
#      can produce.
#   2. A `set_cell/4` that silently dropped writes would make `fill` fast.
#      Checked: cells are read back at four corners and the centre and must
#      carry the character the fill wrote.
#   3. A measurement that never ran leaves 0 ns / a too-small term behind,
#      which beats every budget. Checked: every duration must be > 0 ns, and
#      `flat_size` must clear one whole expanded `Cell` per cell -- a floor
#      measured at runtime, 55 words/cell here, which a blank `Buffer.new/1`
#      grid fails (46150 words against a 105600-word floor at 80x24). The
#      previous bound was one WORD per cell, which a blank grid clears 24x
#      over, so it could not fire.
#   4. A sharing-aware size can never exceed the flat size of the same term,
#      and can never fall below one unshared `%Cell{}` map per cell. Checked:
#      `size_shared/1` must land in [22 words/cell, flat_size]. The floor is
#      the bare struct measured at runtime; cells with different characters
#      cannot share a map body, while a blank grid shares one cell for the
#      whole screen and lands at 2.03 words/cell. The ceiling fails loudly if
#      a future OTP changes either function's meaning, rather than quietly
#      re-baselining the heap row.
#
# Each failure aborts with exit 2 and the word ABORT, never a PASS row.
#
# ---------------------------------------------------------------------------
# BUDGETS
# ---------------------------------------------------------------------------
# Provenance, because a budget without a machine and a date is a rumour.
# Stamped like `priv/quality_baseline.json`, with a `measured_at` and a
# `measured_at_sha`:
#
#   measured_at      2026-09-15T00:00:00Z
#   measured_at_sha  ef966e6c3
#   command          MIX_ENV=test mix run --no-start bench/core/buffer_gate.exs
#
#   id      machine
#   M1-8    Apple M1, 8 schedulers, OTP 29, Elixir 1.20.2, darwin/aarch64,
#           5 runs, load average 13.8-17.6 (a busy box, not an idle one)
#   M1-2    same box and commit, `ELIXIR_ERL_OPTIONS='+S 2:2'` plus 4
#           busy-loop spinners, 5 runs -- a 2-core runner with a noisy
#           neighbour
#
# There is deliberately NO ubuntu-latest column. The `buffer-gate` job runs
# on `ubuntu-latest`/x86_64 and CI cannot currently produce a number to put
# here: the repo-wide `Setup & Cache` job fails on `mix hex.audit` and
# `deps.get --check-locked`, which skips every downstream job (PR #1023 fixes
# it). M1-2 is the stand-in for a small, contended runner. The first green
# `buffer-gate` log is the number to reconcile against this table, which is
# why `print_header/0` prints the architecture, scheduler count, MIX_ENV and
# commit alongside the measurements.
#
# MIX_ENV: measured in `test`, because `ci-unified.yml` sets `MIX_ENV: test`
# workflow-wide. A local `mix run` without it measures `dev`, which is a
# different build.
#
#   size      metric             M1-8 min-max  M1-2 min-max   budget  x slow
#   80x24     fill us/cell         0.66-0.74     0.78-5.37      27.0    5.03
#   80x24     read us/get_cell     0.48-0.60     0.50-1.25       6.5    5.20
#   80x24     scroll us/op         0.46-0.48     0.47-1.05       5.5    5.24
#   80x24     flat bytes/cell         456.29        456.29     460.0    1.01
#   80x24     heap bytes/cell         240.25        240.25     244.0    1.02
#   200x100   fill us/cell         1.71-2.05     3.31-5.69      29.0    5.10
#   200x100   read us/get_cell     1.22-1.32    2.47-13.63      69.0    5.06
#   200x100   scroll us/op         1.18-1.27     1.21-2.34      12.0    5.13
#   200x100   flat bytes/cell         456.09        456.09     460.0    1.01
#   200x100   heap bytes/cell         240.08        240.08     244.0    1.02
#   500x500   fill us/cell         5.75-9.92    9.41-20.19     102.0    5.05
#   500x500   read us/get_cell   32.96-48.92   39.30-218.28   1100.0    5.04
#   500x500   scroll us/op        5.00-10.69    4.86-16.84      85.0    5.05
#   500x500   flat bytes/cell         456.03        456.03     460.0    1.01
#
# The headroom column is against the slowest of the ten runs, which for every
# throughput row is M1-2. Against the M1-8 median the same budgets are
# 10-55x, which is the number to ignore.
#
# The memory rows are identical across every run and both configurations, to
# the last decimal, because both functions are pure functions of the term.
# Their 1.01x / 1.02x is therefore not optimism: see the added-field
# measurement above.
#
# The read rows are the weakest of the metrics and should not be read as a
# tight bound on anything. `get_cell/3` converts the whole buffer to a
# `ScreenBuffer` per call, so its cost is dominated by allocation and GC
# state rather than by the lookup: 500x500 read measured 39.30 us on one
# contended run and 218.28 us on another. They exist to cover the deleted
# test's read case, not because they are sensitive.
#
# Runtime, once compiled: ~10 s wall on this box, ~8 s of it measurement,
# dominated by the 500x500 fill, because `set_cell/4` rebuilds a list prefix
# per write -- which is also why 250000 cells is the row that would notice
# that getting worse. 15-20 s under the contention above.
#
# ---------------------------------------------------------------------------
# CHANGING A BUDGET
# ---------------------------------------------------------------------------
# Not "take the printed measured column and keep the headroom" -- that is a
# rebaseline recipe with no record. A budget change is a diff to the log
# below, and the log is the review surface: `bench/core/buffer_gate.exs` is in
# `.github/CODEOWNERS`, so loosening a number here cannot land unreviewed.
#
# Every change to a number in the table above or to a sampling constant
# (`@passes`, `fill_passes`, `@read_samples`, `@scroll_reps`) adds a row:
#
#   date        row                     old     new   why
#   2026-09-14  (initial)                 -       -   issue #1034
#   2026-09-15  every throughput row      -       -   re-measured over 10
#                                                     runs; the shipped
#                                                     numbers disagreed with
#                                                     their own baseline
#                                                     probe (200x100 scroll
#                                                     was 14.0 against a
#                                                     25.15 observation) and
#                                                     would have false-failed
#   2026-09-15  80x24 fill us/cell     30.0    27.0   5x the slowest of 10
#   2026-09-15  80x24 read us/get_cell 18.0     6.5   same; the old number
#                                                     was 36x the slowest
#   2026-09-15  80x24 scroll us/op     18.0     5.5   same
#   2026-09-15  200x100 fill           58.0    29.0   same
#   2026-09-15  200x100 read           83.0    69.0   same
#   2026-09-15  200x100 scroll         51.0    12.0   same
#   2026-09-15  500x500 fill          285.0   102.0   same
#   2026-09-15  500x500 read          645.0  1100.0   WIDENED: a contended
#                                                     run measured 218.28,
#                                                     4.3x the old budget's
#                                                     own baseline, so 645.0
#                                                     was not 5x anything
#   2026-09-15  500x500 scroll        145.0    85.0   5x the slowest of 10
#   2026-09-15  flat bytes/cell       685.0   460.0   1.5x could not see an
#                                                     added struct field
#                                                     (+16 B/cell); 460.0
#                                                     does, and the metric
#                                                     does not vary
#   2026-09-15  heap bytes/cell       289.0   244.0   same (+8 B/cell)
#
# A row that only widens a budget and says "CI was slow" is a red flag, not a
# justification: say what got slower, or fix it. The 500x500 read row above
# says what: `get_cell/3` rebuilds a `ScreenBuffer` per call and is
# allocation-bound, so it is the one row contention can move by 7x.

defmodule BufferGate do
  @moduledoc false

  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Buffer
  alias Raxol.Terminal.Buffer.Cell

  # One entry per size. `fill_passes` scales with the SIZE rather than with
  # the metric: a 500x500 fill pass costs seconds, so that size settles for
  # two, and every other row everywhere gets the full @passes. The previous
  # arrangement gave 80x24 fill two passes -- the shortest, least-averaged
  # window in the gate -- for no reason except that it was a fill.
  #
  # `heap_bytes_per_cell: nil` omits the sharing-aware row for a size.
  @budgets [
    %{
      size: {80, 24},
      fill_passes: 5,
      fill_us_per_cell: 27.0,
      read_us_per_get_cell: 6.5,
      scroll_us_per_op: 5.5,
      flat_bytes_per_cell: 460.0,
      heap_bytes_per_cell: 244.0
    },
    %{
      size: {200, 100},
      fill_passes: 5,
      fill_us_per_cell: 29.0,
      read_us_per_get_cell: 69.0,
      scroll_us_per_op: 12.0,
      flat_bytes_per_cell: 460.0,
      heap_bytes_per_cell: 244.0
    },
    %{
      size: {500, 500},
      fill_passes: 2,
      fill_us_per_cell: 102.0,
      read_us_per_get_cell: 1100.0,
      scroll_us_per_op: 85.0,
      flat_bytes_per_cell: 460.0,
      heap_bytes_per_cell: nil
    }
  ]

  # get_cell/scroll are cheap in aggregate, so they are repeated and the
  # minimum taken; CPU contention can only ever make a pass slower.
  # Timings are taken in nanoseconds and divided down: a 10x IMPROVEMENT to
  # `scroll/2` takes the 80x24 sweep to under 1 us in total, which rounds to
  # 0 in `:timer.tc/1`'s microseconds and would abort the gate on a win.
  @read_samples 256
  @scroll_reps 20
  @passes 5

  @alphabet for c <- ?a..?z, do: <<c>>
  @wordsize :erlang.system_info(:wordsize)

  def run do
    style = TextFormatting.new(foreground: :red)
    warmup(style)

    print_header()

    rows = Enum.flat_map(@budgets, &measure(&1, style))

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
    %{size: {width, height}, fill_passes: fill_passes} = budget
    cells = width * height
    label = "#{width}x#{height}"

    {fill_ns, filled} =
      min_pass(fill_passes, fn ->
        fill(Buffer.new({width, height}), width, height, style)
      end)

    positive!(fill_ns, "#{label} fill")
    verify_written!(filled, width, height)

    {read_ns, _} =
      min_pass(@passes, fn -> read_sweep(filled, width, height) end)

    positive!(read_ns, "#{label} read")

    {scroll_ns, swept} = min_pass(@passes, fn -> scroll_sweep(filled) end)
    positive!(scroll_ns, "#{label} scroll")
    verify_swept!(swept, filled, width, height)

    flat_words = :erts_debug.flat_size(filled)

    # Integrity check 3, memory leg. The floor is one whole expanded `Cell`
    # per cell, measured at runtime rather than hardcoded: `flat_size/1`
    # expands sharing, so a grid of `cells` cells cannot weigh less than
    # `cells` cells. `> cells` (one word per cell) was the previous bound and
    # a blank `Buffer.new/1` grid clears it -- 24.0 words/cell, since its
    # cells are identical and cheap. This floor does not: 46150 words against
    # a 105600-word floor at 80x24.
    cell_floor = :erts_debug.flat_size(Cell.new("a", style))

    flat_words >= cells * cell_floor ||
      abort(
        "#{label} flat_size is #{flat_words} words, below the " <>
          "#{cells * cell_floor}-word floor of #{cells} cells at " <>
          "#{cell_floor} words each; that is not a filled buffer"
      )

    [
      {label, "fill us/cell", fill_ns / 1000 / cells, budget.fill_us_per_cell},
      {label, "read us/get_cell", read_ns / 1000 / @read_samples,
       budget.read_us_per_get_cell},
      {label, "scroll us/op", scroll_ns / 1000 / @scroll_reps,
       budget.scroll_us_per_op},
      {label, "flat bytes/cell", flat_words * @wordsize / cells,
       budget.flat_bytes_per_cell}
    ] ++ heap_row(budget, filled, flat_words, label, cells)
  end

  # The sharing-aware row. `size_shared/1` and not `size/1`: same answer, and
  # `size/1` costs 1.6 s at 1920 cells and 62 s at 20000 (see the header).
  defp heap_row(%{heap_bytes_per_cell: nil}, _filled, _flat, _label, _cells),
    do: []

  defp heap_row(budget, filled, flat_words, label, cells) do
    heap_words = :erts_debug.size_shared(filled)

    # Integrity check 4: a sharing-aware size lives in [one unshared %Cell{}
    # map per cell, flat_size]. The floor is the bare struct measured at
    # runtime (22 words here): cells carrying different characters cannot
    # share a map body, so a grid of distinct cells must pay it once per
    # cell. A blank grid pays it once in total -- 2.03 words/cell -- which is
    # why `heap_words > cells` was not a check.
    struct_floor = :erts_debug.flat_size(%Cell{})

    (heap_words >= cells * struct_floor and heap_words <= flat_words) ||
      abort(
        "#{label} size_shared is #{heap_words} words against flat_size " <>
          "#{flat_words} and a floor of #{cells * struct_floor} " <>
          "(#{cells} x #{struct_floor}); either the buffer is not filled or " <>
          "one of the two functions does not mean what this gate assumes"
      )

    [
      {label, "heap bytes/cell", heap_words * @wordsize / cells,
       budget.heap_bytes_per_cell}
    ]
  end

  # Minimum of `passes` timings, with that pass's result: CPU contention can
  # only make a measurement slower, so the minimum is the least noisy
  # estimator available without a statistics library.
  #
  # A fold and not `Enum.map |> Enum.min_by`: the mapped version holds every
  # pass's buffer live at once, and a scrolled 500x500 buffer is ~114 MB
  # flat. This keeps the running minimum and the pass being timed, never the
  # other three.
  defp min_pass(passes, fun) do
    Enum.reduce(1..passes, nil, fn _, best ->
      {ns, result} = :timer.tc(fun, :nanosecond)

      case best do
        {best_ns, _} when best_ns <= ns -> best
        _ -> {ns, result}
      end
    end)
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

  # Printed with the table so a CI log can be reconciled against the BUDGETS
  # provenance block, which records a machine, a MIX_ENV and a SHA.
  defp commit do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"],
           stderr_to_stdout: true
         ) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
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
