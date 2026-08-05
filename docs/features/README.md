# Features

## Framework

### [Agent Framework](AGENT_FRAMEWORK.md)

AI agents as TEA apps. OTP supervision, crash isolation, inter-agent messaging, LLM streaming to Anthropic/OpenAI/Ollama/Kimi/Lumo. Turn driver, native multi-vendor harness, ALLOW/ASK/DENY authorization, conversation item-log, reverse co-drive tunnel.

### [Coding Agent](CODING_AGENT.md)

`mix raxol.code`: an interactive terminal coding assistant wearing the axol face. Gated tools, plan mode, persistent sessions, slash commands.

### [Self-Improvement](SELF_IMPROVEMENT.md)

An agent that gets more capable the longer it runs. After-turn reviewer, agent-authored skills, and a Curator that ages them, all OTP-supervised and reversible.

### [Memory](MEMORY.md)

Provider stack, full-text session recall, and a dialectic user model. Pure-Elixir BM25-lite, no SQLite or NIF.

### [Agentic Commerce](AGENTIC_COMMERCE.md)

Autonomous payments for agents. Wallet management, spending controls, x402/MPP auto-pay, Xochi cross-chain settlement.

### [Agent Commerce Protocol](ACP.md)

The seller side. Sell agent services on Base with on-chain settlement and a per-job state machine (the v2 hook/event model). Pre-alpha.

### [Editor Agent Client Protocol](EDITOR_ACP.md)

The JSON-RPC protocol between a code editor (Zed and others) and an AI coding agent. Both roles, durable resumable sessions, zero raxol deps. Distinct from the commerce ACP above. Pre-alpha.

### [Symphony](SYMPHONY.md)

Coding-agent orchestrator. Polls a tracker (Linear, GitHub, Memory), claims eligible issues, isolates each in a workspace, runs a coding agent to completion. Pre-alpha.

### [MCP](MCP.md)

MCP as a rendering target. Component tree -> auto-derived tools, focus lens, structured screenshots, pipe-friendly test harness.

### [Plugin SDK](PLUGIN_SDK.md)

`use Raxol.Plugin` macro, manifest, testing helpers, and the `mix raxol.gen.plugin` generator.

### [Sensor Fusion](SENSOR_FUSION.md)

Poll sensors, fuse readings with weighted averaging and thresholds, render gauges and sparklines.

### [Distributed Swarm](DISTRIBUTED_SWARM.md)

CRDTs, node monitoring, topology election, tactical overlay. Discovery via libcluster with gossip, epmd, DNS, or Tailscale.

### [Adaptive UI](ADAPTIVE_UI.md)

Track usage patterns, recommend layout changes, animate transitions with a feedback loop.

### [Recording & Replay](RECORDING_REPLAY.md)

Capture terminal sessions as asciinema v2 `.cast` files. Replay with interactive controls.

### [REPL](REPL.md)

Sandboxed Elixir REPL with three safety levels, persistent bindings, and virtual filesystem.

### [Time-Travel Debugging](TIME_TRAVEL_DEBUGGING.md)

Snapshot every `update/2` cycle. Step back, forward, jump to any point, restore historical state.

### [Virtual File System](FILESYSTEM.md)

Pure functional in-memory VFS with REPL helpers and 7 LLM-callable agent actions.

## Surfaces

### [Unified Messaging Gateway](GATEWAY.md)

One daemon connecting many chat platforms through a shared adapter contract. Per-chat OTP sessions, DM pairing, cross-platform handoff. Pre-alpha.

### [Speech](SPEECH.md)

TTS for accessibility announcements, Whisper STT, 20 default voice commands.

### [Telegram](TELEGRAM.md)

Run a TEA app as a Telegram bot. Per-chat sessions, inline keyboards, HTML `<pre>` output.

### [Watch](WATCH.md)

APNS/FCM push from accessibility events. Debounced, prioritized, tap-to-event actions.

## Terminal

### [Cursor Effects](CURSOR_EFFECTS.md)

Visual trails and glow with configurable colors, presets, and smooth interpolation.

## Performance

Full frame in 2.1ms on M1 Pro, 13% of the 60fps budget. See [benchmarks](../bench/README.md) for methodology.
