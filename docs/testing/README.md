# Testing Guide

## Running tests

The suite expects `SKIP_TERMBOX2_TESTS=true` and `TMPDIR=/tmp`. Export them in your shell,
or put them in a local `.claude/settings.json` `env` block if you run tests through Claude
Code; that file is gitignored, so a fresh clone starts without it.

```bash
# Standard run (excludes slow, integration, docker-dependent tests)
MIX_ENV=test mix test --exclude slow --exclude integration --exclude docker

# Specific file or line
MIX_ENV=test mix test test/path/to/test_file.exs
MIX_ENV=test mix test test/path/to/test_file.exs:42

# Rerun only previously failed tests
MIX_ENV=test mix test --failed

# Stop after N failures
MIX_ENV=test mix test --max-failures 5
```

### Package tests

Each extracted package has its own test suite, run from inside the package directory:

```bash
cd packages/raxol_core     && MIX_ENV=test mix test
cd packages/raxol_terminal && MIX_ENV=test mix test
cd packages/raxol_sensor   && MIX_ENV=test mix test
cd packages/raxol_agent    && MIX_ENV=test mix test
# ... plus raxol_mcp, raxol_payments, raxol_liveview, raxol_plugin,
# raxol_speech, raxol_telegram, raxol_watch, raxol_earn, raxol_symphony,
# raxol_gateway, raxol_agent_client_protocol, raxol_cli, raxol_console
```

### All quality checks

`mix raxol.check` runs the quality gates in one pass. CI spreads the same tooling across
workflows (`mix format --check-formatted`, `mix raxol.check_docs`, `mix credo`,
`mix dialyzer`, and the test matrix), so a clean local run is a good pre-push signal.

```bash
mix raxol.check                        # lockfile, compile, format, credo, dialyzer, security, docs, rate, test
mix raxol.check --quick                # skip dialyzer
mix raxol.check --only format,credo   # specific checks only
mix raxol.check --skip test            # skip specific checks
```

The `rate` step runs the golden render harness (`mix raxol.rate`): it hashes a fixture
corpus and compares each hash against `priv/rate/golden.refs`, failing the gate on any
mismatch. When you change rendering on purpose, regenerate the references with
`mix raxol.rate --gen` and commit them. The hashes are architecture-independent, so a
mismatch that appears on one platform while another stays green points at a determinism
bug worth tracking down.

### Coverage

```bash
MIX_ENV=test mix test --cover
```

## Test tags

Tests are tagged to allow selective exclusion. `:slow`, `:integration`, and `:docker` are
excluded by the `--exclude` flags on the standard run above; `test/test_helper.exs` adds
the rest.

| Tag | Meaning |
|-----|---------|
| `@tag :docker` | Requires termbox2 NIF or Docker (excluded when `SKIP_TERMBOX2_TESTS=true`) |
| `@tag :skip_on_ci` | Skip in CI (also excluded when `SKIP_TERMBOX2_TESTS=true`) |
| `@tag :skip_on_windows` | Skip on Windows |
| `@tag :unix_only` | Unix/macOS only, excluded on Windows |
| `@tag :slow` | Long-running tests |
| `@tag :integration` | Full-stack integration tests |
| `@moduletag :ring_b` | Drives real GUI terminals over AppleScript; excluded unconditionally, on every platform |
| `@tag :requires_terminal` | Needs a real terminal to mean anything; `.github/workflows/rate-selfhosted.yml` runs these under a pty |
| `@tag :tmp_dir` | ExUnit's temp-dir fixture; the dir arrives in the test context |
| `@tag :event_manager` | Touches the global event manager |
| `@tag :notification` | Touches the global notification manager |
| `@tag :gpg` | Requires `gpg` on `PATH` (raxol_agent suite) |

Run only a specific tag:

```bash
MIX_ENV=test mix test --only integration
```

## Testing TEA modules

TEA modules have pure `init/1`, `update/2`, and `view/1` functions. Test them directly
without any rendering infrastructure:

```elixir
defmodule MyAppTest do
  use ExUnit.Case

  test "init returns default model" do
    model = MyApp.init(%{})
    assert model.count == 0
  end

  test "update increments count" do
    model = MyApp.init(%{})
    {model, _cmds} = MyApp.update(:inc, model)
    assert model.count == 1
  end

  test "update returns no commands for simple actions" do
    model = %{count: 5}
    {_model, cmds} = MyApp.update(:inc, model)
    assert cmds == []
  end

  test "view returns element tree" do
    model = %{count: 42}
    tree = MyApp.view(model)
    assert tree.type == :column
  end
end
```

For apps that emit commands from `update/2`, assert the command list directly:

```elixir
test "search dispatches async command" do
  model = %{query: "hello"}
  {_model, cmds} = MyApp.update({:search, "hello"}, model)
  assert [{:async, _fun}] = cmds
end
```

## Test helpers

Test helpers live in `test/support/`.

### IsolatedCase

`Raxol.Test.IsolatedCase` is a `CaseTemplate` that resets global state
(AccessibilityServer, EventManager, UserPreferences, theme state, ETS caches)
before each test. Use it when a test touches any of those shared services:

```elixir
defmodule MyTest do
  use Raxol.Test.IsolatedCase

  test "isolated from global state" do
    # global state has been reset
  end
end
```

For manual control, call the helper directly:

```elixir
setup do
  Raxol.Test.IsolationHelper.reset_global_state()
  :ok
end
```

### Other helpers

| Module | Purpose |
|--------|---------|
| `Raxol.Test.TestHelper` | Common utilities: `setup_test_terminal/0`, `wait_for_state/2`, `cleanup_process/2` |
| `test/support/buffer_helper.ex` | Screen buffer assertions |
| `test/support/event_macro_helpers.ex` | Event construction shortcuts |

## Property-based tests

Property tests live in `test/property/` and use
[StreamData](https://hexdocs.pm/stream_data) via `ExUnitProperties`.

```elixir
defmodule MyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "parser never crashes on random input" do
    check all input <- string(:printable, min_length: 1, max_length: 100),
              max_runs: 1000 do
      result = MyParser.parse(input)
      assert is_list(result)
    end
  end

  property "round-trip encode/decode" do
    check all value <- integer(),
              max_runs: 500 do
      assert value == value |> encode() |> decode()
    end
  end
end
```

Custom generators follow the `gen all` pattern:

```elixir
defp csi_sequence_generator do
  gen all cmd <- member_of(["A", "B", "C", "D", "H", "m"]),
          params <- list_of(integer(0..100), max_length: 3) do
    "\e[" <> Enum.join(params, ";") <> cmd
  end
end
```

A few of the files in `test/property/`:

- `test/property/parser_property_test.exs`: ANSI parser
- `test/property/ui_component_property_test.exs`: Button, TextInput, Flexbox, Grid
- `test/property/core_property_test.exs`: core data structures
- `test/property/parser_edge_cases_test.exs`: parser edge cases
