# Quickstart Guide

Let's build a raxol app. By the end of this page you'll have a working counter running in your terminal.

What you'll learn:

- The four callbacks every Raxol app implements
- How to handle keyboard input and button clicks
- How the View DSL builds layouts

## Install

Generate a new project:

```bash
mix raxol.new my_app
cd my_app
mix deps.get
```

Or add to an existing project:

```elixir
# mix.exs
def deps do
  [{:raxol, "~> 2.4"}]
end
```

## Your First App

Every Raxol app follows The Elm Architecture (TEA) with four callbacks:

```elixir
defmodule MyApp do
  use Raxol.Core.Runtime.Application

  # 1. Initialize state
  @impl true
  def init(_context) do
    %{count: 0}
  end

  # 2. Handle messages
  @impl true
  def update(message, model) do
    case message do
      :increment ->
        {%{model | count: model.count + 1}, []}

      :decrement ->
        {%{model | count: model.count - 1}, []}

      # Keyboard events
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "="}} ->
        {%{model | count: model.count + 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "-"}} ->
        {%{model | count: model.count - 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [command(:quit)]}

      _ ->
        {model, []}
    end
  end

  # 3. Render UI from state
  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1, align_items: :center} do
      [
        text("My Counter", style: [:bold]),
        box style: %{border: :single, padding: 1, width: 20, justify_content: :center} do
          text("Count: #{model.count}", style: [:bold])
        end,
        row style: %{gap: 1} do
          [
            button("=", on_click: :increment),
            button("-", on_click: :decrement)
          ]
        end,
        text("Press =/- or click buttons. q to quit.", style: [:dim])
      ]
    end
  end

  # 4. Subscriptions (optional)
  @impl true
  def subscribe(_model), do: []
end

# Start the app
{:ok, pid} = Raxol.start_link(MyApp, [])
ref = Process.monitor(pid)
receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
```

**What's happening here?**

- `init/1` returns a plain map -- that's your entire app state
- `update/2` pattern-matches on messages and returns `{new_state, commands}` -- the empty list `[]` means "no side effects"
- `view/1` builds the UI from state using the View DSL macros (`column`, `row`, `box`)
- `command(:quit)` is a built-in command that tells the runtime to shut down

Save as `lib/my_app.ex` and run:

```bash
mix run lib/my_app.ex
```

## How It Works

```
                +---> view(model) ---> Terminal
                |
init(context) --+--> model
                |
                +---> update(message, model) --+
                      ^                        |
                      |    {new_model, cmds}   |
                      +------------------------+
```

1. `init/1` sets up your initial state (the "model")
2. `view/1` renders the UI -- it's called after every state change
3. `update/2` handles messages (keyboard events, button clicks, timers)
4. `subscribe/1` sets up recurring events (timers, external data)

State flows in one direction. Views are pure functions of state. Side effects go through commands.

## View DSL

The View DSL provides macros for building layouts:

```elixir
# Layout containers
column style: %{gap: 1} do ... end    # Vertical stack
row style: %{gap: 2} do ... end        # Horizontal stack

# Widgets
text("Hello", style: [:bold])          # Text with styling
button("Click", on_click: :msg)        # Clickable button
text_input(value: v, placeholder: "")  # Text input
progress(value: 65, max: 100)          # Progress bar

# Containers
box style: %{border: :single, padding: 1} do ... end  # Bordered box

# Utilities
divider()                              # Horizontal line
spacer()                               # Flexible space
```

## Adding Live Updates

Use `subscribe/1` to get periodic messages:

```elixir
@impl true
def subscribe(_model) do
  [subscribe_interval(1000, :tick)]  # Send :tick every second
end

@impl true
def update(:tick, model) do
  {%{model | uptime: model.uptime + 1}, []}
end
```

## OTP Supervision

Use `--sup` when generating to get a proper OTP application:

```bash
mix raxol.new my_app --sup
```

This generates an Application module with a supervision tree. Run with:

```bash
mix run --no-halt
```

## What You Just Built

That counter is a complete Raxol app -- `init/update/view` is the whole API. Everything else builds on this loop.

Try `mix raxol.playground` for an interactive catalog of 30 widget demos you can browse, search, and filter. It's the fastest way to see what's available.

**Next steps:**

- [Widget Gallery](WIDGET_GALLERY.md) -- All widgets with examples
- [Core Concepts](CORE_CONCEPTS.md) -- Buffers, rendering pipeline, and how it all fits together
- [Building Apps](../cookbook/BUILDING_APPS.md) -- Patterns for real apps (state machines, scrollable lists, keyboard shortcuts)

### Explore Further

These features set Raxol apart:

**SSH App Serving** -- Serve your app over SSH. Each connection gets its own process:

```bash
mix run examples/ssh/ssh_counter.exs
# Then: ssh localhost -p 2222
```

**Hot Code Reload** -- Edit your view function while the app is running:

```bash
iex -S mix run examples/dev/hot_reload_demo.exs
# Edit the view/1 function and save -- UI updates automatically
```

**Crash Isolation** -- Components run in separate processes. One crash doesn't take down the app:

```bash
mix run examples/components/process_component_demo.exs
```

Working examples to study:

- `examples/getting_started/counter.exs` -- the counter from this page
- `examples/demo.exs` -- flagship demo with dashboard, sparklines, live stats
- `examples/apps/todo_app.ex` -- a complete todo list app
