# Surfaces: Write Once, Render Everywhere

One TEA module renders to many surfaces without modification. The same `init/update/view`
that draws a terminal UI also serves a browser, an SSH session, an agent over MCP, a
Telegram chat, a watch, and a speech interface. You write the application once; Raxol
projects it.

```
                          +---> Terminal   (termbox2 NIF)
                          |
                          +---> Browser    (Phoenix LiveView)
                          |
  TEA module (GenServer) -+---> SSH         (Erlang :ssh)
                          |
                          +---> Agent (MCP) (auto-derived tools)
                          |
                          +---> Telegram / Watch / Speech
```

## The surfaces

| Surface | Package | What it is |
|---------|---------|-----------|
| Terminal | `raxol_terminal` | The native TUI, over the termbox2 NIF (Windows falls back to a pure-Elixir driver). |
| Browser | `raxol_liveview` | The same component tree as a Phoenix LiveView, cells mapped to DOM. |
| SSH | `raxol` (built-in) | The TUI served over `:ssh`; each connection is its own session. |
| Agent (MCP) | `raxol_mcp` | Every interactive component auto-derives MCP tools; an LLM drives the same UI a human does. |
| Telegram | `raxol_telegram` | A TEA app as a bot: per-chat sessions, inline keyboards. |
| Watch | `raxol_watch` | Glanceable summaries and tap-to-action from accessibility events, over APNS/FCM. |
| Speech | `raxol_speech` | TTS announcements and Whisper STT with voice commands. |

Each surface has its own feature doc: [MCP](../features/MCP.md), [Telegram](../features/TELEGRAM.md),
[Watch](../features/WATCH.md), [Speech](../features/SPEECH.md). The
[Unified Messaging Gateway](../features/GATEWAY.md) connects many chat platforms through one
adapter contract.

## One fan-out, not N adapters

A Raxol app is one OTP process publishing its state, and each surface is a subscriber that
projects that state its own way. Adding a surface adds a subscriber, not a rewrite. The
terminal, the LiveView, and the SSH session can render the same running module at the same
time, each staying in sync through Phoenix.PubSub.

That is a different model from a chat bot framework, where each platform is a separate
integration that reimplements the conversation. Here the conversation, the state, and the
view logic live once in the TEA module; the surfaces are projections of it. A watch shows a
summary of the same model the terminal draws in full; an agent reads the same component tree
a human clicks.

## Animation across surfaces

A `view/1` can declare animation intent (`animate(element, property: :opacity, to: 1.0,
duration: 300)`). Surfaces that can accelerate it do (LiveView emits CSS transitions);
surfaces that cannot compute frames server-side (the terminal). The same declaration, honored
differently per surface, with `prefers-reduced-motion` respected. Hints are declarative
metadata, never imperative commands.

## The agent surface

MCP is built the same way as the others. Component types implement a `ToolProvider`
behaviour, so the framework derives an agent's toolset from the same component tree it
renders for a human, and a focus lens narrows it to the roughly 15 relevant tools per
interaction. An LLM `type_into` a field and `click` a button through the exact structure a
person sees. See [MCP as a Rendering Target](../features/MCP.md).

## See also

- [Why Raxol](../WHY_RAXOL.md): why one OTP runtime beats per-platform integrations.
- [Core Concepts](../getting-started/CORE_CONCEPTS.md): the TEA model the surfaces project.
- [Build Your First Agent](../getting-started/BUILD_AN_AGENT.md): the agent surface in practice.
