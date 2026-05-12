# Raxol Plugin Development Guide

## Overview

Raxol's plugin system allows you to extend terminal functionality with custom features, UI components, and integrations. This guide covers everything you need to know to create powerful plugins for the Raxol terminal emulator.

## Quick Start

### Basic Plugin Structure

```elixir
defmodule YourApp.Plugins.MyPlugin do
  @moduledoc """
  Description of your plugin functionality
  """

  use GenServer
  require Logger

  # Plugin Manifest - Required
  def manifest do
    %{
      name: "my-plugin",
      version: "1.0.0",
      description: "Brief description of plugin functionality",
      author: "Your Name",
      dependencies: %{
        "raxol-core" => "~> 1.5"
      },
      capabilities: [
        :ui_panel,
        :keyboard_input,
        :shell_command
      ],
      config_schema: %{
        hotkey: %{type: :string, default: "ctrl+p"},
        enabled: %{type: :boolean, default: true}
      }
    }
  end

  # Plugin State
  defstruct [
    :config,
    :state_field_1,
    :state_field_2
  ]

  # GenServer implementation
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    state = %__MODULE__{config: config}
    {:ok, state}
  end

  # Handle plugin events
  @impl true
  def handle_call(:some_action, _from, state) do
    {:reply, :ok, state}
  end
end
```

## Core Concepts

### 1. Plugin Manifest

Every plugin must define a `manifest/0` function that returns plugin metadata:

```elixir
def manifest do
  %{
    # Required fields
    name: "unique-plugin-name",           # Unique identifier (kebab-case)
    version: "1.0.0",                     # Semantic version
    description: "What this plugin does", # User-friendly description
    author: "Plugin Author",              # Author information

    # Dependencies
    dependencies: %{
      "raxol-core" => "~> 1.5",          # Required Raxol version
      "other-plugin" => "~> 2.0"         # Optional plugin dependencies
    },

    # Capabilities - what the plugin can do
    capabilities: [
      :ui_panel,        # Can render UI panels
      :keyboard_input,  # Handles keyboard events
      :shell_command,   # Can execute shell commands
      :file_system,     # Accesses file system
      :file_watcher,    # Watches file changes
      :status_line,     # Contributes to status line
      :theme_provider   # Provides color themes
    ],

    # Configuration schema
    config_schema: %{
      field_name: %{
        type: :string,           # :string, :integer, :boolean, :list, :map
        default: "default_value", # Default value
        description: "Field purpose", # User documentation
        required: false,         # Whether field is required
        enum: ["opt1", "opt2"]   # Valid options (optional)
      }
    }
  }
end
```

### 2. Plugin State Management

Use a struct to define your plugin's internal state:

```elixir
defstruct [
  :config,           # Plugin configuration from user
  :ui_state,         # UI-related state
  :data,             # Plugin-specific data
  :timers,           # Active timers
  :subscriptions     # Event subscriptions
]
```

### 3. GenServer Lifecycle

Plugins are implemented as GenServers for state management and concurrency:

```elixir
@impl true
def init(config) do
  # Initialize plugin state
  state = %__MODULE__{
    config: config,
    data: load_initial_data()
  }

  # Set up timers, subscriptions, etc.
  timer = :timer.send_interval(config.refresh_interval, :refresh)

  {:ok, %{state | timers: [timer]}}
end

@impl true
def terminate(_reason, state) do
  # Clean up resources
  Enum.each(state.timers, &:timer.cancel/1)
  :ok
end
```

## Plugin Capabilities

### UI Panel Capability

Render custom UI panels within the terminal:

