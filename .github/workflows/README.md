# GitHub Actions Workflows

This directory contains GitHub Actions workflows for CI, testing, and releases.

## Workflow Files

### Core Workflows
- **`ci-unified.yml`**: Main CI pipeline; `CI Status` aggregates the blocking jobs and is the required check
- **`platform-tests.yml`**: macOS and Windows suites, reusable; called by `ci-unified.yml` on platform-sensitive changes and by `nightly.yml`
- **`scoreboard.yml`**: `workflow_run` after `ci-unified.yml`; comments a pull request's scoreboard against master's and publishes master's records to `gh-pages`. Never runs pull request code
- **`security.yml`**: Dependency audit, Hex advisories, Sobelow, Semgrep, secret detection
- **`nightly.yml`**: Elixir/OTP × OS test matrix, Windows, extended property run, Dialyzer ratchet; keeps one `nightly-build` issue open while red
- **`lockstep-deps.yml`**: Cross-package dependency constraint and prose/link checks
- **`web-deploy-check.yml`**: Web tests and release boot, on `web/**` and playground changes
- **`nix.yml`**: Flake build on Linux and macOS

### Release Workflows
- **`release.yml`**: Tag-authorized Hex train plus GitHub release for `v*` tags; the release notes get the scoreboard change since the previous `v*` tag
- **`release-hex.yml`**: Reusable, approval-gated, dependency-ordered Hex publication
- **`release-raxol-cli.yml`**: Native CLI builds, approval-gated npm
  publication with provenance, and CLI GitHub releases
- **`release-raxol-console.yml`**, **`release-raxol-earn.yml`**: Per-binary release builds
- **`llms-sync.yml`**: Syncs `llms.txt` after a Hex publish

### Manual
- **`rate-selfhosted.yml`**: termbox2 NIF, tty-dependent, and RATE golden suites on the self-hosted runner
- **`scoreboard-backfill.yml`**: Measures master commits from before the scoreboard (from #1133, the first that draws today's pinned screens) with today's scoreboard and adds their records to `gh-pages` (`scripts/scoreboard-backfill.sh`)

The only performance check that fails CI is the buffer gate, run by the
`scoreboard` job in `ci-unified.yml` (`bench/core/buffer_gate.exs`). The same
job records the scoreboard (`mix raxol.scoreboard`), which `scoreboard.yml`
turns into a pull-request comment and a master time series on `gh-pages`.

## What runs when

`CI Status` (from `ci-unified.yml`) is the only required check; every other
workflow reports alongside it.

| Trigger | Runs | Reports to |
| --- | --- | --- |
| Pull request (any base) | `ci-unified.yml`: format, compile, unit, property and package tests, input canary, buffer gate, credo ratchet, security scan; integration tests when `mix.exs`, `mix.lock` or `lib/` change; macOS and Windows when the change is platform-sensitive. A docs-only change (`web/`, `docs/`, `assets/`, Markdown, `.github/` outside `workflows/`) skips all of it and `CI Status` passes | `CI Status` |
| Push to `master`, `main` or `develop` | `ci-unified.yml`, same jobs; macOS and Windows when the pushed range is platform-sensitive. Docs-only pushes do not start it | `CI Status` |
| Pull request or push to `master`/`main` | `security.yml` (not on docs-only changes); also daily at 03:00 UTC | Its own checks |
| Path-filtered | `lockstep-deps.yml` (`mix.exs`, `mix.lock`, Markdown, `docs/`), `web-deploy-check.yml` (`web/`, playground, root `mix.*`), `nix.yml` (`flake.*`) | Their own checks |
| 02:00 UTC daily | `nightly.yml`: test matrix, Windows, extended properties, Dialyzer ratchet, integration and slow tests | One `nightly-build` issue: commented while red, closed after a fully green night (scheduled runs only) |

"Platform-sensitive" is decided in the `changes` job of `ci-unified.yml`:
the change touches `mise.toml`, any `mix.exs` or `mix.lock`, the termbox2
NIF or `platform-tests.yml`, or changes an Elixir file whose content before
or after the change matches `PLATFORM_PATTERN` there (OS branches, `Platform.`
helpers, OS-scoped test tags). To force the legs on a change it misses, run
`platform-tests.yml` by hand (`workflow_dispatch`).

Credo runs on every `ci-unified.yml` run that does code work, and Dialyzer
only nightly; both compare against `priv/quality_baseline.json` through
`scripts/check-quality-ratchet.sh`.

## Local Testing with `act`

Use [act](https://github.com/nektos/act) to run workflows locally for debugging.

### Setup

1. **Install act**: `brew install act` (or other methods).
2. **Docker/Orbstack**: Ensure Docker or Orbstack is running (Orbstack recommended on macOS ARM).
3. **Configuration**: Review `.actrc` in project root. Custom Docker images in `/docker` may be used.

### Running Workflows Locally (`run-local-actions.sh`)

Use the helper script `./scripts/dev/run-local-actions.sh`:

```bash
# Run a specific workflow (-w) and job (-j)
./scripts/dev/run-local-actions.sh -w ci-unified.yml -j format

# Enable verbose debugging (-d)
./scripts/dev/run-local-actions.sh -d

# List available workflows and options (-h)
./scripts/dev/run-local-actions.sh -h
```

### Tips for macOS ARM (M1/M2/M3)

- Use Orbstack for better performance.
- Use custom Docker images (built via `./docker/build-docker-image.sh`) if needed for ARM64 compatibility.
- Check `.actrc` for architecture flags like `--container-architecture linux/arm64`.

### Custom Docker Images

Build custom images (e.g., `elixir-arm64`) if needed:

```bash
./docker/build-docker-image.sh
```

These images can provide specific Erlang/Elixir versions or pre-installed dependencies optimized for ARM64.

### Troubleshooting

- **GitHub Authentication**: If seeing `authentication required` errors, provide a token:
  - `export GITHUB_TOKEN=your_personal_access_token`
  - Or pass directly: `GITHUB_TOKEN=... ./scripts/dev/run-local-actions.sh ...`
  - Use `dummy-test.yml` if the workflow doesn't require GitHub access.
- **PostgreSQL Connection (macOS)**: Ensure PostgreSQL (e.g., `postgresql@14`) is running locally (`brew services start postgresql@14`). Port 5433 is often used in tests.
- **Docker/Orbstack**: Ensure the daemon is running (`docker ps`).
- **Permissions**: Make scripts executable (`chmod +x ./scripts/dev/run-local-actions.sh`).
- **Architecture**: Ensure correct architecture flags in `.actrc` if on ARM.

Refer to the official [act documentation](https://github.com/nektos/act) and [GitHub Actions documentation](https://docs.github.com/en/actions) for more details.
