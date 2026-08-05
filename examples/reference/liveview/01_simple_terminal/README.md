# Simple Terminal LiveView Example

Minimal example showing how to embed a Raxol terminal in Phoenix LiveView.

## Setup

1. **Add Raxol to your dependencies:**

```elixir
# mix.exs
def deps do
  [
    {:raxol, "~> 2.6"}
  ]
end
```

2. **Add CSS to your layout:**

```heex
<!-- lib/my_app_web/components/layouts/root.html.heex -->
<link rel="stylesheet" href={~p"/css/raxol_terminal.css"} />
```

3. **Add JavaScript hooks:**

```javascript
// assets/js/app.js
import RaxolTerminalHooks from "../../deps/raxol/priv/static/js/raxol_terminal_hooks"

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: RaxolTerminalHooks
})
```

4. **Copy the CSS file to your priv/static:**

```bash
cp deps/raxol/priv/static/css/raxol_terminal.css priv/static/css/
```

## Usage

See `simple_terminal_live.ex` for a complete working example.

## Run

```bash
mix phx.server
```

Then visit http://localhost:4000/terminal

## What It Does

- Creates an 80x24 terminal buffer
- Draws a box with title
- Displays a welcome message
- Updates a counter every second

## Next steps

- Add keyboard input handling
- Implement command processing
- Add more interactive features

See `examples/reference/liveview/tea_counter_live.ex` for a full TEA app in the browser.
