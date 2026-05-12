# Raxol Documentation

Complete guide to Raxol -- multi-surface application runtime for Elixir.

## Start Here

- [Why OTP](WHY_OTP.md) -- why the BEAM runtime changes what's possible
- [Quickstart](getting-started/QUICKSTART.md) -- build your first terminal app
- [Core Concepts](getting-started/CORE_CONCEPTS.md) -- architecture and design
- [Component Gallery](getting-started/COMPONENT_GALLERY.md) -- all Components with examples

## Cookbook

- [Building Apps](cookbook/BUILDING_APPS.md) -- TEA patterns, state machines, scrollable lists
- [SSH Deployment](cookbook/SSH_DEPLOYMENT.md) -- serve apps over SSH, Fly.io
- [Theming](cookbook/THEMING.md) -- colors, theme system, accessibility
- [LiveView Integration](cookbook/LIVEVIEW_INTEGRATION.md) -- embed terminals in Phoenix
- [Performance](cookbook/PERFORMANCE_OPTIMIZATION.md) -- 60fps rendering, diffing, caching

## Features

- [Agent Framework](features/AGENT_FRAMEWORK.md) -- AI agents as TEA apps
- [Agentic Commerce](features/AGENTIC_COMMERCE.md) -- agent wallets, payments, Xochi
- [Agent Commerce Protocol](features/ACP.md) -- sell agent services on Base (pre-alpha)
- [Symphony](features/SYMPHONY.md) -- coding-agent orchestrator (pre-alpha)
- [MCP](features/MCP.md) -- MCP as a first-class rendering target
- [Plugin SDK](features/PLUGIN_SDK.md) -- writing plugins
- [Sensor Fusion](features/SENSOR_FUSION.md) -- polling, fusion, HUD rendering
- [Distributed Swarm](features/DISTRIBUTED_SWARM.md) -- CRDTs, discovery, topology
- [Adaptive UI](features/ADAPTIVE_UI.md) -- behavior tracking, layout recommendations
- [Recording & Replay](features/RECORDING_REPLAY.md) -- asciinema v2 session capture
- [Time-Travel Debugging](features/TIME_TRAVEL_DEBUGGING.md) -- snapshot, step, restore
- [REPL](features/REPL.md) -- sandboxed interactive Elixir REPL
- [Virtual File System](features/FILESYSTEM.md) -- pure functional in-memory VFS
- [Speech](features/SPEECH.md) -- TTS announcements, Whisper STT, voice commands
- [Telegram](features/TELEGRAM.md) -- TEA app as Telegram bot
- [Watch](features/WATCH.md) -- APNS/FCM push notifications
- [Cursor Effects](features/CURSOR_EFFECTS.md) -- visual trails and glow
- [All features -->](features/README.md)

## Guides

- [Custom Components](cookbook/CUSTOM_COMPONENTS.md)
- [Migration from DIY](getting-started/MIGRATION_FROM_DIY.md)

## Reference

- [Architecture](core/ARCHITECTURE.md)
- [Buffer API](core/BUFFER_API.md)
- [Architecture Decisions](adr/)
- [Plugin Development](plugins/)
- [Benchmarks](bench/)
- [Development](development/README.md) -- setup, commands, troubleshooting
- [Testing](testing/README.md) -- running tests, helpers, property-based testing
- [Configuration](cookbook/CONFIG.md) -- TOML config, environment overrides

## Examples

- [Examples Learning Path](../examples/README.md) -- runnable examples, beginner to advanced
- `mix raxol.playground` -- interactive Component catalog with 30 demos

## Resources

- [API Docs](https://hexdocs.pm/raxol)
- [GitHub](https://github.com/DROOdotFOO/raxol)
- [ROADMAP](../ROADMAP.md)
- [Issues](https://github.com/DROOdotFOO/raxol/issues)
