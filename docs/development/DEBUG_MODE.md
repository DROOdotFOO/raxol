# Debug Mode

`Raxol.Debug` provides runtime debugging with four verbosity levels, performance monitoring, and structured logging. It integrates with BaseManager and supports timer management.

## Debug levels

| Level | What it does | When to use |
|-------|-------------|-------------|
| `:off` | Nothing | Production |
| `:basic` | Essential logs | General dev work |
| `:detailed` | Verbose logs with metadata | Troubleshooting |
| `:verbose` | Everything, including perf metrics | Performance analysis |

## Quick start

```elixir
Raxol.Debug.enable(:basic)
Raxol.Debug.enable(:detailed)
Raxol.Debug.enable(:verbose)
Raxol.Debug.disable()
```

### Component-Specific

```elixir
if Raxol.Debug.debug_enabled?(:terminal) do
  IO.inspect(state, label: "Terminal State")
end

# Components by level:
# :basic    -> [:terminal, :web]
# :detailed -> [:terminal, :web, :benchmark, :parser]
# :verbose  -> all
```

## Logging

### Basic

```elixir
Raxol.Debug.debug_log(:terminal, "Processing input",
  context: %{key: key, modifiers: modifiers})

Raxol.Debug.debug_log(:parser, "ANSI sequence detected",
  context: %{sequence: sequence},
  metadata: [session_id: session_id])
```

### Structured

```elixir
Raxol.Debug.log_terminal_state(emulator, metadata: [label: "after input"])
Raxol.Debug.log_ansi_sequence(sequence,
  %{type: :csi, params: [31], final: ?m},
  metadata: [line: 42])
Raxol.Debug.log_event_flow(:key_press, event_data, handler_result,
  metadata: [component: :input_handler])

Raxol.Debug.log_render_metrics(%{
  frame_time_us: 16_000,
  dirty_regions: [{0, 0, 10, 5}, {20, 8, 12, 3}, {0, 22, 80, 2}],
  buffer_size: 1024,
  operations_count: 42
})
```

## Profiling

### Timing

```elixir
result = Raxol.Debug.time_debug(:terminal, "render", fn ->
  render_terminal(buffer)
end)
# Output: [DEBUG] terminal - render completed in 15.3ms
```

## Advanced

### Process state dump

```elixir
Raxol.Debug.dump_process_state(:terminal)
# Shows: memory, reductions, message queue, stacktrace, linked processes
```

### Breakpoints

```elixir
Raxol.Debug.debug_breakpoint(:terminal, "Before state mutation")
# In IEx, pauses and waits for Enter
```

### Performance monitoring

At `:detailed` or `:verbose` levels, metrics are collected every 100ms automatically:
```
[DEBUG] Performance: memory=%{total: 104857600, processes: 52428800, ...}
[DEBUG] Performance: run_queue=0
```

### Inspecting configuration

```elixir
Raxol.Debug.debug_config()
# => %{terminal: true, web: true, benchmark: false, parser: false,
#      rendering: false, general: false, log_level: :debug}

Raxol.Debug.get_debug_level()
# => :detailed
```

Toggle a single component at runtime with `enable_debug/1` and `disable_debug/1`:

```elixir
Raxol.Debug.enable_debug(:terminal)
Raxol.Debug.disable_debug(:terminal)
```

## Configuration

### TOML

```toml
[debug]
level = "detailed"          # off, basic, detailed, verbose
max_logs = 10000
max_traces = 5000
performance_sampling = 100  # ms
```

### Runtime

```elixir
level = Raxol.Config.get([:debug, :level], default: "off")
|> String.to_atom()
Raxol.Debug.enable(level)
```

### Environment variable

```bash
DEBUG_LEVEL=verbose iex -S mix
```

```elixir
debug_level = System.get_env("DEBUG_LEVEL", "off") |> String.to_atom()
Raxol.Debug.enable(debug_level)
```

## Usage examples

### Development workflow

```elixir
defmodule MyModule do
  def process_input(input) do
    Raxol.Debug.debug_log(:input, "Received input",
      context: %{input: input})

    result = Raxol.Debug.time_debug(:input, "processing", fn ->
      do_process(input)
    end)

    Raxol.Debug.debug_log(:input, "Processed successfully",
      context: %{result: result})

    result
  end
end
```

### Terminal troubleshooting

```elixir
Raxol.Debug.enable(:verbose)

emulator
|> process_input("\e[31mRed\e[0m")
|> tap(fn state ->
  Raxol.Debug.log_terminal_state(state, metadata: [label: "after color change"])
  Raxol.Debug.log_ansi_sequence("\e[31m", %{type: :sgr, params: [31], final: ?m})
end)
```

### Performance analysis

```elixir
Raxol.Debug.enable(:verbose)

for _ <- 1..100 do
  Raxol.Debug.time_debug(:benchmark, "render", fn ->
    render_frame(buffer)
  end)
end
```

Each `time_debug/3` call logs its own timing line at `:verbose` level, so the durations show up inline in the log stream.

## Removing debug code in production

Use a module attribute to capture the environment at compile time (calling `Mix.env()` in a function body will crash in releases):

```elixir
defmodule MyModule do
  @debug_enabled Mix.env() != :prod

  if @debug_enabled do
    defp debug_log(message) do
      Raxol.Debug.debug_log(:my_module, message)
    end
  else
    defp debug_log(_message), do: :ok
  end
end
```

## Logger integration

| Debug Level | Logger Level | Metadata |
|-------------|-------------|----------|
| `:off` | `:info` | Standard |
| `:basic` | `:debug` | Standard |
| `:detailed` | `:debug` | `[:module, :function, :line, :pid]` |
| `:verbose` | `:debug` | All metadata |

## Performance impact

| Level | CPU | Memory |
|-------|-----|--------|
| `:off` | None | None |
| `:basic` | ~1-2% | Minimal |
| `:detailed` | ~5-10% | ~1MB for logs |
| `:verbose` | ~15-20% | ~5MB for logs and traces |

## Best practices

Guard expensive debug operations behind level checks:
```elixir
if Raxol.Debug.debug_enabled?(:my_component) do
  expensive_debug_operation()
end
```

Use structured context, not string interpolation:
```elixir
# good
Raxol.Debug.debug_log(:handler, "Event processed",
  context: %{event_type: :key_press, key: "a", modifiers: [:ctrl]})

# bad
Raxol.Debug.debug_log(:handler,
  "Event processed: key_press a with ctrl at #{DateTime.utc_now()}")
```

Turn debug mode back off when you are done:
```elixir
Raxol.Debug.disable()
```

For hot paths, sample instead of logging everything:
```elixir
if :rand.uniform() < 0.1 do
  Raxol.Debug.debug_log(:hot_path, "Sampled execution")
end
```

## Troubleshooting

**Debug server not started:** Add `{Raxol.Debug, []}` to your supervision tree.

**Too many logs:** Limit in-process storage with `{Raxol.Debug, [max_logs: 1000, max_traces: 500]}`.

**Performance impact too high:** Use sampling (see above) or drop to a lower debug level.
