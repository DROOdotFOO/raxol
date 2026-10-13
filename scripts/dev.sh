#!/usr/bin/env bash
# Unified development script for Raxol
# Consolidates common development tasks

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  test [pattern]     - Run tests (optional pattern filter)"
    echo "  test-all          - Run all test suites (unit, integration, platform)"
    echo "  format            - Format code with mix format"
    echo "  check             - Run all quality checks (dialyzer, credo, docs)"
    echo "  dialyzer          - Run Dialyzer with PLT caching"
    echo "  setup             - Setup development environment"
    echo "  db                - Database operations (setup, check, diagnose)"
    echo "  release           - Create release"
    echo "  clean             - Clean build artifacts"
    echo ""
    echo "Examples:"
    echo "  $0 test terminal          # Run tests matching 'terminal'"
    echo "  $0 test-all              # Run comprehensive test suite"
    echo "  $0 check                 # Run pre-commit checks"
    echo "  $0 dialyzer              # Run Dialyzer static analysis"
}

run_tests() {
    local pattern=${1:-""}
    echo "Running tests${pattern:+ matching '$pattern'}..."
    
    if [ -n "$pattern" ]; then
        mix test --include=integration test/ --grep="$pattern"
    else
        mix test --include=integration
    fi
}

run_all_tests() {
    echo "Running comprehensive test suite..."
    
    # Core tests
    mix test --include=integration
    
    # Platform-specific tests
    if command -v mix run scripts/testing/run_platform_tests.exs >/dev/null; then
        mix run scripts/testing/run_platform_tests.exs
    fi
    
    # Visualization tests
    if [ -f "$SCRIPT_DIR/visualization/test_visualization.exs" ]; then
        mix run scripts/visualization/test_visualization.exs
    fi
}

run_checks() {
    echo "Running quality checks..."
    
    # Format check
    mix format --check-formatted
    
    mix dialyzer
    mix credo
    mix docs
}

run_dialyzer() {
    echo "Running Dialyzer static analysis..."
    mix dialyzer "$@"
}

setup_env() {
    echo "Setting up development environment..."
    
    mix deps.get
    mix deps.compile
    
    if [ -f "$SCRIPT_DIR/db/setup_db.sh" ]; then
        bash "$SCRIPT_DIR/db/setup_db.sh"
    fi
    
    echo "Environment setup complete!"
}

db_operations() {
    local action=${1:-"setup"}
    
    case $action in
        setup)
            bash "$SCRIPT_DIR/db/setup_db.sh"
            ;;
        check)
            mix run scripts/db/check_db.exs
            ;;
        diagnose)
            mix run scripts/db/diagnose_db.exs
            ;;
        *)
            echo "Unknown db action: $action"
            echo "Available: setup, check, diagnose"
            exit 1
            ;;
    esac
}

case ${1:-""} in
    test)
        run_tests "$2"
        ;;
    test-all)
        run_all_tests
        ;;
    format)
        mix format
        ;;
    check)
        run_checks
        ;;
    dialyzer)
        shift
        run_dialyzer "$@"
        ;;
    setup)
        setup_env
        ;;
    db)
        db_operations "$2"
        ;;
    release)
        mix run scripts/dev/release.exs
        ;;
    clean)
        mix clean
        rm -rf _build deps
        ;;
    help|--help|-h)
        usage
        ;;
    "")
        echo "No command specified."
        usage
        exit 1
        ;;
    *)
        echo "Unknown command: $1"
        usage
        exit 1
        ;;
esac