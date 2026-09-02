# Quickstart

A counter app, running in your terminal, using the four callbacks every Raxol
app implements.

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
  [{:raxol, "~> 2.6"}]
end
```

## Headless / CI setup

The tutorial app below needs a real terminal, but building and testing Raxol
does not. Prerequisites: Elixir/OTP (versions in the repo's `mise.toml`)
and a C toolchain for the termbox2 NIF (`make` + `cc`; on Debian/Ubuntu,
`apt-get install build-essential`). From a fresh clone:

```bash
mix local.hex --force        # fresh machines and CI: install Hex without a prompt
mix deps.get
mix compile                  # builds the termbox2 NIF
SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test --exclude slow --exclude integration --exclude docker
MIX_ENV=test mix raxol.rate  # RATE: render-determinism golden suite
```

`SKIP_TERMBOX2_TESTS=true` excludes the tests that need a real local terminal;
CI sets the same variable. Plain `mix test` without the exclude flags also
runs integration suites that need external services (PostgreSQL for the
workflow checkpoint tests), so stick to the command above. If `HOME` is
read-only in your sandbox, point `MIX_HOME` and `HEX_HOME` at a writable
directory first.

## Your first app

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
        {model, [Directive.stop()]}

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

- `init/1` returns a plain map, which is your entire app state
- `update/2` pattern-matches on messages and returns `{new_state, commands}`. The empty list `[]` means "no side effects"
- `view/1` builds the UI from state using the View DSL macros (`column`, `row`, `box`)
- `Directive.stop()` tells the runtime to shut down (the `Directive` alias comes from `use Raxol.Core.Runtime.Application`)

Save as `lib/my_app.ex` and run:

```bash
mix run lib/my_app.ex
```

## How it works

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
2. `view/1` renders the UI; it's called after every state change
3. `update/2` handles messages (keyboard events, button clicks, timers)
4. `subscribe/1` sets up recurring events (timers, external data)

State flows in one direction. Views are pure functions of state. Side effects go through commands.

## View DSL

The View DSL provides macros for building layouts:

```elixir
# Layout containers
column style: %{gap: 1} do ... end    # Vertical stack
row style: %{gap: 2} do ... end        # Horizontal stack

# Components
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

## Adding live updates

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

## If the terminal is left in a bad state

A Raxol app puts your terminal into raw mode, and full-screen apps also switch to
the alternate screen. Both get restored on the way out. But if the app dies hard,
a `kill -9` or a VM crash, nothing runs that restore and you land back in a shell
with no echo and no line editing.

Nothing is broken. Reset it:

```bash
reset
```

If you cannot see what you are typing, that still works blind. Type it and hit
Enter. `stty sane` is the lighter version, and it fixes echo without clearing the
screen.

vim and tmux leave the same mess when you SIGKILL them. It comes with the
territory for full-screen terminal programs. [Why OTP](../WHY_OTP.md#crash-isolation)
covers what can take the VM down that way in the first place.

## Where to go next

That counter is a complete Raxol app. `init/update/view` is the whole API, and
everything else builds on this loop.

- [Component Gallery](COMPONENT_GALLERY.md): all Components with examples
- [Core Concepts](CORE_CONCEPTS.md): buffers, the rendering pipeline, and how they fit together
- [Building Apps](../cookbook/BUILDING_APPS.md): state machines, scrollable lists, keyboard shortcuts

`mix raxol.playground` browses 40 Component demos interactively, with search and
filtering.

### Things to try

**SSH serving.** Serve your app over SSH. Each connection gets its own process:

```bash
mix run examples/ssh/ssh_counter.exs
# Then: ssh localhost -p 2222
```

**Hot code reload.** Edit your view function while the app is running:

```bash
iex -S mix run examples/dev/hot_reload_demo.exs
# Edit the view/1 function and save; UI updates automatically
```

**Crash isolation.** Components run in separate processes. One crash doesn't take down the app:

```bash
mix run examples/components/process_component_demo.exs
```

Working examples to study:

- `examples/getting_started/counter.exs`: the counter from this page
- `examples/demo.exs`: flagship demo with dashboard, sparklines, live stats
- `examples/getting_started/todo_app.exs`: a keyboard-driven todo list app
