# Plugin Lifecycle and Hooks Reference

**Version**: v1.6.0
**Last Updated**: 2025-09-26
**Target**: Plugin developers

## Plugin Lifecycle Overview

Raxol plugins follow the `Raxol.Core.Runtime.Plugins.Plugin` behaviour and go through a well-defined lifecycle managed by the Plugin System v2.0.

## Core Plugin Behaviour

### Required Callbacks

All plugins must implement these callbacks:

```elixir
@behaviour Raxol.Core.Runtime.Plugins.Plugin

# Plugin initialization
@callback init(config()) :: {:ok, state()} | {:error, any()}

# Plugin termination
@callback terminate(any(), state()) :: any()

# Plugin enable/disable
@callback enable(state()) :: {:ok, state()} | {:error, any()}
@callback disable(state()) :: {:ok, state()} | {:error, any()}
```

### Optional Callbacks

These callbacks provide additional functionality:

```elixir
# Event filtering - intercept and modify system events
@callback filter_event(event(), state()) :: {:ok, event()} | :halt | any()

# Command handling - handle plugin-specific commands
@callback handle_command(command(), list(), state()) ::
  {:ok, state(), any()} | {:error, any(), state()}

# Command declaration - list available commands
@callback get_commands() :: [{atom(), atom(), non_neg_integer()}]
```

## Detailed Lifecycle States

### 1. Discovery Phase

```
Plugin File/Module Discovery
           ↓
    Manifest Validation
           ↓
   Dependency Resolution
           ↓
     Security Check
```

### 2. Loading Phase

```elixir
# Plugin System v2.0 loads plugin
{:ok, plugin_state} = YourPlugin.init(config)

# Plugin state transitions: :loaded
state = %PluginState{
  manifest: manifest,
  status: :loaded,
  module: YourPlugin,
  dependencies: resolved_deps,
  performance_metrics: %{}
}
```

### 3. Starting Phase

```elixir
# System calls enable callback
{:ok, new_state} = YourPlugin.enable(plugin_state)

# Plugin state transitions: :starting -> :running
```

### 4. Runtime Phase

During runtime, plugins can:

#### Handle Events (Optional)

```elixir
def filter_event({:key_press, key}, state) do
  case key do
    "ctrl+p" ->
      # Intercept Ctrl+P and open command palette
      new_state = %{state | palette_open: true}
      {:ok, {:plugin_event, :palette_open}}

    _ ->
      # Pass through other events
      {:ok, {:key_press, key}}
  end
end
```

#### Handle Commands (Optional)

```elixir
def handle_command(:show_status, [], state) do
  status_info = generate_status_report(state)
  {:ok, state, status_info}
end

def handle_command(:refresh_data, [source], state) do
  new_data = fetch_data_from_source(source)
  new_state = %{state | data: new_data}
  {:ok, new_state, :refreshed}
end

# Declare available commands
def get_commands do
  [
    {:show_status, :handle_command, 3},
    {:refresh_data, :handle_command, 3}
  ]
end
```

### 5. Stopping Phase

```elixir
# System calls disable callback
{:ok, final_state} = YourPlugin.disable(running_state)

# Plugin state transitions: :stopping -> :stopped
```

### 6. Termination Phase

```elixir
# System calls terminate callback
:ok = YourPlugin.terminate(:normal, final_state)

# Plugin removed from system
```

## Event System Integration

### Event Types

Plugins can filter and respond to these system events:

- **Input Events**: `{:key_press, key}`, `{:mouse_click, x, y}`, `{:scroll, direction}`
- **Terminal Events**: `{:terminal_resize, {width, height}}`, `{:terminal_focus, boolean}`
- **System Events**: `{:file_change, path}`, `{:process_exit, pid, reason}`
- **Plugin Events**: `{:plugin_loaded, name}`, `{:plugin_unloaded, name}`

### Event Flow

```
System Event
     ↓
Plugin.filter_event/2 (each loaded plugin)
     ↓
Modified/Original Event
     ↓
Core System Processing
```

### Event Filtering Examples

