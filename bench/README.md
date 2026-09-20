# Benchmark Suite

Benchmark scripts for Raxol. For measured numbers and how they are produced,
see [docs/bench/README.md](../docs/bench/README.md).

## Quick start

```bash
mix run bench/suites/parser/parser_benchmark.exs               # ANSI parser
mix run bench/suites/terminal/buffer_benchmark.exs             # screen buffer
mix run bench/suites/rendering/render_performance_simple.exs   # rendering
mix run bench/suites/validation/validate_optimizations.exs     # validation
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
`buffer-gate` job in `.github/workflows/ci-unified.yml` runs it and the
`ci-status` aggregate job fails when that job fails. Read the gate's
sensitivity and budget-change rules before changing a number.

## Suites

| Directory | Contents |
| --- | --- |
| `suites/parser/` | `parser_benchmark.exs`, `ansi_profile.exs`, `parser_chain_profile.exs`, `sgr_comparison.exs` |
| `suites/terminal/` | `buffer_benchmark.exs`, `cursor_benchmark.exs`, `emulator_profiling.exs`, `lite_emulator_test.exs` |
| `suites/rendering/` | `render_performance_simple.exs` |
| `suites/core/` | `performance_summary.exs`, `performance_improvements_benchmark.exs` |
| `suites/validation/` | `validate_optimizations.exs`, `verify_optimization.exs` |
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
