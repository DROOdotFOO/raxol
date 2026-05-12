# Telegram Surface

`raxol_telegram` runs a TEA app as a Telegram bot. Each chat gets a session with its own TEA model; inline keyboards become Button Components; HTML `<pre>` blocks render the buffer.

## Quick Start

```elixir
# config/runtime.exs
config :raxol_telegram,
  bot_token: System.fetch_env!("TELEGRAM_BOT_TOKEN"),
  allowed_chat_ids: [123456789],
  app_module: MyApp
```

```elixir
# Add the supervisor
children = [
  Raxol.Telegram.Supervisor
]
```

Send a message to the bot from an allowed chat and the supervisor spawns a `Session` for that chat. The session hosts a Lifecycle with `environment: :telegram`.

## Access Control

`allowed_chat_ids` is optional. If set, the `Bot` update handler drops messages from other chats before they reach the router. Leave it out to accept all chats -- not recommended unless the bot is public-facing.

## Session Lifecycle

`SessionRouter` keeps a per-chat session map, capped at 1000 entries. New chats get a new session; existing chats route to the running one. Sessions idle out after 10 minutes of no traffic. A 5s cooldown between session creations rate-limits accidental floods.

| Event                  | What happens                                  |
| ---------------------- | --------------------------------------------- |
| Text message           | `InputAdapter` converts to `{:paste, text}`   |
| Inline button callback | Converted to Component click event            |
| `/start`               | Session restart                               |
| 10min silence          | Session terminates, model dropped             |

## Output

`OutputAdapter` takes the screen buffer and produces a Telegram message:

- Buffer -> HTML `<pre>` block (with monospace styling preserved)
- Interactive Components -> inline keyboard buttons in document order

Message edit dedup prevents redundant API calls when the rendered output doesn't change between updates.

## Security

`telegex` is an optional dep. Without it the surface compiles but does nothing -- useful for environments where Telegram isn't wanted.

The bot token is the only secret. Don't commit it; load via `System.fetch_env!/1` at runtime.

## See Also

- [Watch](WATCH.md) -- another push surface for mobile
- [Agent Framework](AGENT_FRAMEWORK.md) -- if your bot is an agent, use this stack
