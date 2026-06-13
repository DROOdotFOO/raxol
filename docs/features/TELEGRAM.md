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

The bot token belongs to Telegex's own config (`config :telegex, token: ...`), not to `:raxol_telegram`. `allowed_chat_ids` is passed at the `handle_update/2` call site; there is no app-env config for it.

Send a message to the bot from an allowed chat and the router spawns a `Session` for that chat. The session hosts a Lifecycle with `environment: :telegram`.

## Access Control

`allowed_chat_ids` is optional. If set, the `Bot` update handler drops messages from other chats before they reach the router. Leave it out to accept all chats, not recommended unless the bot is public-facing.

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

`telegex` is an optional dep. Without it the surface compiles but does nothing, useful for environments where Telegram isn't wanted.

The bot token is the only secret. Don't commit it; load via `System.fetch_env!/1` at runtime.

## Bot API 10.x Surface (2026-06)

Telegram's June 2026 release added rich-text messages, admin bots for `chat_join_request` updates, and poll hyperlinks. `raxol_telegram` 0.2 covers all three plus an MCP export path for the Guardian decisions.

These features ride on top of the per-chat Session model above. They use `Raxol.Telegram.HTTP` (shared raw `Req` transport with `post_fn` injection for tests) because Telegex 1.8 predates Bot API 10.1 and does not expose the new endpoints. The package adds `req ~> 0.5` as an optional dep; without it, the HTTP-bound modules return `{:error, :req_not_available}` and consumers can call `to_payload/3` themselves to get the JSON body.

### Rich Messages (`Raxol.Telegram.RichMessage`)

Builders for Bot API 10.1's `sendRichMessage` family. Paragraph, heading (1-6), table + cell, list + list_item (ordered / unordered), details (collapsible "Show More"), math (block + inline), thinking. Inline formatting: bold, italic, underline, strikethrough, code, spoiler, subscript, superscript.

```elixir
import Raxol.Telegram.RichMessage

msg = rich_message([
  heading(1, "Build status"),
  paragraph([bold("master"), text(" is red")]),
  details([text("Show stacktrace")], [paragraph([code("UndefinedFunctionError")])]),
  table([
    [cell([bold("Module")]), cell([bold("Coverage")])],
    [cell([text("Bot")]),    cell([text("94%")])]
  ]),
  math(~S"\\int_0^1 x^2 dx = \\frac{1}{3}")
])

{:ok, _} = Raxol.Telegram.RichMessage.Sender.send(chat_id, msg)
```

`chunk/2` enforces the 32K hard cap (returns `{:error, :too_long}` rather than truncating) and the 8K Show More boundary (wraps the tail of long content in a `details` block). Sender telemetry: `[:raxol_telegram, :rich_message, :sent | :error]` with `chat_id`, `byte_size`, `chunked?`, `reason`.

### AI Guardian ([ADR-0014](../adr/0014-telegram-ai-guardian.md))

Behaviour for screening `chat_join_request` updates. Guardian runs outside the per-chat Session model: applicants are keyed by user, not chat, and the decision (approve / decline / hand off to a mini-app) happens at the Bot dispatch layer.

```elixir
defmodule MyApp.SpamFilter do
  @behaviour Raxol.Telegram.Guardian

  @impl true
  def screen(applicant) do
    cond do
      blocked?(applicant.user_id) -> {:decline, "user previously banned"}
      missing_bio?(applicant)     -> {:ask_mini_app, "https://verify.myapp.com", "Verify"}
      true                        -> {:approve, nil}
    end
  end
end

# In app env:
config :raxol_telegram, guardian: MyApp.SpamFilter
```

`Bot.handle_update/2` gains a new clause for `%{chat_join_request: _}`. The applicant payload is normalised by `InputAdapter.translate_join_request/1` (handles both atom-keyed and string-keyed maps). `Guardian.decide/2` invokes the configured module's `screen/1`; `Guardian.apply_decision/3` calls the Bot API.

Bot API path selection is automatic: when the applicant carries a `query_id` (Bot API 10.1+), `apply_decision/3` uses `answerChatJoinRequestQuery`; without `query_id`, it falls back to the pre-10.0 `approveChatJoinRequest` / `declineChatJoinRequest` pair. The 10.1 path auto-falls back on `bot_api_error` too (e.g. against an older API server).

For the `:ask_mini_app` path, `Raxol.Telegram.MiniApp.build_url/2` appends `chat_id`, `user_id`, and `query_id` as query parameters so the consumer-hosted mini-app backend has everything it needs to call `answerChatJoinRequestQuery` itself with the right context. The mini-app is not hosted by `raxol_telegram`.

Guardian telemetry: `[:raxol_telegram, :guardian, :received | :approved | :declined | :asked | :denied | :error]`. All carry `chat_id` and `user_id`; terminal events also carry `reason` (or `url` for `:asked`), `source` (`:bot` or `:mcp`), and `error_reason` for failures.

### MCP Exports

`Raxol.Telegram.Guardian.MCPTools.register/0` exposes four tools through `Raxol.MCP.Registry`. Symmetric with [ADR-0012](../adr/0012-mcp-as-rendering-target.md): an external agent can observe and override Guardian decisions over MCP without protocol glue.

| Tool | Purpose |
|------|---------|
| `telegram_guardian_approve` | Admit an applicant (10.1 or pre-10.0 path, same selection logic) |
| `telegram_guardian_decline` | Reject an applicant |
| `telegram_guardian_screen`  | Run the configured screener on a synthetic applicant without applying the decision |
| `telegram_guardian_list_pending` | Returns `[]` in v1; persistence lands in v2 |

Registration is opt-in and requires `raxol_mcp` at runtime; without it, `register/0` returns `{:error, :raxol_mcp_not_available}` and the rest of the package keeps working. No compile-time dep on `raxol_mcp`.

### Polls with Hyperlinks (`Raxol.Telegram.Poll`)

`send_poll/4` accepts options as plain `String.t()`, `{:link, label, url}` tuples (entire text is one hyperlink), or `%{text: ..., entities: [...]}` maps for arbitrary entity layouts. `link_entity/3` builds a `text_link` entity at a specific UTF-16 offset.

```elixir
import Raxol.Telegram.Poll

send_poll(chat_id, "Which doc?",
  [
    "Plain text option",
    link_option("Read ADR-0014", "https://github.com/example/adr/0014"),
    %{text: "See source", entities: [link_entity(4, 6, "https://github.com/example")]}
  ],
  is_anonymous: false,
  allows_multiple_answers: true,
  bot_token: token
)
```

Option count is validated client-side (2-10); other constraints (text length, entity bounds) are left to the API.

### Self-Hosted Bot API Server

For groups expecting >30 req/s during join floods (Telegram's public API rate cap), point `:api_base` at a [gramiojs/telegram-bot-api](https://github.com/gramiojs/telegram-bot-api) Docker image:

```elixir
Raxol.Telegram.RichMessage.Sender.send(chat_id, msg,
  bot_token: token,
  api_base: "https://bot-api.internal"
)
```

The same `:api_base` option works on `Raxol.Telegram.Poll.send_poll/4` and `Raxol.Telegram.Guardian.apply_decision/3` (shared `HTTP` transport).

## See Also

- [Watch](WATCH.md): another push surface for mobile
- [Agent Framework](AGENT_FRAMEWORK.md): if your bot is an agent, use this stack
- [ADR-0014](../adr/0014-telegram-ai-guardian.md): full Guardian design rationale
