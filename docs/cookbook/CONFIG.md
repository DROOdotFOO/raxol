# TOML Configuration

Raxol uses TOML files for configuration, managed by `Raxol.Config` (backed by UnifiedConfigManager with BaseManager pattern). It supports environment-specific overrides, runtime updates, validation, hot-reload, and sensible defaults.

## File Structure

```bash
config/
├── raxol.toml                    # Main config (you create this; copy from the example)
├── raxol.example.toml            # All options documented
└── environments/
    ├── development.toml          # Dev overrides
    └── production.toml           # Production overrides
```

Test settings live in `config/test.exs`, not a TOML file.

### Loading Order

1. `config/raxol.toml` -- base
2. `config/environments/{env}.toml` -- environment overrides
3. Runtime overrides via `Config.set/2`

Later values win.

## Full Schema

```toml
# Terminal
[terminal]
width = 80
height = 24
scrollback_size = 10000
encoding = "UTF-8"
bell = true

[terminal.cursor]
style = "block"          # block, underline, bar
blink = true
blink_rate = 500         # ms

[terminal.colors]
palette = "default"      # default, solarized, dracula, nord
true_color = true

# Buffer
[buffer]
max_size = 1048576       # 1MB
chunk_size = 4096
compression = false
compression_threshold = 10240

# Rendering
[rendering]
fps_target = 60
max_frame_skip = 3
enable_animations = true
animation_duration = 200  # ms
performance_mode = false
gpu_acceleration = true

# Plugins
[plugins]
enabled = true
directory = "plugins"
auto_reload = false
allowed = []             # empty = all allowed
disabled = []
load_timeout = 5000      # ms

# Security
[security]
session_timeout = 1800   # 30 minutes
max_sessions = 5
enable_audit = true
password_min_length = 8
password_require_special = true
password_require_numbers = true
enable_2fa = false

[security.rate_limiting]
enabled = true
window = 60000           # 1 minute
max_requests = 100

# Performance
[performance]
profiling_enabled = false
benchmark_on_start = false
cache_size = 100000
cache_ttl = 300000       # 5 minutes
worker_pool_size = 4

# Theme
[theme]
name = "default"
auto_switch = false
custom_themes_dir = "themes"

# Logging
[logging]
level = "info"           # debug, info, warning, error
file = "logs/raxol.log"
max_file_size = 10485760 # 10MB
rotation_count = 5
format = "text"          # text, json
include_metadata = true

# Accessibility
[accessibility]
screen_reader = false
high_contrast = false
focus_indicators = true
reduce_motion = false
font_scaling = 1.0

# Keybindings
[keybindings]
enabled = true
config_file = "keybindings.toml"
vim_mode = false
emacs_mode = false
```

## API

### Starting

The config server starts automatically via `Raxol.Application`:

```elixir
children = [
  {Raxol.Config, [config_file: "config/raxol.toml"]},
  # ...
]
```

### Reading Values

```elixir
width = Raxol.Config.get([:terminal, :width])
# => 80

bg_color = Raxol.Config.get([:terminal, :background], default: "#000000")

terminal_config = Raxol.Config.get([:terminal])
# => %{"width" => 80, "height" => 24, ...}

all_config = Raxol.Config.all()
```

### Writing Values at Runtime

```elixir
Raxol.Config.set([:terminal, :width], 120)

Raxol.Config.set([:rendering], %{
  "fps_target" => 120,
  "gpu_acceleration" => true
})
```

### Loading and Reloading

```elixir
{:ok, config} = Raxol.Config.load_file("config/custom.toml")
:ok = Raxol.Config.reload()
```

### Validation

```elixir
case Raxol.Config.validate() do
  {:ok, :valid} ->
    IO.puts("Configuration is valid")

  {:error, errors} ->
    Enum.each(errors, &IO.puts("  - #{&1}"))
end
```

### Exporting

```elixir
:ok = Raxol.Config.export("config/current.toml")
```

## Environment Overrides

### Development

```toml
[logging]
level = "debug"
include_metadata = true

[performance]
profiling_enabled = true

[plugins]
auto_reload = true

[rendering]
performance_mode = false
```

### Test

```toml
[terminal]
width = 80
height = 24
scrollback_size = 100

[logging]
level = "warning"
file = "logs/test.log"

[performance]
profiling_enabled = false
worker_pool_size = 2
```

### Production

```toml
[logging]
level = "warning"
format = "json"

[performance]
cache_size = 1000000
worker_pool_size = 8

[rendering]
performance_mode = true
gpu_acceleration = true

[security]
enable_audit = true
enable_2fa = true
```

## Integration Examples

```elixir
# Terminal emulator
defmodule MyTerminal do
  def init do
    width = Raxol.Config.get([:terminal, :width])
    height = Raxol.Config.get([:terminal, :height])
    Raxol.Terminal.Emulator.new(width, height)
  end
end

# Rendering pipeline
defmodule MyRenderer do
  def render(buffer) do
    fps_target = Raxol.Config.get([:rendering, :fps_target])
    frame_time = 1000 / fps_target
    do_render(buffer, frame_time)
  end
end

# Plugin loader
defmodule PluginLoader do
  def load_plugins do
    if Raxol.Config.get([:plugins, :enabled]) do
      dir = Raxol.Config.get([:plugins, :directory])
      auto_reload = Raxol.Config.get([:plugins, :auto_reload])
      load_from_directory(dir, auto_reload: auto_reload)
    end
  end
end
```

## Watching for Changes

```elixir
defmodule ConfigWatcher do
  use GenServer

  def init(state) do
    Process.send_after(self(), :check_config, 1000)
    {:ok, state}
  end

  def handle_info(:check_config, state) do
    new_value = Raxol.Config.get([:my, :setting])

    state = if new_value != state.current_value do
      handle_config_change(new_value)
      %{state | current_value: new_value}
    else
      state
    end

    Process.send_after(self(), :check_config, 1000)
    {:noreply, state}
  end
end
```

## Validation Rules

Built-in validation covers:

- Terminal dimensions -- must be positive integers
- Performance settings -- cache size, worker pool size must be positive
- Security settings -- session timeout, max sessions must be positive

Extend validation by modifying `validate_config/1` in `Raxol.Config`.

## Best Practices

**Keep env-specific values out of the main config.** Put them in `environments/*.toml`.

**Document options.** Maintain `raxol.example.toml` with comments:

```toml
# Frame rate target for rendering
# Higher values = smoother animation but more CPU
# Default: 60
fps_target = 60
```

**Always provide defaults in code:**

```elixir
timeout = Raxol.Config.get([:network, :timeout], default: 5000)
```

**Group related settings** with nested tables:

```toml
[network]
timeout = 5000
retries = 3

[network.pool]
size = 10
overflow = 5
```

## Migrating from Application.get_env

Before:

```elixir
width = Application.get_env(:raxol, :terminal_width, 80)
```

After:

```elixir
width = Raxol.Config.get([:terminal, :width], default: 80)
```

Before (`config/config.exs`):

```elixir
config :raxol,
  terminal_width: 80,
  terminal_height: 24
```

After (`config/raxol.toml`):

```toml
[terminal]
width = 80
height = 24
```

## Troubleshooting

**Config server not started:** Make sure `{Raxol.Config, []}` is in your supervision tree.

**Invalid TOML syntax:**

```bash
mix run -e "File.read!('config/raxol.toml') |> Toml.decode!()"
```

**Missing config values:** Always use defaults:

```elixir
value = Raxol.Config.get([:section, :key], default: "fallback")
```

**Performance:** Config values are cached in memory. Keep files under 1MB and avoid storing large data blobs -- use references to external files instead.
