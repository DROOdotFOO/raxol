# Raxol Plugin

Plugin SDK for building extensible Raxol terminal applications.

Provides the `use Raxol.Plugin` macro, a public API facade, manifest validation, testing utilities, and a code generator. Wraps the 40-module plugin infrastructure in `raxol_core` with a clean, safe cross-package boundary.

## Install

```elixir
# mix.exs
def deps do
  [{:raxol_plugin, path: "packages/raxol_plugin"}]
end
```

## Modules

| Module | Purpose |
|--------|---------|
| `Raxol.Plugin` | `use` macro: sets behaviour, 6 overridable callback defaults, `init/1` required |
| `Raxol.Plugin.API` | Public facade: load, unload, enable, disable, list, get_state, reload (all try/catch guarded) |
| `Raxol.Plugin.Manifest` | Cross-package manifest builder with `validate/1` |
| `Raxol.Plugin.Testing` | ExUnit helpers: `setup_plugin`, `assert_handles_event`, `simulate_lifecycle` |
| `mix raxol.gen.plugin` | Generator: creates plugin module + test file skeleton |

## Quick Start

Generate a plugin:

```bash
mix raxol.gen.plugin MyPlugin
```

Or write one by hand:

```elixir
defmodule MyPlugin do
  use Raxol.Plugin

  @impl true
  def init(config) do
    {:ok, %{enabled: true, config: config}}
  end

  @impl true
  def handle_event(:some_event, data, state) do
    {:ok, %{state | last_event: data}}
  end
end
```

Load and manage at runtime:

```elixir
alias Raxol.Plugin.API

API.load(MyPlugin, %{setting: "value"})
API.enable(MyPlugin)
API.get_state(MyPlugin)
API.disable(MyPlugin)
API.unload(MyPlugin)
```

## Testing

```elixir
use ExUnit.Case
import Raxol.Plugin.Testing

test "handles events" do
  {:ok, state} = setup_plugin(MyPlugin, %{})
  assert_handles_event(MyPlugin, :some_event, %{data: 1}, state)
end
```

```bash
cd packages/raxol_plugin && MIX_ENV=test mix test  # 50 tests, 0 failures
```

See [Plugin Guide](../../docs/plugins/GUIDE.md) for development patterns.
