# RaxolGateway

Unified messaging gateway for Raxol: one supervised daemon connects many chat
platforms through a single adapter contract, with process-per-chat sessions,
unified session keying, and DM pairing authorization.

## Pieces

- `Raxol.Gateway.Route` -- the routing tuple and the session key
  `agent:main:{platform}:{chat_type}:{chat_id}`.
- `Raxol.Gateway.Adapter` -- the behaviour every platform implements
  (`connect`/`disconnect`/`platform`/`normalize_event`/`send_message`).
  `Raxol.Gateway.Adapter.InMemory` is a reference adapter for tests.
- `Raxol.Gateway.Handler` -- the per-chat behaviour a session runs
  (`init/2`, `handle_event/2`, optional `terminate/2` on clean stops).
- `Raxol.Gateway.Handler.Lifecycle` -- a full TEA app per chat under
  `environment: :gateway` (needs the optional `raxol` dependency; no driver,
  no plugin manager, unnamed processes, so one app module serves many chats).
- `Raxol.Gateway.Session` -- one process per chat, with an idle timeout.
- `Raxol.Gateway.SessionRouter` -- starts and routes to sessions, keyed by
  `Route.key/1`, with the idle-timeout, cooldown, and max-session limits.
- `Raxol.Gateway.Pairing` -- DM pairing codes plus allowlists and the
  authorization check order.
- `Raxol.Gateway.Delivery` -- the four outbound destinations (direct, home,
  cross-platform, explicit target string).
- `Raxol.Gateway.Pipeline.Transcribe` -- feed-loop stage that turns a
  `%{media: %{kind: :voice, ...}}` event into `%{text: transcript}` before
  routing (injectable fetch/convert/recognize; ffmpeg + the optional
  `raxol_speech` Recognizer by default; failures drop the one event, loudly).
- `Raxol.Gateway.Supervisor` -- the daemon that ties them together.

A session optionally records each turn to a `:log` (any
`append(server, conversation_id, items)`, e.g. `Conversation.Log`) keyed by a
stable `conversation_id`. `SessionRouter.handoff/3` rebinds a conversation to
another platform's route, reusing that `conversation_id` so the log resumes the
same history.

## Platform adapters

- Telegram: `Raxol.Telegram.GatewayAdapter` + `Raxol.Telegram.UpdatePoller`
  (in the raxol_telegram package).
- Discord: `Raxol.Gateway.Adapter.Discord` (REST sends, optional `req`) +
  `Raxol.Gateway.Adapter.Discord.GatewaySocket` (Gateway v10 WebSocket feed,
  optional `mint_web_socket`).
- Email: `Raxol.Gateway.Adapter.Email` (outbound-only SMTP submission via
  optional `gen_smtp`; inbound is a follow-up).

Inbound email is the remaining follow-up; see
`docs/adr/0023-unified-messaging-gateway.md`.
