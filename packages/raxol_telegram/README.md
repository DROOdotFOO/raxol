# Raxol Telegram

[![Hex.pm](https://img.shields.io/hexpm/v/raxol_telegram.svg)](https://hex.pm/packages/raxol_telegram)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/raxol_telegram)

Telegram surface bridge for Raxol. Renders TEA apps as monospace code blocks in Telegram chats with inline keyboard navigation.

## Install

```elixir
{:raxol_telegram, "~> 0.1"}
```

For runtime Telegram API access, add:

```elixir
{:telegex, "~> 1.8"}
```

## Usage

```elixir
# In your supervision tree
children = [
  {Raxol.Telegram.Supervisor, app_module: MyApp.CounterApp}
]
```

### Bot Integration

Wire `Raxol.Telegram.Bot.handle_update/1` into your Telegex polling loop or webhook handler:

```elixir
def handle_update(update) do
  Raxol.Telegram.Bot.handle_update(update)
end
```

The bot handles `/start` and `/stop` commands. Other messages and inline keyboard taps are translated to Raxol events and routed to per-chat TEA sessions.

### How It Works

1. Each Telegram chat gets an independent TEA lifecycle (session)
2. The screen buffer renders as `<pre>` HTML in Telegram messages
3. Navigation uses inline keyboards (arrows, tab, enter, quit)
4. Button Components in the view tree become additional inline keyboard buttons
5. Sessions auto-expire after 10 minutes of inactivity
6. Message editing avoids spam (re-renders edit the existing message)

### Session Limits

The `SessionRouter` enforces a configurable `max_sessions` cap (default: 1000) to prevent resource exhaustion:

```elixir
{Raxol.Telegram.SessionRouter, app_module: MyApp, max_sessions: 500}
```

Per-chat rate-limit cooldown entries (5s window after the last session start) are auto-purged on every new session, so memory stays bounded under high chat churn. `Raxol.Telegram.SessionRouter.stats/0` reports current session count + cooldown-map size; `purge_stale_cooldowns/0` is exposed as an ops tool too.

### Telemetry

Attach to these events for observability:

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:raxol_telegram, :bot, :received]` | `system_time` | `chat_id, kind: :message \| :callback, byte_size \| data` |
| `[:raxol_telegram, :bot, :denied]` | `system_time` | `chat_id, kind` |
| `[:raxol_telegram, :session, :started]` | `system_time` | `chat_id` |
| `[:raxol_telegram, :session, :rejected]` | `system_time` | `chat_id, reason: :max_sessions_reached \| :rate_limited` |
| `[:raxol_telegram, :session, :stopped]` | `system_time` | `chat_id, reason: :explicit \| :process_down` (with `down_reason`) |

### Live Test

`examples/telegram_demo.exs` runs a real Telegram bot against a counter TEA app. Requires a token from @BotFather:

```bash
cd packages/raxol_telegram
TELEGRAM_BOT_TOKEN=<your-token> \
  TELEGRAM_ALLOWED_CHAT_IDS=123456789 \
  mix run --no-halt examples/telegram_demo.exs
```

See [main docs](../../README.md) for the full Raxol framework.

## License

MIT. See [LICENSE.md](LICENSE.md).