```elixir
def render_panel(state, width, height) do
  # Return list of rendered lines
  lines = [
    %{
      text: "Panel Header",
      style: TextFormatting.new() |> TextFormatting.apply_attribute(:bold)
    },
    %{
      text: "Content line 1",
      style: TextFormatting.new()
    }
  ]

  # Ensure we return exactly 'height' lines
  lines
  |> Enum.take(height)
  |> pad_to_height(height, width)
end

# Helper function to pad lines to required height
defp pad_to_height(lines, height, width) do
  empty_line = %{
    text: String.pad_trailing("", width),
    style: TextFormatting.new()
  }

  current_count = length(lines)
  if current_count < height do
    lines ++ List.duplicate(empty_line, height - current_count)
  else
    lines
  end
end
```

### Keyboard Input Capability

Handle keyboard events and shortcuts:

```elixir
def handle_keypress(key, state) do
  case key do
    "enter" ->
      # Handle enter key
      execute_action(state)

    "escape" ->
      # Handle escape
      %{state | ui_state: :closed}

    "j" ->
      # Vim-style navigation
      move_cursor_down(state)

    "k" ->
      move_cursor_up(state)

    _ ->
      state  # Ignore other keys
  end
end

# Register hotkeys in manifest
config_schema: %{
  hotkey: %{type: :string, default: "ctrl+p"},
  toggle_key: %{type: :string, default: "f2"}
}
```

### Shell Command Capability

Execute shell commands safely:

```elixir
def execute_command(command, args, working_dir) do
  case System.cmd(command, args, cd: working_dir, stderr_to_stdout: true) do
    {output, 0} ->
      {:ok, output}

    {error, exit_code} ->
      Logger.error("Command failed with exit code #{exit_code}: #{error}")
      {:error, {exit_code, error}}
  end
end

# Example: Git integration
defp get_git_status(repo_path) do
  case execute_command("git", ["status", "--porcelain"], repo_path) do
    {:ok, output} -> parse_git_status(output)
    {:error, _} -> []
  end
end
```

### File System Capability

Access and monitor file system changes:

```elixir
def list_directory(path) do
  case File.ls(path) do
    {:ok, entries} ->
      entries
      |> Enum.map(&get_file_info(Path.join(path, &1)))
      |> Enum.sort_by(& &1.name)

    {:error, reason} ->
      Logger.error("Failed to list directory #{path}: #{reason}")
      []
  end
end

defp get_file_info(path) do
  stat = File.stat!(path)

  %{
    name: Path.basename(path),
    path: path,
    type: if(stat.type == :directory, do: :directory, else: :file),
    size: stat.size,
    modified: stat.mtime
  }
end
```

### Status Line Capability

Contribute information to the status line:

```elixir
def status_line_info(state) do
  case state.data do
    nil -> ""
    data ->
      # Return string to display in status line
      "#{data.branch} +#{data.changes}"
  end
end

# Status line integration happens automatically
# Your string will be included in the status line display
```

## Advanced Features

### Real-time Updates

Use timers and GenServer messages for real-time updates:

```elixir
@impl true
def init(config) do
  # Set up periodic refresh
  timer = :timer.send_interval(config.refresh_interval || 1000, :refresh)

  state = %__MODULE__{
    config: config,
    refresh_timer: timer
  }

  {:ok, state}
end

@impl true
def handle_info(:refresh, state) do
  # Refresh plugin data
  updated_state = refresh_data(state)
  {:noreply, updated_state}
end
```

### File Watching

Monitor file system changes:

```elixir
def start_file_watcher(path, state) do
  # This would integrate with Raxol's file watching system
  # Implementation depends on the underlying file watcher
  watcher = FileWatcher.watch(path, self())
  %{state | file_watcher: watcher}
end

@impl true
def handle_info({:file_event, path, events}, state) do
  # Handle file change events
  updated_state = handle_file_change(path, events, state)
  {:noreply, updated_state}
end
```

### Inter-Plugin Communication

Communicate with other plugins:

```elixir
# Send message to another plugin
def notify_other_plugin(message) do
  GenServer.cast(OtherPlugin, {:notification, message})
end

# Handle messages from other plugins
@impl true
def handle_cast({:notification, message}, state) do
  # Process notification
  updated_state = process_notification(message, state)
  {:noreply, updated_state}
end
```