```elixir
# Block specific events
def filter_event({:key_press, "F12"}, state) do
  # Don't let F12 reach the system
  :halt
end

# Modify events
def filter_event({:key_press, key}, state) when key in ["j", "k", "h", "l"] do
  # Convert vim keys to arrow keys
  arrow_key = vim_to_arrow(key)
  {:ok, {:key_press, arrow_key}}
end

# Pass through unchanged
def filter_event(event, _state) do
  {:ok, event}
end
```

## Command Integration

### Command Registration

Commands are automatically registered when plugins are loaded:

```elixir
# In your plugin
def get_commands do
  [
    {:search, :handle_search_command, 3},
    {:open_file, :handle_open_file_command, 3},
    {:toggle_panel, :handle_toggle_panel_command, 3}
  ]
end

# Commands are accessible as:
# "plugin-name:search"
# "plugin-name:open_file"
# "plugin-name:toggle_panel"
```

### Command Execution

```elixir
# User executes: "my-plugin:search query term"
def handle_command(:search, ["query", "term"], state) do
  results = perform_search(state, "query term")
  new_state = %{state | search_results: results}
  {:ok, new_state, results}
end

# Error handling
def handle_command(:invalid_command, _args, state) do
  {:error, "Unknown command", state}
end
```

## State Management Patterns

### Plugin State Structure

```elixir
defmodule MyPlugin do
  defstruct [
    # Configuration from user
    :config,

    # UI state
    :ui_visible,
    :selected_item,
    :cursor_position,

    # Data state
    :cached_data,
    :last_update,

    # Resource management
    :timers,
    :subscriptions,
    :file_watchers
  ]

  def init(config) do
    state = %__MODULE__{
      config: config,
      ui_visible: false,
      selected_item: 0,
      cursor_position: {0, 0},
      cached_data: %{},
      last_update: DateTime.utc_now(),
      timers: [],
      subscriptions: [],
      file_watchers: []
    }

    {:ok, state}
  end
end
```

### State Transitions

```elixir
# Clean state transitions
def enable(%{config: config} = state) do
  # Start timers
  refresh_timer = :timer.send_interval(config.refresh_ms, self(), :refresh)

  # Subscribe to events
  :ok = subscribe_to_file_changes(config.watch_path)

  new_state = %{state |
    timers: [refresh_timer],
    subscriptions: [:file_changes]
  }

  {:ok, new_state}
end

def disable(state) do
  # Clean up resources
  Enum.each(state.timers, &:timer.cancel/1)
  unsubscribe_from_all(state.subscriptions)

  clean_state = %{state |
    timers: [],
    subscriptions: []
  }

  {:ok, clean_state}
end
```

## Hot Reload Support

### State Migration

```elixir
# Optional callback for state migration during hot reload
def migrate_state(old_state, old_version, new_version) do
  case {old_version, new_version} do
    {"1.0.0", "1.1.0"} ->
      # Add new field with default
      Map.put(old_state, :new_field, "default_value")

    {"1.1.0", "2.0.0"} ->
      # Major version change - restructure state
      %{
        config: old_state.config,
        ui_state: %{visible: old_state.ui_visible},
        data: old_state.cached_data
      }

    _ ->
      # No migration needed
      old_state
  end
end
```

### Resource Preservation

```elixir
def prepare_for_reload(state) do
  # Save important data that should survive reload
  persistent_data = %{
    user_selections: state.selected_items,
    cached_results: state.search_cache,
    session_data: state.session_info
  }

  # Store in process dictionary or external storage
  Process.put(:plugin_persistent_data, persistent_data)

  {:ok, state}
end

def restore_after_reload(state) do
  case Process.get(:plugin_persistent_data) do
    nil ->
      state
    persistent_data ->
      Process.delete(:plugin_persistent_data)
      %{state |
        selected_items: persistent_data.user_selections,
        search_cache: persistent_data.cached_results,
        session_info: persistent_data.session_data
      }
  end
end
```

## Plugin System Hooks

### System-Level Hooks

These hooks are called by the Plugin System v2.0:

- **pre_load**: Called before plugin is loaded
- **post_load**: Called after successful plugin load
- **pre_enable**: Called before plugin is enabled
- **post_enable**: Called after plugin is enabled
- **pre_disable**: Called before plugin is disabled
- **post_disable**: Called after plugin is disabled
- **pre_unload**: Called before plugin is unloaded
- **error_occurred**: Called when plugin encounters error

