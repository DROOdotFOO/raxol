# Packages

Raxol ships as a main package plus 13 focused subsystems. Use the main `raxol` package for the full framework, or grab individual packages for narrower needs.

## Main

| Package                                            | Hex                       | What                                  |
| -------------------------------------------------- | ------------------------- | ------------------------------------- |
| [`raxol`](https://hex.pm/packages/raxol)           | `{:raxol, "~> 2.4"}`      | Full framework: runtime, UI, examples |

## Core

| Package                                                    | Hex                           | What                                       |
| ---------------------------------------------------------- | ----------------------------- | ------------------------------------------ |
| [`raxol_core`](https://hex.pm/packages/raxol_core)         | `{:raxol_core, "~> 2.4"}`     | Behaviours, events, config, plugins        |
| [`raxol_terminal`](https://hex.pm/packages/raxol_terminal) | `{:raxol_terminal, "~> 2.4"}` | Terminal emulation, termbox2 NIF           |
| [`raxol_mcp`](https://hex.pm/packages/raxol_mcp)           | `{:raxol_mcp, "~> 2.4"}`      | MCP server, client, registry, test harness |
| [`raxol_liveview`](https://hex.pm/packages/raxol_liveview) | `{:raxol_liveview, "~> 2.4"}` | Phoenix LiveView bridge, themes, CSS       |
| [`raxol_plugin`](https://hex.pm/packages/raxol_plugin)     | `{:raxol_plugin, "~> 2.4"}`   | Plugin SDK, testing, generator             |
| [`raxol_sensor`](https://hex.pm/packages/raxol_sensor)     | `{:raxol_sensor, "~> 2.4"}`   | Sensor fusion (zero deps)                  |

## Agents

| Package                                                    | Hex                           | What                                        |
| ---------------------------------------------------------- | ----------------------------- | ------------------------------------------- |
| [`raxol_agent`](https://hex.pm/packages/raxol_agent)       | `{:raxol_agent, "~> 2.4"}`    | AI agent framework                          |
| [`raxol_payments`](https://hex.pm/packages/raxol_payments) | `{:raxol_payments, "~> 0.1"}` | Agent payments, Xochi cross-chain, stealth  |
| `raxol_acp` (pre-alpha)                                    | `path: "packages/raxol_acp"`  | Virtuals Agent Commerce Protocol (seller)   |
| `raxol_symphony` (pre-alpha)                               | `path: "packages/raxol_symphony"` | Tracker-driven coding-agent orchestrator |

## Surfaces

| Package                                                    | Hex                           | What                                        |
| ---------------------------------------------------------- | ----------------------------- | ------------------------------------------- |
| [`raxol_speech`](https://hex.pm/packages/raxol_speech)     | `{:raxol_speech, "~> 0.1"}`   | TTS (say/espeak), STT (Whisper), voice cmds |
| [`raxol_telegram`](https://hex.pm/packages/raxol_telegram) | `{:raxol_telegram, "~> 0.1"}` | Telegram bot, per-chat sessions, keyboards  |
| [`raxol_watch`](https://hex.pm/packages/raxol_watch)       | `{:raxol_watch, "~> 0.1"}`    | APNS/FCM push, glanceable summaries         |

## Dependency graph

```
raxol --> raxol_core, raxol_terminal, raxol_sensor, raxol_mcp,
          raxol_liveview, raxol_plugin

raxol_terminal --> raxol_core
raxol_mcp      --> raxol_core
raxol_liveview --> raxol_core (+ phoenix_live_view optional)
raxol_plugin   --> raxol_core

raxol_agent    --> raxol + raxol_mcp
raxol_payments --> raxol_agent (compile-time only)
raxol_acp      --> raxol_payments, raxol_mcp (compile-time only)
raxol_symphony --> raxol_core, raxol_agent, raxol_mcp (all optional)

raxol_speech   --> raxol_core (+ bumblebee/nx/exla optional for STT)
raxol_telegram --> raxol_core (+ raxol/telegex optional)
raxol_watch    --> raxol_core (+ pigeon optional for APNS/FCM)

raxol_core     --> telemetry (only external dep)
raxol_sensor   --> (none)
```

The main `raxol` package does not depend on `raxol_agent`, `raxol_acp`, or any of the surface packages -- you opt into those.

## Publishing

See [Hex Publishing](../CLAUDE.md#hex-publishing) for the publish order. `HEX_BUILD=1` strips local path deps so `mix hex.build` sees only Hex packages.
