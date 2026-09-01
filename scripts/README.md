# Scripts

Utility scripts for the Raxol project, grouped by function. Anything a
contributor runs routinely is either `dev.sh` or a top-level gate; the
subdirectories hold narrower tooling.

## Main entry point

`dev.sh` wraps the common tasks:

```bash
./dev.sh test [pattern]   # run tests, optionally filtered
./dev.sh test-all         # comprehensive suite
./dev.sh format           # format code
./dev.sh check            # quality checks
./dev.sh dialyzer         # static analysis with PLT caching
./dev.sh setup            # environment setup
./dev.sh db [action]      # database operations
./dev.sh release          # create a release
./dev.sh clean            # clean build artifacts
```

## Top-level gates and tools

| Script | What it does |
| --- | --- |
| `prose_lint.exs` | Markdown prose rules and relative-link resolution. The pre-commit hook and `mix raxol.check_docs` both run it |
| `check_toolchain.sh` | Verifies the active Elixir/OTP matches `mise.toml` |
| `check_singletons.sh` | Diffs `name: __MODULE__` registrations against `.singletons-allowlist` |
| `check_duplicate_filenames.exs` | Reports duplicate basenames under `lib/` and `test/` |
| `check_package_formatting.sh` | Runs each package's own `mix format` gate |
| `check-lockstep-deps.sh` | Catches sibling-package version drift |
| `check_formatter_loaders.exs` | Verifies `.formatter.exs` subdirectory delegation |
| `check_journal_goldens.exs` | Harness journal golden check |
| `check_domains.sh` | Domain and DNS checks |
| `install.sh` | The `curl \| bash` installer served from raxol.io |
| `gen_homebrew_formula.sh` | Emits the Homebrew tap formula |
| `run_live_gates.sh` | The stablecoin cross-chain go-live matrix |
| `smoke-test.sh` | Post-deploy smoke test |
| `acp_probe.py` | Drives an ACP agent over stdio and records the wire |
| `analyze_performance_regression.exs`, `analyze_memory_regression.exs` | Regression analysis over benchmark output |
| `find_missing_moduledocs.exs` | Lists modules without a `@moduledoc` |
| `gen_landing_frames.exs`, `social_preview.exs` | Web asset generation |
| `deploy-raxol-solver.sh` | Solver deployment |

## Directories

| Directory | Contents |
| --- | --- |
| `ci/` | Build/test automation, structure validation, workflow migration |
| `dev/` | Release management, native-terminal runner, Nix verification, one-off refactor helpers |
| `testing/` | Test runner, coverage, platform tests, terminal verification |
| `quality/` | Style, docs, type-safety, accessibility, and performance checks |
| `db/` | Database setup and diagnostics |
| `docs/` | API doc generation, link validation, docs search |
| `visualization/` | Demo video generation and visualization benchmarks |
| `harness/` | The T0 terminal-matrix measurement harness (see `docs/proposals/t0-runbook.md`) |
| `deploy/` | Deployment build scripts |
| `bin/` | Demo and showcase runners |

## Adding a script

1. Put it in the directory that matches its function, or at the top level if
   it is a gate the whole repo runs.
2. Add a row above.
3. If it is commonly used, wire it into `dev.sh`.
4. Use snake_case, and put a documentation header in the script itself.
