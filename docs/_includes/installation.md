## Installation

The full framework:

```elixir
{:raxol, "~> 2.4"}
```

Or pick a single subsystem:

```elixir
{:raxol_core, "~> 2.4"}        # behaviours, events, config, plugins
{:raxol_terminal, "~> 2.4"}    # terminal emulation, termbox2 NIF
{:raxol_mcp, "~> 2.4"}         # MCP server, client, registry
{:raxol_liveview, "~> 2.4"}    # Phoenix LiveView bridge
{:raxol_plugin, "~> 2.4"}      # plugin SDK
{:raxol_sensor, "~> 2.4"}      # sensor fusion (zero deps)
{:raxol_agent, "~> 2.4"}       # AI agent framework
{:raxol_payments, "~> 0.1"}    # agent wallets, x402/MPP/Xochi
{:raxol_speech, "~> 0.1"}      # TTS + Whisper STT
{:raxol_telegram, "~> 0.1"}    # Telegram bot surface
{:raxol_watch, "~> 0.1"}       # APNS/FCM push
```

```bash
mix deps.get
```

See [PACKAGES](../PACKAGES.md) for the full table, dependency graph, and pre-alpha packages (`raxol_acp`, `raxol_symphony`).