## Styling and Theming

### Text Formatting

Use `Raxol.Terminal.ANSI.TextFormatting` for rich text:

```elixir
alias Raxol.Terminal.ANSI.TextFormatting

# Create formatted text
def format_text(text, options \\ []) do
  style = TextFormatting.new()

  style = if options[:bold], do: TextFormatting.apply_attribute(style, :bold), else: style
  style = if options[:color], do: TextFormatting.set_foreground(style, options[:color]), else: style
  style = if options[:bg], do: TextFormatting.set_background(style, options[:bg]), else: style

  %{text: text, style: style}
end

# Common styling patterns
def success_text(text), do: format_text(text, color: :green, bold: true)
def error_text(text), do: format_text(text, color: :red, bold: true)
def warning_text(text), do: format_text(text, color: :yellow)
def muted_text(text), do: format_text(text, color: :gray)
```

### Color Schemes

Support different color themes:

```elixir
def get_color_scheme(theme \\ :default) do
  case theme do
    :default -> %{
      primary: :blue,
      secondary: :cyan,
      success: :green,
      warning: :yellow,
      error: :red,
      muted: :gray
    }

    :dark -> %{
      primary: :bright_blue,
      secondary: :bright_cyan,
      success: :bright_green,
      warning: :bright_yellow,
      error: :bright_red,
      muted: :gray
    }
  end
end
```

## Plugin Examples

### File Browser Plugin

```elixir
defmodule Raxol.Plugins.Examples.FileBrowserPlugin do
  use GenServer

  def manifest do
    %{
      name: "file-browser",
      version: "1.0.0",
      description: "Tree-style file browser",
      author: "Raxol Team",
      dependencies: %{"raxol-core" => "~> 1.5"},
      capabilities: [:file_system, :ui_panel, :keyboard_input],
      config_schema: %{
        initial_path: %{type: :string, default: "."},
        show_hidden: %{type: :boolean, default: false},
        hotkey: %{type: :string, default: "ctrl+b"}
      }
    }
  end

  defstruct [:config, :current_path, :entries, :selected_index]

  # Implementation...
end
```

### Git Integration Plugin

```elixir
defmodule Raxol.Plugins.Examples.GitPlugin do
  use GenServer

  def manifest do
    %{
      name: "git-integration",
      version: "1.0.0",
      description: "Git repository management",
      author: "Raxol Team",
      dependencies: %{"raxol-core" => "~> 1.5"},
      capabilities: [:shell_command, :ui_panel, :status_line, :file_watcher],
      config_schema: %{
        auto_refresh: %{type: :boolean, default: true},
        refresh_interval: %{type: :integer, default: 2000}
      }
    }
  end

  # Implementation with git commands, status monitoring, etc.
end
```

## Testing Plugins

### Basic Test Structure

```elixir
defmodule MyPluginTest do
  use ExUnit.Case, async: true

  alias MyApp.Plugins.MyPlugin

  describe "plugin manifest" do
    test "returns valid manifest" do
      manifest = MyPlugin.manifest()

      assert is_binary(manifest.name)
      assert is_binary(manifest.version)
      assert is_list(manifest.capabilities)
    end
  end

  describe "plugin functionality" do
    setup do
      config = %{enabled: true, hotkey: "ctrl+p"}
      {:ok, pid} = MyPlugin.start_link(config)

      on_exit(fn -> GenServer.stop(pid) end)

      {:ok, plugin: pid, config: config}
    end

    test "handles basic operations", %{plugin: plugin} do
      result = GenServer.call(plugin, :some_operation)
      assert result == :expected_result
    end
  end
end
```

### Integration Testing

```elixir
defmodule MyPluginIntegrationTest do
  use ExUnit.Case

  import Raxol.Test.PluginTestHelpers

  test "plugin integrates with terminal" do
    # Set up test terminal
    {:ok, terminal} = start_test_terminal()

    # Load plugin
    {:ok, _plugin} = load_plugin(terminal, MyPlugin, %{})

    # Test plugin functionality
    send_keypress(terminal, "ctrl+p")

    # Assert expected behavior
    assert_panel_visible(terminal, "my-plugin")
  end
end
```

