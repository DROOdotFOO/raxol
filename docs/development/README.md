# Development Guide

## Setup

### Quick Start (Nix)
```bash
git clone https://github.com/DROOdotFOO/raxol.git
cd raxol
nix-shell
mix deps.get
mix setup
```

### Manual Setup
```bash
# Requirements: Elixir 1.19+, Erlang/OTP 27+
# Optional: Node.js 20+ and PostgreSQL 15+ (only needed for Phoenix/asset builds)
mix deps.get
mix compile
```

## Commands

### Testing
```bash
SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test

# Specific test
SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test test/file.exs

# Rerun failed tests
SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test --failed

# With coverage
mix test --cover
```

### Code Quality
```bash
mix format                    # Format code
mix credo                     # Style check
mix dialyzer                  # Type checking (PLT cached in priv/plts/)
mix docs                      # Generate docs
mix raxol.check               # Run all checks (format, compile, credo, dialyzer, test)
mix raxol.check --quick       # Skip dialyzer
```

### Development
```bash
mix raxol.playground   # Component playground (30 widget demos)
mix raxol.repl         # Interactive REPL with sandboxing
iex -S mix            # Interactive shell
```

## Dialyzer

PLT cached in `priv/plts/` for faster reruns.

### Commands
```bash
mix dialyzer.setup            # Build the PLT
mix dialyzer.check            # Run analysis against the PLT
mix dialyzer.clean            # Remove the PLT
mix dialyzer                  # Plain run (also works)
mix dialyzer --format short   # Compact output
```

You can also use the dev script:
```bash
./scripts/dev.sh dialyzer
./scripts/dev.sh check      # Runs dialyzer as part of quality checks
```

### PLT Caching

Two-tier system:

- **Core PLT** (`priv/plts/core.plt`): Erlang/OTP + stable dependencies
- **Local PLT** (`priv/plts/local.plt`): Project modules + volatile dependencies

This keeps rebuild times short while staying accurate.

### False Positives

Known false positives are filtered in `.dialyzer_ignore.exs`:

```elixir
~r/termbox2_nif.*has no local return/,
~r/Phoenix.*callback.*never called/,
~r/GenServer.*init.*no local return/
```

Dialyzer runs in CI with PLT caching enabled.

## Configuration

### Environment Variables
```elixir
# config/dev.exs
config :raxol,
  terminal: [
    width: 120,
    height: 40,
    scrollback: 10_000
  ],
  performance: [
    cache: true,
    profiling: true
  ]
```

### Test Environment
```elixir
# config/test.exs
config :raxol,
  terminal: [headless: true, mock_pty: true],
  performance: [assertions: true]
```

## Troubleshooting

**NIF Compilation Fails**
```bash
export TMPDIR=/tmp
SKIP_TERMBOX2_TESTS=true mix compile
```

**Module Not Found**
```bash
mix deps.clean --all
mix deps.get
mix compile --force
```

**Test Failures**
```bash
rm -rf _build/test
MIX_ENV=test mix compile
```

**Performance Issues**
```bash
mix raxol.perf                # Performance monitoring
mix raxol.flamegraph          # Generate flame graph
```

## Performance

### Profiling
```bash
mix raxol.perf analyze        # Analyze current performance
mix raxol.perf monitor        # Live monitoring
mix raxol.perf memory         # Memory analysis
mix raxol.perf report         # Generate report
mix raxol.flamegraph <module> # Generate flame graph SVG
```

### Benchmarking
```bash
mix raxol.bench               # Run benchmark suite
mix run bench/core/buffer_benchmark.exs  # Specific benchmark
```

### Optimization Tips
- Damage tracking is automatic
- Enable component caching
- Batch state updates
- Profile before optimizing

## Contributing

### Pre-commit Checks
```bash
mix raxol.check               # Run all quality checks before committing
```

### Code Standards
- Zero compilation warnings (`--warnings-as-errors` in CI)
- All `mix raxol.check` steps must pass
- Functional patterns

## Build & Release

### Precompilation
```bash
MIX_ENV=prod mix compile
```

### Release
```bash
MIX_ENV=prod mix release
```

