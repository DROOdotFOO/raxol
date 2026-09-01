# Raxol test suite

The root app's tests. Each extracted package under `packages/` has its own
suite, run from inside that package. The full guide, including package
commands, property-based testing, and the quality gate, is
[docs/testing/README.md](../docs/testing/README.md).

## Running

The suite expects `MIX_ENV=test`, `SKIP_TERMBOX2_TESTS=true`, and `TMPDIR=/tmp`.

```bash
MIX_ENV=test mix test --exclude slow --exclude integration --exclude docker
MIX_ENV=test mix test test/path/to/test.exs
MIX_ENV=test mix test test/path/to/test.exs:123
MIX_ENV=test mix test --failed
```

## Layout

- `test/support/`: helpers and case templates
- `test/property/`: StreamData property tests
- `test/fixtures/`: checked-in fixtures (harness sessions and goldens, themes,
  plugins, configs)
- everything else: tests organized by module or feature. Test paths do not
  always mirror `lib/` paths, so grep before concluding something is untested

## Helpers

| Module | File | What it gives you |
| --- | --- | --- |
| `Raxol.Test.TestHelper` | `support/raxol_test_helper.ex` | Common setup, `wait_for_state/2` polling |
| `Raxol.Test.IsolationHelper` | `support/isolation_helper.ex` | `reset_global_state/0` between tests |
| `Raxol.Test.TestUtils` | `support/test_utils.ex` | Case template with shared utilities |
| `Raxol.Test.SharedUtilities` | `support/shared_test_utilities.ex` | Utilities the other helpers share |
| `Raxol.DataCase` | `support/data_case.ex` | Database-backed setup, always `async: false` |
| `Raxol.Test.PropertyGenerators` | `support/property_generators.ex` | StreamData generators |

Mocks for the core runtime behaviours are defined in `test_helper.exs`.
Database tests run against a MockDB adapter, not an Ecto sandbox;
`database_enabled` is false in `config/test.exs`.

## Conventions

- **No `Process.sleep`.** Use `assert_receive` or `wait_for_state/2`.
- **Clean up in `setup`.** `on_exit` for processes, ETS tables, and temp files.
- **Isolate.** Unique process names, and reset shared state rather than relying
  on test order.
- **Async where safe.** `async: true` for pure unit tests, `async: false` for
  anything touching a named process or the database.

Tags auto-excluded by environment: `:docker` and `:skip_on_ci` (when
`SKIP_TERMBOX2_TESTS=true`), `:unix_only` (on Windows), plus `:slow` and
`:integration` when you pass the exclude flags above.

## Troubleshooting

Flaky under a full run but green alone is almost always shared state. See
[Test Isolation Guide](../docs/testing/TEST_ISOLATION_GUIDE.md) and
[Quick Reference](../docs/testing/QUICK_REFERENCE.md).
