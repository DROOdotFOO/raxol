# Raxol LiveView

Phoenix LiveView integration for Raxol terminal applications.

Render any TEA app in a browser via Phoenix LiveView, with real-time updates over WebSocket. The same `init/1`, `update/2`, `view/1` callbacks work, no code changes needed.

## Install

```elixir
# mix.exs
def deps do
  [{:raxol_liveview, "~> 2.8"}]
end
```

Web hosts must use Plug 1.20.4 or newer on the 1.20 branch and a patched
LiveView branch: 1.0.20+, 1.1.34+, or 1.2.14+ (within each minor).
LiveView 0.20 is no longer supported because no fix is published for its
`live_session` hook bypass
([EEF-CVE-2026-126334](https://cna.erlef.org/cves/CVE-2026-126334.html)).
The optional Plug floor also excludes the multipart length-limit bypass
([EEF-CVE-2026-120287](https://cna.erlef.org/cves/CVE-2026-120287.html));
it does not install Plug in hosts that do not use it.

Phoenix hosts must also use a patched minor branch: 1.6.18+, 1.7.25+,
or 1.8.17+ (within each minor). These optional floors cover the November 21
binary-broadcast dispatch and Presence tracker denial-of-service advisories
([EEF-CVE-2026-129344](https://cna.erlef.org/cves/CVE-2026-129344.html),
[EEF-CVE-2026-128361](https://cna.erlef.org/cves/CVE-2026-128361.html)).

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

  def mount(params, session, socket) do
    TEALive.mount(params, session, socket,
      app_module: MyApp.Counter,
      authenticated_user_key: "user_id"
    )
  end

  def handle_info(msg, socket), do: TEALive.handle_info(msg, socket)
  def handle_event(event, params, socket), do: TEALive.handle_event(event, params, socket)
  def render(assigns), do: TEALive.render(assigns)
end
```

`TEALive` resolves and caches the app dispatcher during the connected mount.
Keyboard events therefore do not synchronously call the lifecycle process; a
stopped or busy lifecycle cannot crash or stall the LiveView keydown callback.

`authenticated_user_key` is opt-in. Protect the route with your normal
authentication and set that key only from the authenticated server session.
The app receives the nonempty string identity in
`context.options[:authenticated_user]`; it receives neither URL params nor
the rest of the session. Without a valid identity the app must stay
read-only. TEALive does not authenticate the user or decide authorization.

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
cd packages/raxol_liveview && MIX_ENV=test mix test
```

See [LiveView cookbook](../../docs/cookbook/LIVEVIEW_INTEGRATION.md) for more patterns.
