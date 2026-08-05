# Scripts Directory Structure

This directory contains organized utility scripts for the Raxol project. Scripts are categorized by function for better maintainability and discoverability.

## Directory Organization

```
scripts/
├── ci/              # CI/CD related scripts
├── dev/             # Development utilities
├── testing/         # Test-related scripts
├── docs/            # Documentation generation
├── quality/         # Code quality and checks
├── db/              # Database utilities
├── visualization/   # Visualization and demo scripts
├── bin/             # Executable scripts
├── archived/        # Archived/deprecated scripts
└── dev.sh          # Main development script (entry point)
```

## Main Entry Point

### `dev.sh`
The unified development script that provides convenient access to common tasks:
- `./dev.sh test [pattern]` - Run tests with optional pattern filter
- `./dev.sh test-all` - Run comprehensive test suite
- `./dev.sh format` - Format code
- `./dev.sh check` - Run quality checks
- `./dev.sh dialyzer` - Run Dialyzer analysis
- `./dev.sh setup` - Setup development environment
- `./dev.sh db [action]` - Database operations
- `./dev.sh release` - Create release
- `./dev.sh clean` - Clean build artifacts

## Directory Contents

### `ci/` - CI/CD Scripts
- `build_and_test.sh` - Build and test automation
- `ci_validate_structure.sh` - Validate project structure
- `migrate-workflows.sh` - Migrate CI workflows
- `rollback-workflows.sh` - Rollback CI workflows

### `dev/` - Development Utilities
- `release.exs` - Release management
- `install_pre_commit.sh` - Pre-commit hook installation
- `run_native_terminal.sh` - Native terminal testing
- `verify_nix_env.sh` - Nix environment verification
- Various cleanup and refactoring utilities

### `testing/` - Testing Scripts
- `run_tests.sh` - Test runner
- `check_coverage.exs` - Coverage analysis
- `analyze_tests.exs` - Test analysis
- `run_platform_tests.exs` - Platform-specific tests
- `summarize_test_errors.sh` - Error summary generation
- Various test utilities

### `quality/` - Code Quality
- `pre_commit_check.exs` - Pre-commit validation
- `code_quality_metrics.exs` - Quality metrics
- `check_style.exs` - Style checking
- `check_duplicate_filenames.exs` - Duplicate detection
- `explain_credo_warning.exs` - Credo warning explanations
- Various validation scripts

### `db/` - Database Utilities
- `setup_db.sh` - Database setup
- `check_db.exs` - Connectivity check
- `diagnose_db.exs` - Database diagnostics

### `visualization/` - Visualization & Demos
- `demo_videos.sh` - Demo video generation
- `demo_showcase.md` - Demo documentation
- `test_visualization.exs` - Visualization tests
- `run_visualization_tests.exs` - Visualization test suite

### `docs/` - Documentation Generation
- `generate_docs.exs` - Main documentation generator
- `generate_api_docs.exs` - API documentation
- `simple_doc_generator.exs` - Simple doc generation
- `check_links.js` - Link validation
- `maintenance.js` - Documentation maintenance
- `search.js` - Documentation search

### `bin/` - Executable Scripts
- `demo.exs` - Demo runner
- `run_showcase.exs` - Showcase runner

### `archived/` - Archived Scripts
Contains deprecated, experimental, and refactoring scripts from previous sprints. These are kept for reference but are not actively maintained.

## Usage examples

```bash
# Run all tests
./dev.sh test-all

# Run tests matching a pattern
./dev.sh test terminal

# Check code quality before committing
./dev.sh check

# Setup development environment
./dev.sh setup

# Database operations
./dev.sh db setup
./dev.sh db check
./dev.sh db diagnose

# Create a release
./dev.sh release
```

## Adding New Scripts

When adding new scripts:
1. Place them in the appropriate subdirectory based on function
2. Update this README with a description
3. If commonly used, consider adding to `dev.sh` for easier access
4. Follow existing naming conventions (snake_case for scripts)
5. Add proper documentation headers in the script itself