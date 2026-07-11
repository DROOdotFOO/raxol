# Plugin SDK

`raxol_plugin` is the developer-facing SDK over the 40-module plugin system in `raxol_core`. If you're writing a plugin, this is the package you depend on. If you're consuming plugins from your app, you don't need it; the runtime is in `raxol_core`.

## Quick Start

```elixir
defmodule MyPlugin do
  use Raxol.Plugin

  @impl true
  def init(_config) do
    {:ok, %{counter: 0}}
  end

  @impl true
  def filter_event({:key, %{key: :tab}} = event, _state) do
    {:ok, event}
  end

  @impl true
  def handle_command(:bump, _args, state) do
    {:ok, %{state | counter: state.counter + 1}, :ok}
  end
end
```

`use Raxol.Plugin` sets the behaviour and provides six overridable defaults (`terminate/2`, `enable/1`, `disable/1`, `filter_event/2`, `handle_command/3`, `get_commands/0`) so you only implement what you need; only `init/1` is required. The `use` line takes no options. To declare plugin metadata (name, version, dependencies), build a `Raxol.Plugin.Manifest` (see [Manifests](#manifests)).

## Generator

```bash
mix raxol.gen.plugin my_plugin
```

Generates a plugin module at `lib/my_plugin.ex` (the module name is underscored into the path) and a matching `test/my_plugin_test.exs` with a lifecycle smoke test. Pass a dotted name like `MyApp.Plugins.Logger` to nest the generated files.

## API Facade

`Raxol.Plugin.API` wraps `Raxol.Core.Runtime.Plugins.PluginManager` with try/catch guards. Use it instead of calling the manager directly:

```elixir
:ok = Raxol.Plugin.API.load(MyPlugin, %{some: "config"})
:ok = Raxol.Plugin.API.enable(:my_plugin)
state = Raxol.Plugin.API.get_state(:my_plugin)
:ok = Raxol.Plugin.API.disable(:my_plugin)
Raxol.Plugin.API.unload(:my_plugin)
```

`load/2` takes a module atom and a config map; the other functions take the plugin id (an atom). If the plugin crashes or doesn't exist, the API returns `{:error, reason}` rather than letting the exit propagate.

## Manifests

`Raxol.Plugin.Manifest` builds a plain manifest map (not a struct, for cross-package safety) from keyword options and validates it. Use it to declare a plugin's identity, version, and dependencies:

```elixir
manifest =
  Raxol.Plugin.Manifest.new(
    id: :my_plugin,
    name: "My Plugin",
    version: "0.1.0",
    module: MyPlugin,
    depends_on: [{:other_plugin, "~> 1.0"}]
  )

case Raxol.Plugin.Manifest.validate(manifest) do
  :ok -> :ok
  {:error, errors} -> IO.inspect(errors)
end
```

## Testing

`Raxol.Plugin.Testing` provides ExUnit helpers:

```elixir
defmodule MyPluginTest do
  use ExUnit.Case
  import Raxol.Plugin.Testing

  setup do
    {:ok, state} = setup_plugin(MyPlugin, %{})
    {:ok, state: state}
  end

  test "passes the tab key through", %{state: state} do
    assert_handles_event(MyPlugin, {:key, %{key: :tab}}, state)
  end

  test "bump increments the counter", %{state: state} do
    {new_state, :ok} = assert_handles_command(MyPlugin, :bump, [], state)
    assert new_state.counter == 1
  end
end
```

The helpers exercise plugin callbacks in isolation without starting the full plugin manager, so there is no process to tear down: `setup_plugin/2` calls `init/1`, and `assert_handles_event/3` / `assert_handles_command/4` / `simulate_lifecycle/2` / `assert_halts_event/3` drive the other callbacks directly.

## What's in `raxol_core`

The 40-module runtime (plugin manager, dependency resolver, lifecycle, capability detector, security audit, permission mode, ETS cache, etc.) lives in `raxol_core`. You generally don't touch it directly; the SDK is the contract.

The split exists so apps that *use* plugins don't need to depend on the SDK that *creates* them.

## See Also

- [GUIDE](https://github.com/DROOdotFOO/raxol/blob/master/docs/plugins/GUIDE.md): step-by-step plugin authoring
- [PLUGIN_TEMPLATES](https://github.com/DROOdotFOO/raxol/blob/master/docs/plugins/PLUGIN_TEMPLATES.md): ready-made starters
- [TESTING](https://github.com/DROOdotFOO/raxol/blob/master/docs/plugins/TESTING.md): in-depth testing patterns
