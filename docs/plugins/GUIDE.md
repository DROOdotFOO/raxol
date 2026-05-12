# Plugin Development Guide

How to build Raxol plugins with lifecycle management, event filtering, and process isolation. The canonical entry point is `use Raxol.Plugin` from the [`raxol_plugin`](../features/PLUGIN_SDK.md) package; the underlying `Raxol.Core.Runtime.Plugins.Plugin` behaviour stays a runtime concern.

## Quick Start

```elixir
defmodule YourApp.Plugins.MyPlugin do
  use Raxol.Plugin,
    name: "my_plugin",
    version: "1.0.0",
    description: "Brief description"

  @impl true
  def init(config) do
    {:ok, %{config: config}}
  end

  @impl true
  def handle_event({:key, %{key: :tab}}, state) do
    {:ok, state}
  end
end
```

`use Raxol.Plugin` sets the behaviour, builds the manifest from the macro args, and provides six overridable defaults (`init/1`, `enable/1`, `disable/1`, `terminate/2`, `handle_event/2`, `handle_command/2`). Override only what you need.

For a scaffolded project:

```bash
mix raxol.gen.plugin my_plugin
```

See [PLUGIN_TEMPLATES.md](PLUGIN_TEMPLATES.md) for complete working examples, including stateful plugins, event filtering, and timer-driven plugins.

## Plugin Lifecycle

### States & Transitions

```
Discovery -> Loading -> Starting -> Running -> Stopping -> Stopped -> Terminated
             | init    | enable              | disable              | terminate
```

### Loading Phase (init/1)

```elixir
@impl true
def init(config) do
  state = %__MODULE__{
    config: config,
    data: load_initial_data()
  }
  {:ok, state}
end
```

### Starting Phase (enable/1)

```elixir
@impl true
def enable(state) do
  timer = :timer.send_interval(5000, :refresh)
  new_state = %{state | timers: [timer]}
  {:ok, new_state}
end
```

### Stopping Phase (disable/1)

```elixir
@impl true
def disable(state) do
  Enum.each(state.timers, &:timer.cancel/1)
  {:ok, %{state | timers: []}}
end
```

### Termination (terminate/2)

```elixir
@impl true
def terminate(_reason, state) do
  # Final cleanup
  :ok
end
```

## Plugin Manifest

The manifest is built into a `Raxol.Core.Runtime.Plugins.Manifest` struct. Supported fields:

```elixir
def manifest do
  %{
    # Required
    id: "unique-id",                    # Kebab-case identifier
    name: "Display Name",
    version: "1.0.0",                   # Semantic versioning
    author: "Your Name",
    module: __MODULE__,

    # Optional
    description: "What it does",
    api_version: "1.0",                 # Defaults to "1.0"
    depends_on: ["other-plugin-id"],    # Other plugin IDs
    conflicts_with: [],
    provides: [:keyboard_input],        # Informational tags
    requires: [],                       # Required runtime services
    resource_budget: %{}                # Optional resource limits
  }
end
```

There is no `dependencies:` map for Hex packages, no `capabilities:` enforcement, no `trust_level:` field, and no `config_schema:`. Plugin config is whatever map the host passes to `init/1`.

## Event System

### Event Types

Events arrive as `%Raxol.Core.Events.Event{}` structs:

- **Keyboard**: `%Event{type: :key, data: %{key: :char, char: "q"}}`, `%Event{type: :key, data: %{key: :enter}}`
- **Terminal**: `%Event{type: :resize, data: %{width: 80, height: 24}}`
- **System**: `{:file_change, path}`, `{:process_exit, pid, reason}`
- **Plugin**: `{:plugin_loaded, name}`, `{:plugin_unloaded, name}`

### Event Flow

```
System Event -> filter_event/2 (priority order) -> Core Processing
                     |
              Can modify, pass through, or halt
```

### Event Filtering

Implement `filter_event/2` to intercept, modify, or block events:

```elixir
alias Raxol.Core.Events.Event

# Block events (stops propagation)
def filter_event(%Event{type: :key, data: %{key: :f12}}, _state), do: :halt

# Modify events
def filter_event(%Event{type: :key, data: %{key: :char, char: "j"}} = event, _state) do
  {:ok, %{event | data: %{key: :down}}}
end

# Pass through unchanged
def filter_event(event, _state), do: {:ok, event}
```

### Command Handling

```elixir
@callback handle_command(command(), list(), state()) ::
  {:ok, state(), any()} | {:error, any(), state()}

def handle_command(:refresh, [], state) do
  new_data = fetch_data()
  {:ok, %{state | data: new_data}, :ok}
end

def get_commands do
  [{:refresh, :handle_command, 3}]
end
```

### Plugin Priority

Control event processing order with `priority` in the manifest:

