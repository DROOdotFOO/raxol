# Benchmarks

Performance measurements for Raxol's core operations.

## Quick start

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

## Latest results

Measured 2026-08-07 at `fce2465bb` on Apple M1, Elixir 1.20.2 / OTP 29.0.3,
with `mix run bench/suites/comparison/framework_comparison.exs` (full mode).
Every number below comes from that one run on that one machine.

### Core operations

| Operation                         | Time    | Throughput     |
| --------------------------------- | ------- | -------------- |
| Buffer create (80x24)             | 0.32 us | 3.2M ops/sec   |
| Buffer create (200x50)            | 0.72 us | 1.4M ops/sec   |
| Cell write (single)               | 1.4 us  | 718K ops/sec   |
| Cell write (80 cells, line)       | 113 us  | 8.8K ops/sec   |
| Full screen write (1920 cells)    | 2.6 ms  | 389 ops/sec    |
| Emulator ingest (plain text)      | 1.7 ms  | 592 ops/sec    |
| Emulator ingest (colored)         | 3.6 ms  | 275 ops/sec    |
| Emulator ingest (50 CSI seqs)     | 69.5 ms | 14 ops/sec     |
| Tree diff (no change)             | 0.10 us | 10.3M ops/sec  |
| Tree diff (1 node changed)        | 1.3 us  | 776K ops/sec   |
| Tree diff (100 nodes, 1 change)   | 32 us   | 31.3K ops/sec  |

The emulator ingest rows measure the whole terminal path: parsing plus state
application (buffer writes, cursor movement, style changes). The standalone
ANSI lexer (`mix raxol.bench parser`) handles a short plain string in under a
microsecond; the two paths differ by orders of magnitude, so any "ANSI parse"
number is meaningless without naming which path it measures.

### Frame budget

| Metric                            | Value   |
| --------------------------------- | ------- |
| Full frame (create + fill + diff) | 5.0 ms  |
| Budget used (of 16ms @ 60fps)     | 31%     |
| Headroom for app logic            | 11.0 ms |
| Memory per 80x24 buffer           | 2 KB    |

The memory figure is `erts_debug.size` on the buffer term; cells are stored
in a map populated on write, so an empty buffer is small and memory grows
with written cells, not dimensions.

### Cross-framework comparison

| Operation           | Raxol   | Ratatui (Rust) | Bubble Tea (Go) | Textual (Python) |
| ------------------- | ------- | -------------- | --------------- | ---------------- |
| Buffer create 80x24 | 0.32 us | ~0.5 us        | ~2 us           | ~50 us           |
| Cell write (single) | 1.4 us  | ~0.01 us       | ~0.1 us         | ~5 us            |
| Full screen write   | 2.6 ms  | ~20 us         | ~50 us          | ~2 ms            |
| Tree/view diff      | 32 us   | ~5 us          | N/A             | ~100 us          |

All values in microseconds unless noted. Lower is better.

**Raxol**: measured on this hardware. **Others**: published/estimated numbers
from different hardware, so the comparison is approximate at best; a
same-machine harness is the only honest upgrade. The previous ANSI parse row
is gone: published parser numbers for other frameworks measure lexers, while
our comparison suite measures full emulator ingest, and comparing the two
mislead more than it informed.

### Interpretation

Raxol's per-operation latency is higher than Rust/Go (expected for a managed
runtime), but:

- **Full frame at 5.0ms** leaves 69% of the 60fps budget for application logic
- **Tree diff at 32us** sits between Ratatui (~5us) and Textual (~100us)
- **718K cell writes/sec** is more than enough for any terminal UI
- **OTP benefits**: crash isolation, hot reload, and distribution come built
  in to the runtime

The BEAM is fast enough for 60fps terminal rendering while also providing
fault tolerance and distribution primitives that would require significant
additional infrastructure in compiled languages.

## Suites

| Suite      | Location                   | Focus                       |
| ---------- | -------------------------- | --------------------------- |
| Comparison | `bench/suites/comparison/` | Cross-framework performance |
| Parser     | `bench/suites/parser/`     | ANSI parsing, CSI sequences |
| Terminal   | `bench/suites/terminal/`   | Buffer, cursor, emulator    |
| Rendering  | `bench/suites/rendering/`  | UI rendering, tree diffing  |
| Core       | `bench/suites/core/`       | System-wide operations      |

## Running benchmarks

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

## Performance targets

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
