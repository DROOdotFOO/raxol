# Test Isolation Guide

## The problem

Tests fail when run as a full suite but pass individually. The root causes:

- Dynamic module loading/reloading from plugin fixtures
- Shared global process state
- Process name conflicts
- Test execution order dependencies

## Fixes

### 1. Isolate plugin tests with module prefixes

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

### 2. Use `start_supervised!` for process management

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

### 3. Make global processes test-specific

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

### 4. Add explicit module loading checks

`function_exported?` races with dynamic compilation. Ensure modules are loaded first.

```elixir
# Before
test "defines handle_event/3 callback" do
  assert function_exported?(MyModule, :handle_event, 3)
end

# After
test "defines handle_event/3 callback" do
  Code.ensure_loaded!(MyModule)
  assert function_exported?(MyModule, :handle_event, 3)
end
```

### 5. Use `async: true` where safe

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

### 6. Clean up dynamic modules

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

## Where to start

1. **Plugin tests.** Use `start_supervised!` for `PluginServer` and generate
   unique module names per test. This is the largest concentration of the
   dynamic-module and named-process problems above.
2. **`test_helper.exs` globals.** It still starts `ProcessStore`, the
   `:raxol_event_subscriptions` registry, and `EventManager` for the whole
   suite. Moving those into helper functions that individual tests opt into
   is fix 3, and it is not done.
3. **Async audit.** Convert tests to `async: true` where fix 5 says it is
   safe.

## Verifying the fixes

After applying changes, run the suite multiple times with different seeds to catch ordering issues:

```bash
for i in {1..5}; do
  echo "Run $i"
  env TMPDIR=/tmp SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test --seed $RANDOM
done

# Or hammer one suspected file until it fails
env TMPDIR=/tmp SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test \
  test/path/to/suspect_test.exs \
  --seed $RANDOM \
  --repeat-until-failure 10
```
