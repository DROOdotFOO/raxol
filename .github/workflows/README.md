# GitHub Actions Workflows

This directory contains GitHub Actions workflows for CI, testing, and releases.

## Workflow Files

### Core Workflows
- **`ci-unified.yml`**: Main CI pipeline with parallelized testing, smart caching, and conditional execution
- **`security.yml`**: Comprehensive security scanning (dependencies, secrets, SAST)
- **`nightly.yml`**: Nightly regression testing with full test matrix
- **`regression-testing.yml`**: Unified performance and memory regression testing
- **`release.yml`**: Automated release creation and publishing

### Supporting Workflows
- **`performance-tracking.yml`**: Performance benchmarking and tracking
- **`pr-comment.yml`**: Automated PR feedback and status updates
- **`deploy-web.yml`**: Web application deployment

### Legacy/Testing workflows
- **`ci.yml`**: Original CI workflow (deprecated in favor of main CI pipeline)
- **`ci-local.yml`**: Simplified CI for local `act` testing
- **`ci-local-deps.yml`**: Tests dependencies locally
- **`test-snyk.yml`**: Security testing with Snyk
- **`dummy-test.yml`**: Quick workflow for verifying `act` setup
- **`macos-ci-fix.yml`**: macOS-specific CI fixes

### Removed/Consolidated Components
**Workflows consolidated into `regression-testing.yml`:**
- **`performance-regression.yml`**: *(Removed)* - Performance regression testing
- **`memory-regression.yml`**: *(Removed)* - Memory regression testing

**Actions removed due to duplication:**
- **`setup-beam/`**: *(Removed)* - Mock setup action, replaced by standardized `setup-elixir/`
- **`cache/`**: *(Removed)* - Mock cache action, workflows use standard GitHub cache action

**Workflow role clarifications:**
- **`nightly.yml`**: Now focuses on comprehensive test matrix and extended scenarios
- **`performance-tracking.yml`**: Handles historical performance tracking and dashboards (runs every 3 days at 4 AM UTC for efficiency)
- **`regression-testing.yml`**: Handles performance/memory regression detection for PRs and baseline updates

## Local Testing with `act`

Use [act](https://github.com/nektos/act) to run workflows locally for debugging.

### Setup

1. **Install act**: `brew install act` (or other methods).
2. **Docker/Orbstack**: Ensure Docker or Orbstack is running (Orbstack recommended on macOS ARM).
3. **Configuration**: Review `.actrc` in project root. Custom Docker images in `/docker` may be used.

### Running Workflows Locally (`run-local-actions.sh`)

Use the helper script `./scripts/dev/run-local-actions.sh`:

```bash
# Run the default CI workflow (ci.yml)
./scripts/dev/run-local-actions.sh

# Run a specific workflow (-w) and job (-j)
./scripts/dev/run-local-actions.sh -w cross_platform_tests.yml -j test_linux

# Enable verbose debugging (-d)
./scripts/dev/run-local-actions.sh -d

# List available workflows and options (-h)
./scripts/dev/run-local-actions.sh -h

# Run the dummy test to quickly verify setup
./scripts/dev/run-local-actions.sh -w dummy-test.yml
```

The `dummy-test.yml` workflow uses mock setups for quick verification without running the full suite. It's useful for:

- Troubleshooting `act` or workflow configuration.
- Verifying local setup.
- Testing new workflow steps quickly.

## Reusable actions

The `.github/actions/` directory contains reusable composite actions:

- **`setup-elixir`**: Sets up Elixir/OTP with caching
- **`run-tests`**: Runs tests with coverage and artifact upload

## CI/CD architecture

### Main CI Pipeline (`ci-unified.yml`)
- **Parallel test execution**: Tests split into unit, integration, and property tests
- **Smart caching**: Cache strategy with dependency detection
- **Conditional execution**: Heavy checks only run when needed
- **Fast feedback**: Format and compile checks run first

### Regression testing (`regression-testing.yml`)
- **Combined testing**: Performance and memory regression testing in a single workflow
- **Flexible execution**: Can run performance, memory, or both test types
- **Comprehensive analysis**: Automated regression detection and reporting
- **Baseline comparison**: Compares current changes against master branch
- **Performance gates**: Enforces memory and performance thresholds

### Security Scanning (`security.yml`)
- **No Docker dependencies**: Uses CLI tools directly
- **Multiple scanners**: Semgrep, Sobelow, TruffleHog, Gitleaks
- **Automated reporting**: Creates issues for critical findings

### Nightly Builds (`nightly.yml`)
- **Full test matrix**: Multiple Elixir/OTP versions
- **Performance benchmarking**: Track performance over time
- **Extended integration tests**: Include slow/heavy tests

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