## Plugin Distribution

### Plugin Package Structure

```
my_plugin/
├── mix.exs
├── lib/
│   └── my_plugin.ex
├── test/
│   └── my_plugin_test.exs
├── README.md
├── CHANGELOG.md
└── plugin.json
```

### Plugin Metadata (plugin.json)

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "Plugin description",
  "author": "Author Name",
  "repository": "https://github.com/author/my-plugin",
  "license": "MIT",
  "raxol_version": "~> 1.5",
  "keywords": ["terminal", "productivity"],
  "screenshots": [
    "screenshots/main.png",
    "screenshots/config.png"
  ]
}
```

### Publishing to Plugin Marketplace

```bash
# Package plugin
mix raxol.plugin.package

# Publish to marketplace
mix raxol.plugin.publish --token YOUR_API_TOKEN
```

## Best Practices

### 1. Error Handling

```elixir
def safe_operation(state) do
  try do
    result = dangerous_operation(state)
    {:ok, result}
  rescue
    error ->
      Logger.error("Plugin operation failed: #{inspect(error)}")
      {:error, error}
  end
end
```

### 2. Resource Management

```elixir
@impl true
def init(config) do
  # Always clean up resources in terminate/2
  state = %__MODULE__{config: config, resources: []}
  {:ok, state}
end

@impl true
def terminate(_reason, state) do
  # Clean up all resources
  Enum.each(state.resources, &cleanup_resource/1)
  :ok
end
```

### 3. Configuration Validation

```elixir
def validate_config(config) do
  required_fields = [:api_key, :endpoint]

  case check_required_fields(config, required_fields) do
    :ok -> {:ok, config}
    {:error, missing} -> {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
  end
end
```

### 4. User Experience

- Provide clear error messages
- Use consistent keyboard shortcuts
- Implement loading states for slow operations
- Support theming and customization
- Include helpful documentation

### 5. Performance

- Use GenServer for state management
- Implement efficient rendering
- Cache expensive operations
- Use background tasks for heavy work
- Minimize file system access

## Debugging Plugins

### Logging

```elixir
require Logger

def debug_operation(state) do
  Logger.debug("Plugin operation started with state: #{inspect(state)}")

  result = perform_operation(state)

  Logger.debug("Plugin operation completed: #{inspect(result)}")

  result
end
```

### Development Tools

```bash
# Start Raxol in development mode with plugin debugging
mix raxol.dev --debug-plugins

# Watch plugin files for changes
mix raxol.dev --watch lib/plugins/

# Plugin-specific logs
mix raxol.dev --log-level debug --filter "plugin:my-plugin"
```

## FAQ

**Q: Can plugins communicate with external APIs?**
A: Yes, plugins can make HTTP requests and communicate with external services. Use libraries like HTTPoison or Finch.

**Q: How do I handle plugin configuration?**
A: Define a `config_schema` in your manifest and access user configuration through the `config` parameter in `init/1`.

**Q: Can plugins modify terminal settings?**
A: Plugins can request capabilities like theme changes or keybinding modifications, but these require user permission.

**Q: How do I distribute private plugins?**
A: You can load plugins directly from local paths or private git repositories using `mix raxol.plugin.install`.

**Q: Are plugins sandboxed?**
A: Yes, plugins run in isolated processes and only have access to capabilities they declare in their manifest.

## Getting Help

- Documentation: [https://docs.raxol.io/plugins](https://docs.raxol.io/plugins)
- Examples: [https://github.com/raxol-io/plugin-examples](https://github.com/raxol-io/plugin-examples)
- Community: [https://discord.gg/raxol](https://discord.gg/raxol)
- Issues: [https://github.com/raxol-io/raxol/issues](https://github.com/raxol-io/raxol/issues)