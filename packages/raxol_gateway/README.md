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
- `Raxol.Gateway.Handler` -- the per-chat behaviour a session runs.
- `Raxol.Gateway.Session` -- one process per chat, with an idle timeout.
- `Raxol.Gateway.SessionRouter` -- starts and routes to sessions, keyed by
  `Route.key/1`, with the idle-timeout, cooldown, and max-session limits.
- `Raxol.Gateway.Pairing` -- DM pairing codes plus allowlists and the
  authorization check order.
- `Raxol.Gateway.Supervisor` -- the daemon that ties them together.

## Not yet implemented

Delivery modes and cross-platform `/handoff`, the concrete platform adapters
(Telegram, Discord, ...), and the `Lifecycle`-backed handler are follow-ups; see
`docs/adr/0023-unified-messaging-gateway.md`.
