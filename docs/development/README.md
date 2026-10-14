# Development Guide

Also in this directory:

- [Naming Conventions](NAMING_CONVENTIONS.md): filename standards and the duplicate-filename checker
- [ASCII Standards](ASCII_STANDARDS.md): bracketed tags instead of emoji in output
- [Debug Mode](DEBUG_MODE.md): `Raxol.Debug` verbosity levels and structured logging
- [Type Spec Generator](TYPE_SPEC_GENERATOR.md): `mix raxol.gen.specs`
- [Release Checklist](RELEASE_CHECKLIST.md): publish order, the gates that must be green first, and the per-package manual checks

## Setup

### Quick start (Nix)
```bash
git clone https://github.com/DROOdotFOO/raxol.git
cd raxol
nix develop
mix deps.get
mix setup
```

### Manual setup
```bash
# Requirements: Elixir 1.17+, Erlang/OTP 27+
# Reference toolchain: mise.toml (mise install)
# Optional: Node.js 20+ and PostgreSQL 15+ (only needed for Phoenix/asset builds)
mix deps.get
mix compile
```

### Pre-commit hooks

`mix setup` points `core.hooksPath` at `.githooks`. Two gates run, each only
when the files it guards are staged: `mix.lock` consistency, and the Markdown
prose rules.

The prose gate runs `elixir scripts/prose_lint.exs`, deliberately not `mix`.
The rules are the same `Raxol.Docs.ProseLint` module either way, but that route
loads no project, so a docs commit is not blocked by states that say nothing
about prose:

* `deps/` not matching the branch's `mix.lock`, which is routine when branches
  carry different locks, since one checkout shares one `deps/`
* a `_build` compiled by a different Elixir than the one on `PATH`
* a root `mix.lock` that no longer re-resolves

CI still runs `mix raxol.check_docs`, which additionally checks catalog counts.

If a gate reports something like `function Enum.__in__/2 is undefined`, the
`mix` on `PATH` and the one `MIX_HOME` points at are different installs, and a
Hex archive built for one is being loaded by the other. The hook prepends the
toolchain `mise.toml` names when it finds it installed under mise; for a
manual command, put that toolchain's `bin` first on `PATH`.

Set `RAXOL_HOOK_NO_TOOLCHAIN=1` to skip that and use `PATH` as-is, which is what
you want when deliberately committing against a different Elixir.

The hook is not a defence against a branch you do not trust. It runs
`scripts/prose_lint.exs`, and the lockfile gate evaluates `mix.exs`, so a
checked-out branch already chooses code that runs on `git commit`. That is true
of any repo with hooks enabled. Review the branch, or use `--no-verify`.

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

### Code quality
```bash
mix format                    # Format code
mix credo                     # Style check
mix dialyzer                  # Type checking (PLT cached in priv/plts/)
mix docs                      # Generate docs
mix raxol.check               # Run all checks (compile, format, credo, dialyzer, security, docs, rate, test)
mix raxol.check --quick       # Skip dialyzer
```

Run `mix raxol.check` before you push. It mirrors the checks CI enforces, including the
RATE golden render gate (`mix raxol.rate`). When you change rendering on purpose,
regenerate the references with `mix raxol.rate --gen` and commit them.

### Development
```bash
mix raxol.playground   # Component playground (42 demos)
mix raxol.repl         # Interactive REPL with an AST safety check
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

### PLT caching

Two-tier system:

- **Core PLT** (`priv/plts/core.plt`): Erlang/OTP + stable dependencies
- **Local PLT** (`priv/plts/local.plt`): Project modules + volatile dependencies

This keeps rebuild times short while staying accurate.

### False positives

Known false positives are filtered in `.dialyzer_ignore.exs`:

```elixir
~r/termbox2_nif.*has no local return/,
~r/Phoenix.*callback.*never called/,
~r/GenServer.*init.*no local return/
```

Dialyzer runs in CI with PLT caching enabled.

## Configuration

### Environment variables
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

### Test environment
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

### Optimization tips
- Damage tracking is automatic
- Enable component caching
- Batch state updates
- Profile before optimizing

## Contributing

### Pre-commit checks
```bash
mix raxol.check               # Run all quality checks before committing
```

### Code standards
- Zero compilation warnings (`--warnings-as-errors` in CI)
- All `mix raxol.check` steps must pass
- Functional patterns
- OTP process communication: `GenServer.call/3` for requests that expect a reply, `GenServer.cast/2` for fire-and-forget; when in doubt, use `call` over `cast`, to ensure back-pressure

### Guard at the resource

Authorization and input validation sit on the function that performs the side
effect, not on the routing clause that reaches it; a dispatch-level check is UX
only. The `%{jail: true}` gate is the worked example: `/login` refusing at
`apply_command/3` still left `Commands.connect/4` writing the host-global
credential store from the onboarding wizard, so the refusal moved into
`connect/4` and `Wizard.save_key_to_op/1` (#1011). Same shape elsewhere: the
mode allow-list belongs with the handlers that apply a mode, and a startup
barrier cannot trust the lane to report its own readiness.

### Package boundaries

The dependency graph between `packages/*` is in [PACKAGES.md](../PACKAGES.md);
main `raxol` does not depend on `raxol_agent`, `raxol_earn`, `raxol_gateway`,
or `raxol_agent_client_protocol`. Cross-package references use
`@compile {:no_warn_undefined, Module}` and `Code.ensure_loaded?/1` guards.
Struct patterns across package boundaries use map patterns (`%{field: x}`)
instead of struct patterns (`%Struct{field: x}`).

Each package formats at its own line length (98, not the root's 80). The root
`.formatter.exs` delegates every `packages/*` path to that package's config via
`:subdirectories`, so `mix format` from the repo root is correct for any file
and matches what CI checks.

### Test rules

Tags, auto-excluded by environment:

- `@tag :docker` - requires termbox2/Docker (excluded when `SKIP_TERMBOX2_TESTS=true`)
- `@tag :skip_on_ci` - excluded when `SKIP_TERMBOX2_TESTS=true`
- `@tag :unix_only` - excluded on Windows
- `@tag :slow` / `@tag :integration` - long-running

Timing:

- Never assert on measured elapsed time. A ceiling set close to the real cost
  flakes on a loaded runner; one set far above it proves nothing.
- Prove causality instead: by message (`assert_receive`, a monitor `:DOWN`), by
  ordering (timestamps written from each participant), or by the returned value
  when only one branch can produce it.
- Keep a lower bound only where the code guarantees it (`Process.sleep(50)`
  then `assert elapsed >= 50`).
- When the failure mode is a hang or a superlinear blow-up, the budget is the
  test's own `@tag timeout:` (or `@describetag`), set an order of magnitude
  above the observed cost. ExUnit reports it as a failure with a stack, and
  nothing has to be measured.
- Throughput and allocation budgets live in `bench/` and the regression-testing
  workflow, never in the suite. `bench/core/buffer_gate.exs` is the worked
  example: budgets with a stated headroom factor and a provenance block, a
  non-zero exit, and a CI job that fails on a breach.

## Build & Release

### Precompilation
```bash
MIX_ENV=prod mix compile
```

### Release
```bash
MIX_ENV=prod mix release
```
