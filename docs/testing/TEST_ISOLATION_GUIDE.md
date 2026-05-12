# Test Isolation Guide

## The Problem

Tests fail when run as a full suite but pass individually. The root causes:

- Dynamic module loading/reloading from plugin fixtures
- Shared global process state
- Process name conflicts
- Test execution order dependencies

## Fixes

### 1. Isolate Plugin Tests with Module Prefixes

Plugin fixtures redefine the same module names repeatedly. Use unique module names per test.

```elixir
# In plugin_server_test.exs
setup do
  test_id = :erlang.unique_integer([:positive])
  module_prefix = "TestPlugin#{test_id}"

  {:ok, pid} = PluginServer.start_link(
    name: :"PluginServer#{test_id}",
    plugin_paths: [],
    auto_load: false
  )

  on_exit(fn ->
    if Process.alive?(pid), do: GenServer.stop(pid)
  end)

  %{plugin_server: pid, module_prefix: module_prefix}
end
```

### 2. Use `start_supervised!` for Process Management

Manual start/stop of GenServers causes conflicts between tests. Let ExUnit manage the lifecycle instead.

```elixir
# Before (problematic)
setup do
  case Process.whereis(SessionBridge) do
    nil -> {:ok, _pid} = SessionBridge.start_link([])
    _pid -> :ok
  end
  :ok
end

# After (isolated)
setup do
  _pid = start_supervised!(SessionBridge)
  :ok
end
```

### 3. Make Global Processes Test-Specific

The `test_helper.exs` starts global processes that tests share. Move them to individual test `setup` blocks.

```elixir
# test_helper.exs - REMOVE global process starts
# - Don't start EventManager globally
# - Don't start Registry globally
# - Don't start ProcessStore globally

# individual_test.exs - per-test isolation
setup do
  registry_name = :"test_registry_#{:erlang.unique_integer([:positive])}"
  start_supervised!({Registry, keys: :duplicate, name: registry_name})

  event_manager_name = :"test_event_manager_#{:erlang.unique_integer([:positive])}"
  start_supervised!({Raxol.Core.Events.EventManager, name: event_manager_name})

  %{registry: registry_name, event_manager: event_manager_name}
end
```

### 4. Add Explicit Module Loading Checks

`function_exported?` races with dynamic compilation. Ensure modules are loaded first.

```elixir
# Before
test "defines handle_in/3 callback" do
  assert function_exported?(RaxolWeb.TerminalChannel, :handle_in, 3)
end

# After
test "defines handle_in/3 callback" do
  Code.ensure_loaded!(RaxolWeb.TerminalChannel)
  Process.sleep(10)
  assert function_exported?(RaxolWeb.TerminalChannel, :handle_in, 3)
end
```

### 5. Use `async: true` Where Safe

Tests without shared state can run in parallel.

```elixir
# Safe for async (no global state, no named processes)
defmodule Raxol.SomeTest do
  use ExUnit.Case, async: true

  test "pure function" do
    assert MyModule.add(1, 2) == 3
  end
end

# Not safe for async (uses named processes)
defmodule Raxol.PluginServerTest do
  use ExUnit.Case, async: false

  test "starts plugin server" do
    {:ok, _} = PluginServer.start_link(name: PluginServer)
  end
end
```

### 6. Clean Up Dynamic Modules

Plugin tests leave modules defined in memory. Purge them after each test.

```elixir
setup do
  loaded_modules = []

  on_exit(fn ->
    Enum.each(loaded_modules, fn mod ->
      :code.purge(mod)
      :code.delete(mod)
    end)
  end)

  %{loaded_modules: loaded_modules}
end
```

## Priority

### High (do first)

1. **TerminalChannel and Presence tests** - Add `Code.ensure_loaded!` before `function_exported?` checks. Use unique process names in setup.

2. **Plugin tests** - Use `start_supervised!` for PluginServer. Generate unique module names per test.

### Medium

3. **Refactor test_helper.exs** - Move global process starts to helper functions. Let individual tests opt in to needed services.

4. **Add test utilities** - Extend `Raxol.Test.IsolationHelper` with `start_test_registry/0` and `start_test_event_manager/0`.

### Low

5. **Enable more async tests** - Audit tests for async safety and convert where possible.

## Full Example: TerminalChannelTest

```elixir
defmodule RaxolWeb.TerminalChannelTest do
  use ExUnit.Case, async: false

  setup do
    test_id = :erlang.unique_integer([:positive])

    session_bridge = start_supervised!(
      {Raxol.Web.SessionBridge, name: :"SessionBridge#{test_id}"}
    )

    persistent_store = start_supervised!(
      {Raxol.Web.PersistentStore, name: :"PersistentStore#{test_id}"}
    )

    Code.ensure_loaded!(RaxolWeb.TerminalChannel)

    %{
      session_bridge: session_bridge,
      persistent_store: persistent_store
    }
  end

  describe "module structure" do
    test "module exists" do
      assert Code.ensure_loaded?(RaxolWeb.TerminalChannel)
    end

    test "defines handle_in/3 callback" do
      assert function_exported?(RaxolWeb.TerminalChannel, :handle_in, 3)
    end
  end
end
```

## Verifying the Fixes

After applying changes, run the suite multiple times with different seeds to catch ordering issues:

```bash
for i in {1..5}; do
  echo "Run $i"
  env TMPDIR=/tmp SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test --seed $RANDOM
done

# Or target the previously flaky tests specifically
env TMPDIR=/tmp SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test \
  test/raxol_web/channels/terminal_channel_test.exs \
  test/raxol_web/presence_test.exs \
  --seed $RANDOM \
  --repeat-until-failure 10
```