### Hook Implementation

```elixir
# In Plugin System v2.0 configuration
hooks: %{
  pre_load: [&validate_system_requirements/1],
  post_load: [&register_plugin_commands/1],
  error_occurred: [&log_plugin_error/2, &notify_administrators/2]
}

def validate_system_requirements(plugin_manifest) do
  case check_dependencies(plugin_manifest.dependencies) do
    :ok -> :continue
    {:error, missing} -> {:halt, "Missing dependencies: #{inspect(missing)}"}
  end
end
```

## Error Handling Patterns

### Graceful Degradation

```elixir
def handle_command(:complex_operation, args, state) do
  case safe_complex_operation(args, state) do
    {:ok, result, new_state} ->
      {:ok, new_state, result}

    {:error, :network_timeout} ->
      # Fallback to cached data
      cached_result = get_cached_result(args, state)
      {:ok, state, cached_result}

    {:error, reason} ->
      Logger.warning("Operation failed: #{reason}")
      {:error, "Operation temporarily unavailable", state}
  end
end

defp safe_complex_operation(args, state) do
  try do
    result = perform_network_operation(args)
    new_state = update_cache(state, args, result)
    {:ok, result, new_state}
  rescue
    e in RuntimeError ->
      {:error, e.message}
  catch
    :exit, reason ->
      {:error, {:process_exit, reason}}
  end
end
```

### Resource Cleanup

```elixir
def terminate(reason, state) do
  Logger.info("Plugin terminating: #{reason}")

  # Cancel all timers
  state.timers
  |> Enum.each(&:timer.cancel/1)

  # Close files
  state.open_files
  |> Enum.each(&File.close/1)

  # Cleanup network connections
  state.connections
  |> Enum.each(&HTTPoison.close/1)

  # Save important state
  save_plugin_state(state)

  :ok
end
```

## Performance Considerations

### Efficient Event Handling

```elixir
# Fast event filtering with guards
def filter_event({:key_press, key}, state)
    when key in ["j", "k", "h", "l"] do
  # Quick vim key handling
  {:ok, {:key_press, vim_to_arrow(key)}}
end

def filter_event({:key_press, _key}, _state) do
  # Pass through other keys without processing
  {:ok, event}
end

# Avoid expensive operations in event filters
def filter_event({:file_change, path}, state) do
  # Don't process file immediately - schedule async processing
  send(self(), {:process_file_change, path})
  {:ok, {:file_change, path}}
end
```

### State Management Performance

```elixir
# Use efficient data structures
defstruct [
  # Use maps for lookups
  :items_by_id,  # %{id => item}

  # Use lists for ordered data
  :ordered_items,  # [item1, item2, ...]

  # Cache expensive computations
  :cached_results,  # %{query => result}
  :cache_timestamps  # %{query => timestamp}
]

# Batch updates
def update_multiple_items(state, updates) do
  new_items_by_id =
    updates
    |> Enum.reduce(state.items_by_id, fn {id, update}, acc ->
      Map.update(acc, id, update, &merge_update(&1, update))
    end)

  %{state | items_by_id: new_items_by_id}
end
```

## Testing Plugin Lifecycle

### Lifecycle Test Example

```elixir
defmodule MyPluginLifecycleTest do
  use ExUnit.Case
  alias MyPlugin

  describe "plugin lifecycle" do
    test "complete lifecycle works" do
      config = %{enabled: true}

      # Test initialization
      assert {:ok, state} = MyPlugin.init(config)
      assert state.config == config

      # Test enable
      assert {:ok, enabled_state} = MyPlugin.enable(state)
      assert length(enabled_state.timers) > 0

      # Test command handling
      {:ok, new_state, result} = MyPlugin.handle_command(:test_cmd, [], enabled_state)
      assert result == :expected

      # Test disable
      assert {:ok, disabled_state} = MyPlugin.disable(new_state)
      assert disabled_state.timers == []

      # Test termination
      assert :ok = MyPlugin.terminate(:normal, disabled_state)
    end
  end
end
```

This reference covers how plugins interact with the Raxol system throughout their lifecycle.