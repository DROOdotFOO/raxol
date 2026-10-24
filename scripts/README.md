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
| `check_refactor_move.exs` | Mechanical proof for move/split PRs: `defp -> def` widenings and normalized-body drift against a base ref |
| `check_journal_goldens.exs` | Harness journal golden check |
| `check_domains.sh` | Domain and DNS checks |
| `install.sh` | The `curl \| bash` installer served from raxol.io |
| `worktree.sh` | Adds a private 0700 parallel git worktree with transactionally cloned `deps`/`_build` caches. Workstation-only: seeding skips Hex verification, rejects symlinked seed paths, checks lock and path-dependency manifests, and `--fresh` opts out. An explicit path (relative ones resolve against your shell's cwd) is claimed with one `mkdir`, so its parent must already exist |
| `gen_homebrew_formula.sh` | Emits the Homebrew tap formula |
| `run_live_gates.sh` | The stablecoin cross-chain go-live matrix |
| `smoke-test.sh` | Post-deploy smoke test |
| `scoreboard-backfill.sh` | Measures older master commits with today's scoreboard (records for `gh-pages`), skipping any whose screens differ from the pinned ones; run by `scoreboard-backfill.yml` |
| `scoreboard-canaries.sh` | Applies each deliberate regression in `bench/scoreboard_canaries/`, measures, reverts, and fails unless the scoreboard flags every one; run by `scoreboard-canaries.yml` |
| `acp_probe.py` | Drives an ACP agent over stdio and records the wire |
| `find_missing_moduledocs.exs` | Lists modules without a `@moduledoc` |
| `gen_landing_frames.exs`, `social_preview.exs` | Web asset generation |
| `deploy-raxol-solver.sh` | Solver deployment |

## Directories

| Directory | Contents |
| --- | --- |
| `dev/` | Release management, native-terminal runner, Nix verification |
| `testing/` | Test runner, coverage, platform tests, terminal verification |
| `quality/` | Style, docs, type-safety, accessibility, and performance checks |
| `db/` | Database setup and diagnostics |
| `docs/` | API doc generation, link validation, docs search |
| `visualization/` | Demo video generation and visualization benchmarks |
| `harness/` | The T0 terminal-matrix measurement harness (see `docs/testing/T0_RUNBOOK.md`) |
| `deploy/` | Deployment build scripts |
| `bin/` | Demo and showcase runners |
| `omp_fixtures/` | `capture.exs`: records scrubbed OMP protocol transcripts (the `auth-gateway stdio` F1 set into `packages/raxol_agent/test/fixtures/omp/gateway/`, the `--mode rpc` F3 set into `packages/raxol_agent/test/fixtures/omp/rpc/`) from the pinned `omp`; `--with-model` makes model calls; `--rescrub` re-applies the current scrub to the committed transcripts without running `omp` |

## Adding a script

1. Put it in the directory that matches its function, or at the top level if
   it is a gate the whole repo runs.
2. Add a row above.
3. If it is commonly used, wire it into `dev.sh`.
4. Use snake_case, and put a documentation header in the script itself.
