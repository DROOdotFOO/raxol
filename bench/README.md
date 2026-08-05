# Benchmark Suite

Benchmarking files for Raxol.

## Directory structure

```
bench/
├── README.md           # This file
├── suites/             # Organized benchmark suites
│   ├── parser/         # ANSI parser and sequence benchmarks
│   ├── terminal/       # Buffer, cursor, and emulator benchmarks
│   ├── rendering/      # UI rendering performance benchmarks
│   ├── core/           # System-wide performance benchmarks
│   └── validation/     # Optimization validation benchmarks
├── archived/           # Historical and deprecated benchmarks
├── baselines/          # Baseline benchmark data for comparison
├── output/             # HTML reports and visualization outputs
│   └── assets/         # Static assets for HTML reports
├── results/            # Benchmark run results
│   ├── Test Suite/     # Benchee result files (.benchee, _summary.json)
│   └── visualization/  # Visualization benchmark results
├── scripts/            # Benchmark utilities and scripts
└── snapshots/          # Performance snapshots for regression testing
```

## Quick start

```bash
# Run parser benchmarks
mix run bench/suites/parser/parser_benchmark.exs

# Run terminal benchmarks
mix run bench/suites/terminal/buffer_benchmark.exs

# Run rendering benchmarks
mix run bench/suites/rendering/render_performance_simple.exs

# Run validation benchmarks
mix run bench/suites/validation/validate_optimizations.exs

# Run system-wide benchmarks
mix run bench/suites/core/performance_summary.exs
```

## Benchmark Suites

### Parser Suite (`suites/parser/`)
- `parser_benchmark.exs`: ANSI parser performance
- `ansi_profile.exs`: ANSI sequence processing
- `parser_chain_profile.exs`: Parser state chain
- `sgr_comparison.exs`: SGR sequence benchmarks

### Terminal Suite (`suites/terminal/`)
- `buffer_benchmark.exs`: Screen buffer performance
- `cursor_benchmark.exs`: Cursor movement benchmarks
- `emulator_profiling.exs`: Terminal emulator profiling
- `lite_emulator_test.exs`: Lightweight emulator tests

### Rendering Suite (`suites/rendering/`)
- `render_performance_simple.exs`: Basic rendering benchmarks
- `render_pipeline_profiling.exs`: Advanced rendering analysis

### Core Suite (`suites/core/`)
- `performance_summary.exs`: System-wide overview
- `performance_improvements_benchmark.exs`: Optimization tests

### Validation Suite (`suites/validation/`)
- `validate_optimizations.exs`: Optimization validation
- `verify_optimization.exs`: Performance verification

## Documentation

See [docs/bench/README.md](../docs/bench/README.md) for comprehensive documentation.

## Output Files

- HTML reports: `output/` directory
- Results: `results/` directory (.benchee, JSON files)
- Baselines: `baselines/` directory

## Best practices

1. Run benchmarks before performance changes
2. Use descriptive timestamped names
3. Update baselines after improvements
4. Document regressions in PRs