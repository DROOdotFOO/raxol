# Changelog

All notable changes to `raxol_gateway` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-11-13

First release. One supervised daemon fronting many chat platforms behind a
single adapter contract.

### Added

- `Raxol.Gateway.Adapter`: the behaviour every platform implements
  (`connect/1`, `disconnect/1`, `platform/0`, `normalize_event/2`,
  `send_message/3`). `Adapter.InMemory` is the reference adapter tests drive.
- `Raxol.Gateway.Route`: the routing tuple and the unified session key
  `agent:main:{platform}:{chat_type}:{chat_id}`, so one chat maps to one
  session regardless of which adapter delivered the event.
- `Raxol.Gateway.Session` / `Raxol.Gateway.SessionRouter`: one process per
  chat with an idle timeout, started and routed by `Route.key/1`, under
  per-chat cooldown and a max-session limit.
- `Raxol.Gateway.Handler`: the per-chat behaviour a session runs (`init/2`,
  `handle_event/2`, optional `terminate/2` on clean stops).
- `Raxol.Gateway.SessionRouter`, and so `Raxol.Gateway.Supervisor`, does not
  start when the `:handler` module cannot be loaded: the start fails with
  `{:handler_not_available, module}`.
- `Raxol.Gateway.Handler.Lifecycle`: a full TEA app per chat under
  `environment: :gateway`. That environment starts no driver and no plugin
  manager and leaves processes unnamed, which is what lets one app module
  serve many chats in one VM.
- `Raxol.Gateway.Pairing`: DM pairing codes, allowlists, and a fixed
  authorization order. Inbound events are gated on it, so an unpaired chat
  cannot reach a handler.
- `Raxol.Gateway.Delivery`: the four outbound destinations, direct, home,
  cross-platform, and an explicit target string.
- `Raxol.Gateway.Pipeline.Transcribe`: a feed-loop stage that turns a
  `%{media: %{kind: :voice}}` event into `%{text: transcript}` before routing.
  Fetch, convert, and recognize are injectable; the defaults are ffmpeg plus
  the optional `raxol_speech` recognizer. A failure drops that one event and
  logs it rather than stalling the loop.
- `Raxol.Gateway.Adapter.Discord`: gateway-socket adapter with its own
  protocol codec and a Mint WebSocket transport.
- `Raxol.Gateway.Adapter.Email`: outbound over `gen_smtp` plus an inbound
  inbox and thread store, with a UTF-8 guard on inbound bodies and telemetry
  on drops.
- Durable poller offsets, so a restarted adapter resumes where it stopped
  rather than replaying or skipping updates.
- Optional per-turn conversation logging. A session records turns to any
  `:log` implementing `append(server, conversation_id, items)` keyed by a
  stable `conversation_id`; `SessionRouter.handoff/3` rebinds a conversation
  to another platform's route and reuses that id, so the log resumes the same
  history across platforms.
- A failed delivery neither crashes the chat session nor enters outbound
  history. `Raxol.Gateway.Session` handles adapter `{:error, reason}` returns,
  exceptions, and exits, logs the failure, and emits
  `[:raxol_gateway, :session, :delivery_failed]`.

### Notes

- `raxol_core` is the only required dependency. `raxol` (for
  `Handler.Lifecycle`), `raxol_speech` (for `Pipeline.Transcribe`),
  `gen_smtp` (for the email adapter), and `mint_web_socket` and `req` (for
  the Discord adapter) are optional; each entry point checks for its
  dependency before use.
- `Raxol.Gateway.Handler.Agent`, an agent-backed handler, ships in
  `raxol_console`, which requires `raxol_gateway ~> 0.2`.
- Pre-alpha. The public API may change inside 0.x.
