# Changelog

All notable changes to `raxol_telegram` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-05-21

### Added

- `Raxol.Telegram.SessionRouter.stats/0`: reports active session count
  and the size of the per-chat rate-limit cooldown map. Useful for
  monitoring memory under high chat churn.
- `Raxol.Telegram.SessionRouter.purge_stale_cooldowns/0`: drops
  cooldown entries older than the cooldown window. Called automatically
  on every `track_session/3` so the map cannot grow faster than session
  creation rate. Safe to call as an ops tool too.
- **Telemetry events** (`telemetry` is now an explicit dependency):
  - `[:raxol_telegram, :bot, :received]`: on every allowed update.
    Metadata: `%{chat_id, kind: :message | :callback, byte_size | data}`.
  - `[:raxol_telegram, :bot, :denied]`: when `allowed_chat_ids` filters
    out a request. Also fires for malformed config (graceful denial).
  - `[:raxol_telegram, :session, :started]`: on successful session
    creation.
  - `[:raxol_telegram, :session, :rejected]`: when session creation
    fails. Reasons: `:max_sessions_reached | :rate_limited`.
  - `[:raxol_telegram, :session, :stopped]`: on session termination.
    Reasons: `:explicit | :process_down` (with `down_reason` metadata).
- `examples/telegram_demo.exs`: end-to-end live-test harness with a
  minimal counter TEA app, Telegex polling setup, and chat-id access
  control via env vars.

### Changed

- **Breaking:** the `:click` event emitted by `InputAdapter.translate_callback("btn:" <> id)`
  now carries `%{component_id: id}` instead of `%{widget_id: id}`. This
  aligns the package with the repo-wide widget -> Component rename.
  Downstream consumers that pattern-match `event.data.widget_id` must
  rename to `event.data.component_id`.
- `Bot.chat_allowed?/2` no longer crashes when `:allowed_chat_ids` is set
  to a non-list, non-nil value (previously raised `CaseClauseError`).
  Misconfiguration now denies the request and logs a warning.
- `Bot.handle_update/2` wraps `Telegex.answer_callback_query/1` in a
  try/rescue/catch. A misbehaving Telegex (e.g. Finch not started)
  no longer crashes the update handler.
- `SessionRouter` automatically purges stale rate-limit cooldown entries
  on every `track_session/3` call, capping `last_start` map growth.
  Fixes an unbounded-memory issue when many unique chat_ids interact
  with the bot.

### Docs

- Reconcile `docs/features/TELEGRAM.md` with the actual API:
  - There is no `config :raxol_telegram, ...` block; the bot token
    belongs to Telegex's own config; `allowed_chat_ids` is passed to
    `Bot.handle_update/2` at the call site.
  - The Supervisor child spec needs `app_module: ...`.
  - The text-message mapping table now reflects reality: single-char
    text -> `:key` event, multi-char -> `:paste` event.

### Tests

- 46 example tests + 19 properties (StreamData), 0 failures. New
  coverage: bot telemetry on allow/deny paths, session lifecycle events,
  rate-limit + max-session rejection paths, cooldown purge behaviour,
  InputAdapter callback/text classification properties, OutputAdapter
  escape_html invariants, button extraction from view tree.

## [0.1.0] - 2026-04-27

Initial release. Telegram surface bridge for Raxol that renders TEA apps as
monospace `<pre>` HTML blocks in Telegram chats with inline keyboard navigation.

### Added

- `Raxol.Telegram.Bot`: update handler with optional `allowed_chat_ids`
  access control. Handles `/start` and `/stop` commands and routes other
  messages and inline keyboard taps to per-chat sessions.
- `Raxol.Telegram.SessionRouter`: per-chat session management with a
  configurable `max_sessions` cap (default 1000) and a 5-second per-chat
  cooldown for rate limiting.
- `Raxol.Telegram.Session`: TEA lifecycle running in the `:telegram`
  environment. Includes message edit deduplication (re-renders edit the
  existing message instead of spamming new ones) and a 10-minute idle
  timeout.
- `Raxol.Telegram.InputAdapter`: translates Telegram callback queries and
  text messages into Raxol events.
- `Raxol.Telegram.OutputAdapter`: renders the screen buffer as
  `<pre>`-wrapped HTML and extracts inline keyboard buttons from the view
  tree in document order.
- `Raxol.Telegram.Supervisor`: top-level `:rest_for_one` supervisor wiring
  the router and session components together.

### Tests

- 34 tests covering bot routing, session lifecycle, rate limiting, message
  edit dedup, and output rendering.
