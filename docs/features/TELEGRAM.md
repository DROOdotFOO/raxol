# Telegram Surface

`raxol_telegram` runs a TEA app as a Telegram bot. Each chat gets a session with its own TEA model; inline keyboards become Button Components; HTML `<pre>` blocks render the buffer.

## Quick Start

```elixir
# Add the supervisor with your TEA app module
children = [
  {Raxol.Telegram.Supervisor, app_module: MyApp.CounterApp}
]
```

Wire your Telegex polling/webhook handler into `Bot.handle_update/2`:

```elixir
defmodule MyApp.TelegramHandler do
  use Telegex.Polling.GenHandler

  @impl true
  def on_update(update) do
    Raxol.Telegram.Bot.handle_update(update, allowed_chat_ids: [123456789])
  end
end
```

The bot token belongs to Telegex's own config (`config :telegex, token: ...`), not to `:raxol_telegram`. `allowed_chat_ids` is passed at the `handle_update/2` call site -- there is no app-env config for it.

Send a message to the bot from an allowed chat and the router spawns a `Session` for that chat. The session hosts a Lifecycle with `environment: :telegram`.

## Access Control

`allowed_chat_ids` is optional. If set, the `Bot` update handler drops messages from other chats before they reach the router. Leave it out to accept all chats -- not recommended unless the bot is public-facing.

## Session Lifecycle

`SessionRouter` keeps a per-chat session map, capped at 1000 entries. New chats get a new session; existing chats route to the running one. Sessions idle out after 10 minutes of no traffic. A 5s cooldown between session creations rate-limits accidental floods.

| Event                  | What happens                                                              |
| ---------------------- | ------------------------------------------------------------------------- |
| Single-char text       | `:key` event with `char: <c>`                                             |
| Multi-char text        | `:paste` event with the trimmed text                                      |
| Inline `key:<name>`    | `:key` event (special key like `:up`/`:enter`, or char for length-1 keys) |
| Inline `btn:<id>`      | `:click` event with `component_id: <id>`                                  |
| `/start`               | Session created (or routed to existing one)                               |
| `/stop`                | Session terminated                                                        |
| 10min silence          | Session terminates, model dropped                                         |

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
