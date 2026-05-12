# Plugin SDK

`raxol_plugin` is the developer-facing SDK over the 40-module plugin system in `raxol_core`. If you're writing a plugin, this is the package you depend on. If you're consuming plugins from your app, you don't need it -- the runtime is in `raxol_core`.

## Quick Start

```elixir
defmodule MyPlugin do
  use Raxol.Plugin,
    name: "my_plugin",
    version: "0.1.0",
    description: "Does a thing"

  @impl true
  def init(_config) do
    {:ok, %{counter: 0}}
  end

  @impl true
  def handle_event({:key, %{key: :tab}}, state) do
    {:ok, %{state | counter: state.counter + 1}}
  end
end
```

`use Raxol.Plugin` sets the behaviour and provides six overridable defaults so you only implement what you need.

## Generator

```bash
mix raxol.gen.plugin my_plugin
```

Generates a plugin skeleton in `lib/raxol/plugins/my_plugin/` with manifest, behaviour, and a basic test file. Pass `--with-config` for a `Config` module, `--with-hooks` for lifecycle hooks.

## API Facade

`Raxol.Plugin.API` wraps `Raxol.Core.Runtime.Plugins.PluginManager` with try/catch guards. Use it instead of calling the manager directly:

```elixir
{:ok, _pid} = Raxol.Plugin.API.load("my_plugin", config: %{...})
:ok = Raxol.Plugin.API.send_event("my_plugin", {:custom_event, data})
{:ok, state} = Raxol.Plugin.API.get_state("my_plugin")
Raxol.Plugin.API.unload("my_plugin")
```

If the plugin crashes or doesn't exist, the API returns `{:error, reason}` rather than letting the exit propagate.

## Manifests

`Raxol.Plugin.Manifest` builds a map of all plugins across packages at compile time. Useful for tooling that needs to know what plugins exist:

```elixir
Raxol.Plugin.Manifest.all()
# => %{
#   "my_plugin" => %{module: MyPlugin, version: "0.1.0", ...},
#   ...
# }
```

## Testing

`Raxol.Plugin.Testing` provides ExUnit helpers:

```elixir
defmodule MyPluginTest do
  use ExUnit.Case
  import Raxol.Plugin.Testing

  setup do
    plugin = start_test_plugin(MyPlugin, config: %{})
    {:ok, plugin: plugin}
  end

  test "handles tab key", %{plugin: plugin} do
    send_event(plugin, {:key, %{key: :tab}})
    assert get_state(plugin).counter == 1
  end
end
```

`start_test_plugin/2` uses `start_supervised!` under the hood, so cleanup is automatic.

## What's in `raxol_core`

The 40-module runtime (plugin manager, dependency resolver, lifecycle, capability detector, security audit, permission mode, ETS cache, etc.) lives in `raxol_core`. You generally don't touch it directly -- the SDK is the contract.

The split exists so apps that *use* plugins don't need to depend on the SDK that *creates* them.

## See Also

- [GUIDE](../plugins/GUIDE.md) -- step-by-step plugin authoring
- [PLUGIN_TEMPLATES](../plugins/PLUGIN_TEMPLATES.md) -- ready-made starters
- [TESTING](../plugins/TESTING.md) -- in-depth testing patterns
