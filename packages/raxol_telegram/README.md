# Raxol Telegram

[![Hex.pm](https://img.shields.io/hexpm/v/raxol_telegram.svg)](https://hex.pm/packages/raxol_telegram)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/raxol_telegram)

Telegram surface bridge for Raxol. Renders TEA apps as monospace code blocks in Telegram chats with inline keyboard navigation.

## What this is for

The Telegram bot ecosystem is moving in three directions at once: bots-as-group-admins screening join requests, rich-text messages via the Bot API 10.1 `sendRichMessage` family, and MCP-driven bots controlled by external agents. The wrapper-library space is crowded (Telegex, GramIO, ferobot, rustigram) but they all stop at "render a message, parse an update." None of them give you a TEA application model that runs the same way in a terminal, a browser, and a chat.

`raxol_telegram` plugs into the bottom of your TEA stack. A `Raxol.Core.Runtime.Lifecycle` instance per chat renders to monospace `<pre>` HTML with inline keyboards instead of cells and ANSI. A `Raxol.Telegram.Guardian` behaviour ([ADR-0014](../../docs/adr/0014-telegram-ai-guardian.md)) handles the new admin-bot surface separately, so join-request screening and interactive sessions stay decoupled. For high-volume groups, [gramiojs/telegram-bot-api](https://github.com/gramiojs/telegram-bot-api)'s self-hosted Docker image bypasses the 30 req/s public API limit.

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

### Rich Messages (Bot API 10.1)

Bot API 10.1 (released 2026-06-11) added `sendRichMessage` for structured content beyond MarkdownV2: tables, collapsible sections, headings, math, sub/superscript, and an expanded 32,768 character cap with a Show More boundary.

```elixir
import Raxol.Telegram.RichMessage

msg = rich_message([
  heading(1, "Build status"),
  paragraph([bold("master"), text(" is red")]),
  details([text("Show stacktrace")], [
    paragraph([code("UndefinedFunctionError")])
  ]),
  table([
    [cell([bold("Module")]), cell([bold("Coverage")])],
    [cell([text("Bot")]),    cell([text("94%")])]
  ]),
  math(~S"\\int_0^1 x^2 dx = \\frac{1}{3}")
])

{:ok, _result} = Raxol.Telegram.RichMessage.Sender.send(chat_id, msg)
```

**Show More chunking** wraps content past ~8,000 characters in a collapsible `details` block automatically. Disable with `chunk: false`. Content over 32,768 characters returns `{:error, :too_long}` rather than truncating.

**HTTP transport.** Telegex 1.8 predates Bot API 10.1, so the Sender uses `Req` (an optional dep) directly. Without `Req`, `Sender.send/3` returns `{:error, :req_not_available}` and you can call `RichMessage.to_payload/3` yourself to get the JSON body. For high-volume deployments (Telegram's public API caps at 30 req/s), point `:api_base` at a self-hosted [Bot API server](https://github.com/gramiojs/telegram-bot-api):

```elixir
Raxol.Telegram.RichMessage.Sender.send(chat_id, msg,
  bot_token: token,
  api_base: "https://bot-api.internal"
)
```

**Telemetry.** `[:raxol_telegram, :rich_message, :sent]` and `[:raxol_telegram, :rich_message, :error]`. Both carry `chat_id`, `byte_size` (encoded payload), and `chunked?` metadata.

**Wire format caveat.** Bot API 10.1's `RichMessage` / `RichText` / `RichBlock` class names are documented; the exact JSON discriminator field convention was inferred from the existing MessageEntity precedent (snake_case `type` values: `"bold"`, `"table_cell"`, `"details"`, etc). If Telegram's wire format differs once schemas are published in full, the only adjustment is the discriminator string in each builder.

### Polls with Hyperlinks

Telegram's June 2026 release surfaced hyperlinks in poll options as a
first-class UX. Underlying Bot API exposed `text_entities` on
`InputPollOption` before that; `Raxol.Telegram.Poll` gives it a typed
Elixir surface.

```elixir
import Raxol.Telegram.Poll

send_poll(chat_id, "Which doc?",
  [
    "Plain text option",
    link_option("Read ADR-0014", "https://github.com/example/adr/0014"),
    %{
      text: "See the source",
      entities: [link_entity(4, 3, "https://github.com/example")]
    }
  ],
  is_anonymous: false,
  allows_multiple_answers: true,
  bot_token: token
)
```

**Option shapes:** plain string, `{:link, label, url}` for an option whose
entire text is one link, or a `%{text: ..., entities: [...]}` map for
arbitrary entity layouts. `link_entity/3` builds a `text_link` entity at a
specific UTF-16 offset.

**Validation:** option count is checked client-side (Telegram requires
2-10). Other constraints (text length, entity bounds) are left to the API.

**HTTP transport.** Uses `Raxol.Telegram.HTTP` like other 10.x endpoints,
so `:bot_token`, `:api_base`, and `:post_fn` work uniformly.

### AI Guardian (Chat Join Request Screening)

Bot API 10.0 added `chat_join_request` updates and 10.1 added
`answerChatJoinRequestQuery`. Bots that hold admin permissions in a group
can screen applicants before they're admitted, optionally pushing them
through a mini-app for verification. See
[ADR-0014](../../docs/adr/0014-telegram-ai-guardian.md) for the full
design rationale.

Implement the `Raxol.Telegram.Guardian` behaviour with a single `screen/1`
callback. The return value drives what happens next.

```elixir
defmodule MyApp.SpamFilter do
  @behaviour Raxol.Telegram.Guardian

  @impl true
  def screen(applicant) do
    cond do
      blocked?(applicant.user_id) ->
        {:decline, "user previously banned"}

      missing_bio?(applicant) ->
        {:ask_mini_app, "https://verify.myapp.com", "Verify"}

      true ->
        {:approve, nil}
    end
  end
end
```

Configure the Guardian module via app env or pass per-call:

```elixir
config :raxol_telegram, guardian: MyApp.SpamFilter

# or
Raxol.Telegram.Bot.handle_update(update, guardian: MyApp.SpamFilter, bot_token: token)
```

The `:ask_mini_app` path is a hand-off: the bot sends a private message to
the applicant with a `web_app` inline keyboard button pointing at your
mini-app URL. `Raxol.Telegram.MiniApp.build_url/2` automatically appends
`chat_id`, `user_id`, and `query_id` as query params so your mini-app
backend can call `approveChatJoinRequest` / `declineChatJoinRequest` /
`answerChatJoinRequestQuery` itself with the right context. `raxol_telegram`
does not host the mini-app.

**Bot API path selection.** When the applicant carries a `query_id` (Bot
API 10.1+), `Guardian.apply_decision/3` uses `answerChatJoinRequestQuery`.
Without `query_id` it falls back to `approveChatJoinRequest` /
`declineChatJoinRequest`. The 10.1 path also auto-falls back on
`bot_api_error` responses (e.g. against an older API server).

**Telemetry.** `[:raxol_telegram, :guardian, :received | :approved | :declined | :asked | :denied | :error]`. All events carry `chat_id` and `user_id`; terminal events also carry `reason` (or `url` for `:asked`), `source` (`:bot` or `:mcp`), and `error_reason` for failures.

**MCP exports.** `Raxol.Telegram.Guardian.MCPTools.register()` exposes four
tools (`telegram_guardian_approve`, `_decline`, `_screen`, `_list_pending`)
through `Raxol.MCP.Registry`. Symmetric with ADR-0012: external agents can
observe and override Guardian decisions over MCP. Registration is opt-in
and requires `raxol_mcp` at runtime; without it, `register/0` returns
`{:error, :raxol_mcp_not_available}` and the rest of the package keeps
working.

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
