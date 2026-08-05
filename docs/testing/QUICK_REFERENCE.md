# Test Isolation - Quick Reference

## Common patterns

### Testing module exports

```elixir
# BAD - Can race with module compilation
test "defines function" do
  assert function_exported?(MyModule, :my_function, 1)
end

# GOOD - Ensures module is loaded first
test "defines function" do
  Code.ensure_loaded!(MyModule)
  assert function_exported?(MyModule, :my_function, 1)
end
```

### Starting GenServers in tests

```elixir
# BAD - Manual cleanup, name conflicts
setup do
  {:ok, pid} = MyServer.start_link(name: MyServer)
  on_exit(fn -> GenServer.stop(pid) end)
  :ok
end

# GOOD - ExUnit handles cleanup
setup do
  test_id = :erlang.unique_integer([:positive])
  start_supervised!({MyServer, name: :"MyServer_#{test_id}"})
  :ok
end
```

### Testing with dynamic modules

```elixir
# BAD - Modules persist across tests
test "loads plugin" do
  Code.compile_string("defmodule MyPlugin, do: ...")
end

# GOOD - Unique names and cleanup
setup do
  test_id = :erlang.unique_integer([:positive])
  module_name = :"TestPlugin#{test_id}"

  on_exit(fn ->
    :code.purge(module_name)
    :code.delete(module_name)
  end)

  %{module_name: module_name}
end
```

### Async vs sync tests

```elixir
# Safe for async - pure functions, no shared state
defmodule MyPureModuleTest do
  use ExUnit.Case, async: true

  test "adds numbers" do
    assert MyModule.add(1, 2) == 3
  end
end

# NOT safe for async - uses named processes
defmodule MyServerTest do
  use ExUnit.Case, async: false

  test "starts server" do
    start_supervised!({MyServer, name: MyServer})
  end
end
```

## Flaky test checklist

When tests pass individually but fail in the suite:

- [ ] Add `Code.ensure_loaded!` before `function_exported?` checks
- [ ] Use unique process names: `:"ProcessName_#{:erlang.unique_integer([:positive])}"`
- [ ] Replace manual process management with `start_supervised!`
- [ ] Set `async: false` if test uses named processes or global state
- [ ] Clean up dynamic modules in `on_exit`
- [ ] Check for shared ETS tables or registries

## Warning signs

Things that indicate isolation problems:

- Tests pass individually but fail in suite
- Failures only occur with certain seeds
- "already_started" errors
- "name conflict" errors
- Module redefinition warnings
- Race conditions in `function_exported?` checks

The fix is almost always: unique names, `start_supervised!`, explicit module loading, and cleanup in `on_exit`.

## Commands

```bash
# Test specific file with seed
mix test path/to/test.exs --seed 12345

# Run test until failure (catch flakiness)
mix test path/to/test.exs --seed $RANDOM --max-failures 1

# Test with specific seed multiple times
for i in {1..10}; do
  mix test path/to/test.exs --seed 12345 || break
done
```
