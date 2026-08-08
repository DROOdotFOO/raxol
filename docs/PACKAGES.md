# Packages

Raxol ships as a main package plus 17 focused subsystems. Use the main `raxol` package for the full framework, or take individual packages for narrower needs.

## Main

| Package                                            | Hex                       | What                                  |
| -------------------------------------------------- | ------------------------- | ------------------------------------- |
| [`raxol`](https://hex.pm/packages/raxol)           | `{:raxol, "~> 2.6"}`      | Full framework: runtime, UI, examples |

## Core

| Package                                                    | Hex                           | What                                       |
| ---------------------------------------------------------- | ----------------------------- | ------------------------------------------ |
| [`raxol_core`](https://hex.pm/packages/raxol_core)         | `{:raxol_core, "~> 2.6"}`     | Behaviours, events, config, plugins        |
| [`raxol_terminal`](https://hex.pm/packages/raxol_terminal) | `{:raxol_terminal, "~> 2.6"}` | Terminal emulation, termbox2 NIF           |
| [`raxol_mcp`](https://hex.pm/packages/raxol_mcp)           | `{:raxol_mcp, "~> 2.6"}`      | MCP server, client, registry, test harness |
| [`raxol_liveview`](https://hex.pm/packages/raxol_liveview) | `{:raxol_liveview, "~> 2.6"}` | Phoenix LiveView bridge, themes, CSS       |
| [`raxol_plugin`](https://hex.pm/packages/raxol_plugin)     | `{:raxol_plugin, "~> 2.6"}`   | Plugin SDK, testing, generator             |
| [`raxol_sensor`](https://hex.pm/packages/raxol_sensor)     | `{:raxol_sensor, "~> 2.6"}`   | Sensor fusion (zero deps)                  |

## Agents

| Package                                                    | Hex                           | What                                        |
| ---------------------------------------------------------- | ----------------------------- | ------------------------------------------- |
| [`raxol_agent`](https://hex.pm/packages/raxol_agent)       | `{:raxol_agent, "~> 2.6"}`    | AI agent framework                          |
| [`raxol_payments`](https://hex.pm/packages/raxol_payments) | `{:raxol_payments, "~> 0.2"}` | Agent payments, Xochi cross-chain, stealth  |
| `raxol_earn` (pre-alpha)                                    | `path: "packages/raxol_earn"`  | Virtuals Agent Commerce Protocol (seller)   |
| `raxol_agent_client_protocol` (pre-alpha)                  | `path: "packages/raxol_agent_client_protocol"` | Editor<->agent Agent Client Protocol (agentclientprotocol.com) |
| `raxol_symphony` (0.2.0, pre-alpha)                        | `path: "packages/raxol_symphony"` | Tracker-driven coding-agent orchestrator |
| `raxol_gateway` (pre-alpha)                                | `path: "packages/raxol_gateway"`  | Unified messaging gateway (multi-platform) |
| `raxol_cli` (pre-alpha)                                    | `path: "packages/raxol_cli"`      | The `raxol` command (`code`, `p`, `acp`, `agent`, `playground`, `new`), packaged as a self-contained Burrito binary |
| `raxol_console` (pre-alpha)                                | `path: "packages/raxol_console"`  | Boots a Virtuals ACP Console agent package onto the gateway stack |

The **coding agent** layers as: `Backend.Selector` (LLM backend adapter) -> the **Harness** engine (the event/command contract `Raxol.Agent.Contract` and the durable journal `Raxol.Agent.Journal` in `raxol_agent`, the projections and surface widgets `Raxol.Harness.*` in main `raxol`) -> the product surfaces `mix raxol.code` (interactive TUI, also over SSH), `mix raxol.p` (headless one-shot), and `mix raxol.acp` (ACP on stdio, for editors), all three in `raxol_agent` -> `raxol_symphony`, which orchestrates many agent runs above them. The Harness is the engine; the `mix raxol.harness.*.bless` tasks only regenerate its golden/fixture test snapshots.

## Surfaces

| Package                                                    | Hex                           | What                                        |
| ---------------------------------------------------------- | ----------------------------- | ------------------------------------------- |
| [`raxol_speech`](https://hex.pm/packages/raxol_speech)     | `{:raxol_speech, "~> 0.2"}`   | TTS (say/espeak), STT (Whisper), voice cmds |
| [`raxol_telegram`](https://hex.pm/packages/raxol_telegram) | `{:raxol_telegram, "~> 0.2"}` | Telegram bot, per-chat sessions, keyboards  |
| [`raxol_watch`](https://hex.pm/packages/raxol_watch)       | `{:raxol_watch, "~> 0.2"}`    | APNS/FCM push, glanceable summaries         |

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
raxol_earn      --> raxol_payments (runtime), raxol_mcp + raxol_agent (compile-time only)
raxol_agent_client_protocol --> (none; jason only, zero raxol deps)
raxol_symphony --> raxol_core, raxol_agent, raxol_mcp (all optional)
raxol_cli      --> raxol, raxol_agent (+ raxol_agent_client_protocol for `raxol acp`)
raxol_console  --> raxol_agent, raxol_gateway, raxol_earn

raxol_speech   --> raxol_core (+ bumblebee/nx/exla optional for STT)
raxol_telegram --> raxol_core (+ raxol/telegex/raxol_gateway optional)
raxol_watch    --> raxol_core (+ pigeon optional for APNS/FCM)
raxol_gateway  --> raxol_core (+ raxol_agent optional)

raxol_core     --> telemetry (only external dep)
raxol_sensor   --> (none)
```

The main `raxol` package does not depend on `raxol_agent`, `raxol_earn`, `raxol_agent_client_protocol`, `raxol_gateway`, or any of the surface packages. You opt into those.

## Publishing

See [Hex Publishing](https://github.com/DROOdotFOO/raxol/blob/master/CLAUDE.md#hex-publishing) for the publish order. `HEX_BUILD=1` strips local path deps so `mix hex.build` sees only Hex packages.
