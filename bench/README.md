# Benchmark Suite

Benchmark scripts for Raxol. For measured numbers and how they are produced,
see [docs/bench/README.md](../docs/bench/README.md).

## Quick start

```bash
mix run bench/suites/parser/parser_benchmark.exs               # ANSI parser
mix run bench/suites/rendering/render_performance_simple.exs   # rendering
mix run bench/suites/core/performance_summary.exs              # system-wide
mix run bench/suites/comparison/framework_comparison.exs       # the README table
```

## Gates

Most scripts here are reports: they print numbers and exit 0. One is a gate.

```bash
MIX_ENV=test mix run --no-start bench/core/buffer_gate.exs
```

`core/buffer_gate.exs` measures target-only `Raxol.Terminal.Buffer`
fill/read/scroll throughput and per-cell memory against the budgets and
ubuntu-latest provenance declared at the top of the file. It stops with
status 1 on a breach and status 2 on an invalid measurement. The
`scoreboard` job in `.github/workflows/ci-unified.yml` runs it and the
`ci-status` aggregate job fails when that job fails. Read the gate's
sensitivity and budget-change rules before changing a number.

## Scoreboard

```bash
MIX_ENV=test mix raxol.scoreboard
MIX_ENV=test mix run --no-start bench/core/buffer_gate.exs --json buffer.json
MIX_ENV=test mix raxol.scoreboard --include buffer.json --output scoreboard.json
```

`mix raxol.scoreboard` counts deterministic work, not time: the ANSI frame
bytes the engine writes and the BEAM reductions spent per frame of the
playground table and flex-layout demos, driven in-process through the
rendering engine's own stage functions. A terminal with synchronized output
also receives a 16-byte wrapper per frame, not counted.
`test/raxol/scoreboard_test.exs` holds `Raxol.Scoreboard.frames/2` to the
bytes a real engine writes for the same keys, and before measuring, every
frame is replayed through `Raxol.Terminal.Emulator` and must reproduce its own
screen (character and style), so the byte count only falls by sending less
for the same screen. `table.keystroke.work_ratio` is a keystroke's work over
the first frame's: an incremental renderer sits far below 1, and the table
demo is at 0.98 today. Bytes and memory are exact. Reductions are not quite:
runs on one machine agree within a few hundredths of a percent, but two CI runs
of the same commit have differed by up to 0.2%, so reduction metrics count a
change only beyond 0.5%. `--include` merges the buffer gate's memory
rows. Metric ids, labels and which direction is better are in
`priv/scoreboard/metrics.json`; add a metric there before emitting it.

Each scenario frame's screen is also pinned: its fingerprint (every cell's
character and style) is in `priv/scoreboard/screens.refs`, and the scoreboard
refuses to measure a screen that differs. Replay proves the bytes draw the
screen; the pin proves it is the same screen as before, so the numbers cannot
improve because a demo draws less. When a playground demo the scoreboard uses
(`TableDemo`, `FlexLayoutDemo`) is meant to look different, run
`MIX_ENV=test mix raxol.scoreboard --bless` and commit `screens.refs` in the
same pull request, where the change and its effect on the numbers are reviewed
together.

CI uploads each run's record as the `scoreboard` artifact.
`.github/workflows/scoreboard.yml` comments on the open pull request whose head
is the tested commit, comparing against the nearest recorded ancestor of its
base commit on its base branch (and saying so when that is not the base commit
itself), and appends master's records to `scoreboard/records.jsonl` on the
`gh-pages` branch; releases list the change since the previous tag.

## Suites

| Directory | Contents |
| --- | --- |
| `suites/parser/` | `parser_benchmark.exs`, `ansi_profile.exs`, `parser_chain_profile.exs`, `sgr_comparison.exs` |
| `suites/terminal/` | `emulator_profiling.exs`, `lite_emulator_test.exs` |
| `suites/rendering/` | `render_performance_simple.exs` |
| `suites/core/` | `performance_summary.exs` |
| `suites/comparison/` | `framework_comparison.exs`, the source of the root README's frame-time table |
| `suites/enhanced/` | `performance_dashboard.exs` |
| `suites/performance/` | Reusable modules: animation, event handling, memory, rendering, reporting |
| `suites/visualization/` | Chart and visualization benchmarks |

Two standalone scripts sit directly in `suites/`:
`kitty_graphics_benchmark.exs` and `protocol_performance_benchmark.exs`, plus
`example_dsl_benchmark.exs` as a template for a new one.

## Other directories

| Directory | What it holds |
| --- | --- |
| `baselines/` | Baseline data for regression comparison |
| `snapshots/` | Performance snapshots |
| `results/` | Benchee run output (`.benchee`, JSON) |
| `output/` | HTML reports and their static assets |
| `scripts/` | Benchmark utilities |
| `core/` | `buffer_gate.exs`, the gate above, plus older per-area scripts |
| `features/`, `memory/`, `live_view/`, `liveview/` | Older per-area scripts kept for reference |
