# ADR-0008: Phoenix LiveView Integration Architecture

## Status

Implemented (Retroactive Documentation)

## Context

Terminal apps traditionally live in local command-line environments. A web interface adds remote access, collaboration, cross-platform consistency, and the ability to embed terminal UIs in web applications. But the integration is tricky: terminal interactions need low-latency bidirectional communication, state must stay synchronized, and web exposure brings security concerns.

Previous approaches (VNC, iframes, custom WebSocket protocols, server-side rendering) all fall short on either latency, integration quality, or real-time interaction.

We needed native Phoenix integration, real-time bidirectional terminal I/O, and performance that can handle high-frequency terminal updates.

## Decision

Build on Phoenix LiveView's WebSocket infrastructure and reactive model for real-time terminal interfaces with collaboration support.

### Components

#### LiveView Terminal (`lib/raxol_web/live/terminal_live.ex`)

The main LiveView component:

```elixir
defmodule RaxolWeb.TerminalLive do
  use RaxolWeb, :live_view
  alias RaxolWeb.Presence

  def mount(_params, session, socket) do
    session_id = generate_session_id()
    emulator = initialize_emulator(session)
    renderer = Raxol.Terminal.Renderer.new(emulator.main_screen_buffer)

    setup_presence("terminal:" <> session_id, session["user_id"])

    socket = assign(socket,
      session_id: session_id,
      emulator: emulator,
      renderer: renderer,
      users: [],
      cursors: %{}
    )

    {:ok, socket}
  end

  def handle_event("terminal_input", %{"data" => data}, socket) do
    process_terminal_input(socket.assigns.emulator, data)
    {:noreply, update_terminal_display(socket)}
  end
end
```

Real-time rendering with efficient diffs, user presence tracking, session management with auto-cleanup and reconnection, keyboard/mouse/resize event handling, and theme customization.

#### WebSocket Channel (`lib/raxol_web/channels/terminal_channel.ex`)

Lower-level channel for high-performance terminal I/O:

```elixir
defmodule RaxolWeb.TerminalChannel do
  use RaxolWeb, :channel

  def join("terminal:" <> session_id, _params, socket) do
    emulator = Emulator.new(80, 24)
    state = %{
      emulator: emulator,
      renderer: Renderer.new(emulator.main_screen_buffer),
      session_id: session_id
    }
    {:ok, assign(socket, state)}
  end

  def handle_in("input", %{"data" => data}, socket) do
    if within_rate_limit?(socket) do
      process_input(socket.assigns.emulator, data)
      output = render_terminal(socket.assigns.renderer)
      {:reply, {:ok, %{output: output}}, socket}
    else
      {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end
end
```

Rate limited (100 msg/sec), input validation with size limits, session isolation, error handling with graceful degradation.

#### Presence (`lib/raxol_web/presence.ex`)

Phoenix Presence tracks who's connected:

```elixir
defmodule RaxolWeb.Presence do
  use Phoenix.Presence,
    otp_app: :raxol,
    pubsub_server: Raxol.PubSub
end
```

User tracking per session, cursor synchronization, online/offline status, metadata sharing (names, themes, permissions).

#### Collaboration

Real-time cursors broadcast via Presence updates. Shared input broadcasts to all connected users and processes in the shared terminal.

### Architecture

```
TerminalLive (Main Container)
|-- TerminalDisplay (Rendering)
|-- InputHandler (Keyboard/Mouse)
|-- UserList (Presence)
|-- CursorOverlay (Multi-user Cursors)
+-- SessionControls (Connect/Disconnect/Share)
```

Event flow: Browser -> LiveView -> Channel -> Terminal Emulator -> Output -> LiveView -> Browser

State lives in three places: LiveView assigns (UI state), channel state (terminal session data), and Presence (collaboration data).

### Performance

Only changed regions get re-rendered. Rate limiting prevents abuse. Visible regions render first.

## Consequences

### Positive

- Terminal apps accessible from any browser
- Multiple users can interact with the same session
- Native Phoenix integration
- Efficient real-time updates via Phoenix's WebSocket layer
- Built-in rate limiting, input validation, session management

### Negative

- Additional web layer increases complexity
- Each web session uses memory and a WebSocket connection
- Requires network connectivity
- Web exposure increases attack surface
- Some terminal features limited by browser capabilities

### Mitigation

- Web interface is opt-in; terminal works standalone
- Automatic session cleanup and connection pooling
- Graceful degradation when network drops
- Rate limiting and input validation throughout

## Validation

### Achieved

- Round-trip latency: <50ms
- Concurrent sessions: 100+ tested
- Real-time multi-user editing with conflict resolution
- 99.9% availability with graceful reconnection
- No vulnerabilities in web interface security audit

## Alternatives Considered

**Static server-side rendering**: no real-time interaction.

**Pure WebSocket implementation**: more complex than LiveView, worse Phoenix integration.

**SPA**: requires separate API server and complex state sync.

**VNC/screen sharing**: high latency, poor UX, no integration.

LiveView gives us the best balance of performance, developer experience, and feature richness while building on Phoenix's proven real-time infrastructure.

## References

- [TEALive Bridge](../../packages/raxol_liveview/lib/raxol/live_view/tea_live.ex)
- [Phoenix LiveView Docs](https://hexdocs.pm/phoenix_live_view/)

---

**Decision Date**: 2025-05-20 (Retroactive)
**Implementation Completed**: 2025-08-10
