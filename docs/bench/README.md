# Benchmarks

Performance measurements for Raxol's core operations.

## Quick Start

```bash
# Framework comparison (vs Ratatui, Bubble Tea, Textual)
mix run bench/suites/comparison/framework_comparison.exs

# Quick mode (~30s instead of ~2min)
mix run bench/suites/comparison/framework_comparison.exs -- --quick

# Internal benchmarks
mix raxol.bench                    # All benchmarks
mix raxol.bench parser             # Parser only
mix raxol.bench rendering          # Rendering only
mix raxol.bench --quick            # Shorter runs
```

## Latest Results

Measured on Apple M1 Pro, Elixir 1.19.0 / OTP 27.

### Core Operations

| Operation                       | Time    | Throughput    |
| ------------------------------- | ------- | ------------- |
| Buffer create (80x24)           | 25 us   | 40K ops/sec   |
| Cell write (single)             | 0.97 us | 1M ops/sec    |
| Cell write (80 cells, line)     | 79 us   | 12.7K ops/sec |
| Full screen write (1920 cells)  | 2.0 ms  | 496 ops/sec   |
| ANSI parse (plain text)         | 38 us   | 26K ops/sec   |
| ANSI parse (colored)            | 67 us   | 15K ops/sec   |
| ANSI parse (50 CSI sequences)   | 2.0 ms  | 510 ops/sec   |
| Tree diff (no change)           | 0.04 us | 27M ops/sec   |
| Tree diff (1 node changed)      | 0.34 us | 3M ops/sec    |
| Tree diff (100 nodes, 1 change) | 4.0 us  | 252K ops/sec  |

### Frame Budget

| Metric                            | Value   |
| --------------------------------- | ------- |
| Full frame (create + fill + diff) | 2.1 ms  |
| Budget used (of 16ms @ 60fps)     | 13%     |
| Headroom for app logic            | 13.9 ms |
| Memory per 80x24 buffer           | 216 KB  |

### Cross-Framework Comparison

| Operation           | Raxol   | Ratatui (Rust) | Bubble Tea (Go) | Textual (Python) |
| ------------------- | ------- | -------------- | --------------- | ---------------- |
| Buffer create 80x24 | 25 us   | ~0.5 us        | ~2 us           | ~50 us           |
| Cell write (single) | 0.97 us | ~0.01 us       | ~0.1 us         | ~5 us            |
| Full screen write   | 2.0 ms  | ~20 us         | ~50 us          | ~2 ms            |
| ANSI parse (simple) | 38 us   | ~0.3 us        | ~1 us           | ~10 us           |
| Tree/view diff      | 4.0 us  | ~5 us          | N/A             | ~100 us          |

All values in microseconds unless noted. Lower is better.

**Raxol**: measured on this hardware. **Others**: published/estimated benchmarks. Cross-framework numbers are approximate, from published benchmarks on different hardware. Direct comparison requires same-machine measurement.

### Interpretation

Raxol's per-operation latency is higher than Rust/Go (expected for a managed runtime), but:

- **Full frame at 2.1ms** leaves 87% of the 60fps budget for application logic
- **Tree diff at 4us** is competitive with Ratatui's immediate-mode approach and 25x faster than Textual
- **Million+ cell writes/sec** is more than enough for any terminal UI
- **OTP benefits**: crash isolation, hot reload, and distribution come built in to the runtime

The BEAM is fast enough for 60fps terminal rendering while also providing fault tolerance and distribution primitives that would require significant additional infrastructure in compiled languages.

## Suites

| Suite      | Location                   | Focus                       |
| ---------- | -------------------------- | --------------------------- |
| Comparison | `bench/suites/comparison/` | Cross-framework performance |
| Parser     | `bench/suites/parser/`     | ANSI parsing, CSI sequences |
| Terminal   | `bench/suites/terminal/`   | Buffer, cursor, emulator    |
| Rendering  | `bench/suites/rendering/`  | UI rendering, tree diffing  |
| Core       | `bench/suites/core/`       | System-wide operations      |

## Running Benchmarks

```bash
# Specific suite files
mix run bench/suites/parser/parser_benchmark.exs
mix run bench/suites/terminal/buffer_benchmark.exs
mix run bench/suites/rendering/render_performance_simple.exs

# Via mix task (uses Benchee, generates HTML reports)
mix raxol.bench parser --dashboard
mix raxol.bench --regression    # Check for regressions (5% threshold)
mix raxol.bench --compare       # Compare with previous run
```

## Performance Targets

| Operation             | Target         | Status         |
| --------------------- | -------------- | -------------- |
| Full frame render     | < 16ms (60fps) | 2.1ms (pass)   |
| Buffer operations     | < 1ms          | 0.97us (pass)  |
| Tree diff (100 nodes) | < 1ms          | 4us (pass)     |
| ANSI parse (simple)   | < 100us        | 38us (pass)    |
| Memory per buffer     | < 500 KB       | 216 KB (pass)  |

## Tips

- Close other apps for consistent results
- Use `--quick` for development, full runs for publishing
- Run 3+ times and take the median
- Compare on the same hardware/OS