```elixir
def manifest do
  %{
    name: "high-priority-plugin",
    version: "1.0.0",
    priority: 1,  # Lower = higher priority (processed first)
    # ...
  }
end
```

Plugins without explicit priority default to `1000`.

Dependencies are automatically sorted -- dependent plugins see events after their dependencies have processed them.

### Error Handling in Filters

Filter errors are logged but don't stop event propagation. Filters run under `PluginSupervisor` with a 1-second timeout by default. If a filter crashes, the event passes through to the next plugin.

## Capabilities

Plugins declare what they offer in the manifest's `provides:` list. The list is informational -- the runtime does not enforce a fixed allowlist. Common values used by host code: `:command_handler`, `:keyboard_input`, `:status_line`, `:file_watcher`, `:theme_provider`.

There is no UI rendering callback on the Plugin behaviour. Plugins influence the UI by emitting commands or events that an app or Component consumes. To embed Components, build a `Raxol.UI.Components.Base.Component` and have the plugin update its model.

### Keyboard Input

```elixir
def manifest do
  %{provides: [:keyboard_input], ...}
end

def filter_event({:key_press, hotkey}, state) when hotkey == state.config.hotkey do
  {:ok, {:plugin_event, :activated}}
end
```

### File Watcher

```elixir
def init(config) do
  {:ok, watcher} = FileSystem.start_link(dirs: [config.watch_dir])
  FileSystem.subscribe(watcher)
  {:ok, %__MODULE__{watcher: watcher}}
end

def filter_event({:file_event, _watcher, {path, _events}}, state) do
  {:ok, {:file_changed, path}}
end
```

## State Management

Plugin state is managed through an ETS-backed `StateManager` for concurrent access and crash recovery. Each plugin's state is isolated. State updates from `filter_event/2` and `handle_command/3` are automatically persisted.

State persists across hot reloads. If a plugin crashes, its last known state is preserved and restored on restart.

## Security Analysis

Raxol automatically analyzes plugin BEAM bytecode to detect security-sensitive operations.

### Detected Capabilities

| Capability         | Detected Operations                            |
| ------------------ | ---------------------------------------------- |
| `:file_access`     | `File.*`, `:file.*`, `Path.*`                  |
| `:network_access`  | `:gen_tcp.*`, `:ssl.*`, `Req.*`, `HTTPoison.*` |
| `:code_injection`  | `Code.eval_*`, `Module.create`, `:erl_eval.*`  |
| `:system_commands` | `System.cmd`, `Port.open`, `:os.cmd`           |

### Security Policies

```elixir
alias Raxol.Core.Runtime.Plugins.Security.CapabilityDetector

# Default policy (denies all sensitive operations)
policy = CapabilityDetector.default_policy()

# Custom policy allowing specific capabilities
policy = CapabilityDetector.create_policy([:file_access])

# Validate a plugin module
case CapabilityDetector.validate_against_policy(MyPlugin, policy) do
  :ok -> :load_plugin
  {:error, :file_access_denied} -> :reject_plugin
  {:error, :network_access_denied} -> :reject_plugin
end
```

The bytecode analyzer detects what the plugin actually does. Validation compares those detected capabilities against the policy, regardless of what the manifest claims.

## Process Isolation

Plugin operations run under `PluginSupervisor` for crash isolation. Plugin crashes don't affect the core application.

```elixir
alias Raxol.Core.Runtime.Plugins.PluginSupervisor

# Synchronous with isolation
case PluginSupervisor.run_plugin_task(:my_plugin, fn ->
  risky_operation()
end) do
  {:ok, result} -> handle_result(result)
  {:error, {:crashed, reason}} -> log_crash(reason)
  {:error, {:timeout, ms}} -> log_timeout(ms)
end

# Fire and forget
PluginSupervisor.async_plugin_task(:my_plugin, fn ->
  background_work()
end)

# Concurrent tasks with individual failure isolation
results = PluginSupervisor.run_plugin_tasks_concurrent(:my_plugin, [
  fn -> fetch_data() end,
  fn -> process_config() end,
  fn -> load_cache() end
])
# => [{:ok, data}, {:ok, config}, {:ok, cache}]
```

Custom timeouts: `PluginSupervisor.run_plugin_task(:my_plugin, fun, timeout: 10_000)`

## Testing

See [TESTING.md](TESTING.md) for the full testing guide.

```elixir
defmodule MyPluginTest do
  use ExUnit.Case

  test "plugin lifecycle" do
    {:ok, state} = MyPlugin.init(%{})
    {:ok, state} = MyPlugin.enable(state)
    assert state.enabled
    {:ok, state} = MyPlugin.disable(state)
    refute state.enabled
  end
end
```

## Examples

- [Spotify Plugin](examples/SPOTIFY.md): sample plugin with OAuth, state management, and API integration
