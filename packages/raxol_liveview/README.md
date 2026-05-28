# Raxol LiveView

Phoenix LiveView integration for Raxol terminal applications.

Render any TEA app in a browser via Phoenix LiveView, with real-time updates over WebSocket. The same `init/1`, `update/2`, `view/1` callbacks work, no code changes needed.

## Install

```elixir
# mix.exs
def deps do
  [{:raxol_liveview, path: "packages/raxol_liveview"}]
end
```

## Modules

| Module | Purpose |
|--------|---------|
| `Raxol.LiveView.TerminalBridge` | Buffer-to-HTML conversion with RLE spans, style-to-CSS, diff highlighting, animation hint to CSS transition generation (`animation_css/1`) |
| `Raxol.LiveView.InputAdapter` | Translates browser keydown events to Raxol Event structs |
| `Raxol.LiveView.TEALive` | Phoenix.LiveView that mounts and runs a TEA app via PubSub |
| `Raxol.LiveView.TerminalComponent` | Phoenix.LiveComponent wrapper for embedding terminals in existing LiveViews |
| `Raxol.LiveView.Themes` | 5 built-in themes (default, light, nord, dracula, synthwave84) with CSS custom properties |

## Usage

Mount a TEA app in a LiveView:

```elixir
defmodule MyAppWeb.TerminalLive do
  use Phoenix.LiveView
  alias Raxol.LiveView.TEALive

  def mount(_params, _session, socket) do
    TEALive.mount(socket, MyApp.Counter)
  end

  def handle_info(msg, socket), do: TEALive.handle_info(msg, socket)
  def handle_event(event, params, socket), do: TEALive.handle_event(event, params, socket)
  def render(assigns), do: TEALive.render(assigns)
end
```

Or embed as a component:

```heex
<.live_component module={Raxol.LiveView.TerminalComponent}
  id="my-terminal"
  app_module={MyApp.Counter}
  theme={:synthwave84} />
```

Include the CSS asset at `priv/static/raxol_terminal.css` in your layout.

## Tests

```bash
cd packages/raxol_liveview && MIX_ENV=test mix test  # 37 tests, 0 failures
```

See [LiveView cookbook](../../docs/cookbook/LIVEVIEW_INTEGRATION.md) for more patterns.
