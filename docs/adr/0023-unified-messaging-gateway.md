# ADR-0023: Unified messaging gateway (`raxol_gateway`)

## Status

Accepted, 2026-07-22 (implemented as the `raxol_gateway` package). Originally proposed 2026-06-17. Third and last of the Hermes-extraction Tier 1 ADRs
(`~/Desktop/hermes-extraction-report.md`, item H1.4). Companion to ADR-0021 (self-improving agents)
and ADR-0022 (memory). Builds on the existing surface packages (`raxol_telegram`, `raxol_watch`,
`raxol_speech`), the shared `Raxol.Core.Events.Event`, the `Lifecycle` environment system, the
omnigent item-log (`Raxol.Agent.Conversation.{Store,Log}`), and ADR-0014 (Telegram Guardian).

Revised 2026-06-17 after a second Hermes research pass against current sources (v0.14-v0.16 official
docs + the `NousResearch/hermes-agent` repo). The SQLite critique below was confirmed near-verbatim
(schema v11, 1s busy timeout, 15 retries, WAL checkpoint every 50 writes, two-level guard). Three
refinements folded in: the platform count is version-dependent (22-24 in recent releases), Hermes's
own `/handoff` rebinds + summarizes rather than carrying the transcript (Raxol's persisted history
does better), and the pairing lockout is a Raxol hardening Hermes does not document.

Core implemented 2026-06-18 in `packages/raxol_gateway/`: `Adapter` behaviour (+ `Adapter.InMemory`),
`Route` keying, `SessionRouter` + `Session` (process-per-chat under a DynamicSupervisor, idle/cooldown/
max-session limits), `Pairing` (codes + allowlists + `authorize/2`), and `Supervisor`. Elaborations
landed the same day: per-chat history recording (`Session` `:log` keyed by `conversation_id`), the
four-mode `Delivery` router (decision item 4), and `SessionRouter.handoff/3` (rebind to an existing
`conversation_id` so history follows). Still to do: the concrete platform adapters (Telegram refactor,
Discord, ...) and the `Lifecycle`-backed handler.

2026-07-24: the `Adapter` contract is frozen (five callbacks; additions must be optional callbacks),
and the first production handler landed: `Handler.Agent`, backed by `Raxol.Agent.Stream` with
environment-resolved credentials (`auto_provider`).

2026-07-25: the remaining items from the 2026-06-18 list closed. `Handler.Lifecycle` runs a full TEA
app per chat under the new `environment: :gateway` (#721), and three platform adapters sit behind the
frozen contract: `Raxol.Telegram.GatewayAdapter` plus its `UpdatePoller` (#715),
`Raxol.Gateway.Adapter.Discord` plus its `GatewaySocket` (#717), and `Raxol.Gateway.Adapter.Email`
over `gen_smtp` (#718).

## Context

Raxol reaches chat platforms through separate, bespoke surface packages with no shared contract and
no cross-platform session.

- `raxol_telegram` is the most complete surface. `SessionRouter`
  (`packages/raxol_telegram/lib/raxol/telegram/session_router.ex:1-277`) keys sessions by integer
  `chat_id`, caps at 1000 sessions (`:12`), rate-limits with a 5s cooldown (`:14`), and idles out
  at 10 min (`:11`); API `route/2` (`:33`), `start_session/1` (`:42`), `get_session/1` (`:66`).
  `Session` (`session.ex`) wraps one `Lifecycle` per chat with `environment: :telegram` (`:154`).
  `Bot.handle_update/2` (`bot.ex:34`) is the platform entry point, with whitelist auth via
  `chat_allowed?/2` (`:139`, `allowed_chat_ids`). `InputAdapter.translate_callback/1`
  (`input_adapter.ex:36`) / `translate_text/1` (`:72`) map platform events to `Event`s;
  `OutputAdapter.format_message/2` (`output_adapter.ex:104`) renders the buffer to HTML + keyboard.
- `raxol_watch` is notification-only: `DeviceRegistry` (ETS, `register/3`
  `device_registry.ex:31`), `Notifier` (`push_to_all/1` `notifier.ex:46`, 1s debounce),
  `Push.Backend` behaviour (`push/2`), `ActionHandler.handle_action/2` (`action_handler.ex:46`)
  mapping taps back to `Event`s.
- `raxol_speech` is an input/output adapter pair (`InputAdapter.translate/2`
  `input_adapter.ex:50`, plus a TTS `Speaker`), no session router.
- The `Lifecycle` environment system already supports `:terminal`, `:agent`, `:telegram`, `:ssh`,
  `:watch`, with a uniform `io_writer` render callback.

Hermes is the benchmark. Its Gateway is ONE long-running daemon connecting 20+ platforms
(Telegram, Discord, Slack, WhatsApp, Signal, Matrix, and more; the exact set is version-dependent at
22-24 across recent releases, and it shifts: Teams appears in older lists but not the current
messaging enumeration) through a uniform adapter contract (`connect`/`disconnect`/`send_message`/
`on_message` per adapter), a single session store keyed `agent:main:{platform}:{chat_type}:{chat_id}`,
DM pairing authorization, four delivery modes, and `/handoff <platform>` cross-platform session
migration.

Four gaps separate Raxol from that:

### Gap 1: No shared adapter contract

Each surface has its own bespoke `InputAdapter`/`OutputAdapter`/router. Adding a platform means
copying `raxol_telegram` wholesale. There is no `behaviour` a new platform implements to plug in.

### Gap 2: No unified session store and no per-chat history

Sessions are per-package, in-memory, and keyed differently per surface (`chat_id` int vs device
token). None of the surfaces use `Conversation.Log`; a Telegram chat keeps no durable history.
There is no single key scheme spanning platforms.

### Gap 3: No pairing / cross-platform identity

Authorization is a per-platform whitelist (`allowed_chat_ids`) at best. There is no pairing-code
flow, no mapping of one user across Telegram + Watch + others, and no shared authorization store.

### Gap 4: No cross-platform handoff

A conversation cannot move from Telegram to another platform and keep its history, because history
is not stored and identity is not shared.

## Decision

**Introduce a `raxol_gateway` package: one supervised daemon, a `GatewayAdapter` behaviour that
existing and new platforms implement, a unified per-chat session store reusing `Conversation.Log`,
a pairing/authorization GenServer, a delivery router, and cross-platform handoff. Process-per-chat
on the BEAM replaces Hermes's SQLite-contention + message-queue + two-level-guard machinery.**

### 1. `Raxol.Gateway.Adapter` behaviour

Extract the proven Telegram pattern into one contract every platform implements:

```elixir
@callback connect(config()) :: {:ok, conn()} | {:error, term()}
@callback disconnect(conn()) :: :ok
@callback platform() :: atom()                                   # :telegram, :discord, ...
@callback normalize_event(raw :: term()) :: {:ok, route(), Event.t()} | :ignore
@callback send_message(conn(), route(), rendered()) :: :ok | {:error, term()}
```

`route()` carries `%{platform, chat_type, chat_id, user_id}`. Adapters own only platform I/O and
translation; routing, sessions, auth, history, and rendering distribution live in the gateway. This
is parity-validated, not speculative: Hermes documents the same per-adapter shape
(`connect`/`disconnect`/`send_message`/`on_message`), so each new platform is the same five-callback
implementation here.
`raxol_telegram` is refactored so `Bot`/`InputAdapter`/`OutputAdapter` implement
`Gateway.Adapter` (its `SessionRouter` is superseded by the gateway's generic router, item 2).
New adapters ship incrementally: Discord, Slack, Signal/Matrix.

### 2. Generic session router + unified store

A `Gateway.SessionRouter` generalizes Telegram's router: a `DynamicSupervisor` +
`Registry` of one `Gateway.Session` process per chat, keyed
`agent:main:{platform}:{chat_type}:{chat_id}` (Hermes key shape). It inherits the proven
idle-timeout + cooldown + max-session logic from `raxol_telegram/session_router.ex:11-14,196-201`.

Each `Gateway.Session` wraps a `Lifecycle` (new `environment: :gateway`) AND records turns to
`Conversation.Log` keyed by a stable `conversation_id` (item 4 depends on this). This closes Gap 2:
chats get durable history, and the store choice is `Conversation.Store.ETS` (default) or a durable
adapter, reusing ADR-0021/0022 infrastructure.

Process-per-chat is the architectural win: Hermes serializes a shared SQLite store (1s timeout, up
to 15 retries, WAL checkpoint every 50 writes "to avoid the convoy effect") and adds an
adapter-level message queue plus a two-level guard to dodge races. On the BEAM each chat is an
isolated process with its own mailbox; the convoy and the races do not exist.

### 3. Pairing + authorization (`Gateway.Pairing`)

A GenServer issuing DM pairing codes (8 chars, unambiguous alphabet, 1h TTL, per-user rate limit;
the lockout-after-repeated-failures is a Raxol hardening Hermes does not document), plus an allowlist
store. Authorization check order:
per-platform allow-all -> paired-user approved list -> platform allowlist -> global allowlist ->
default deny. This generalizes Telegram's `allowed_chat_ids` (`bot.ex:139`) and reuses the
Guardian applicant-tracking concepts from ADR-0014. A `user_id` registry maps one human across
platforms, enabling item 4.

### 4. Delivery router + cross-platform handoff

`Gateway.Delivery` resolves four destinations (Hermes parity): direct reply, a configured
home-channel (for cron/background results), an explicit target (`"telegram:-1001234567890"`), and
cross-platform. `/handoff <platform>` rebinds the destination route to the EXISTING
`conversation_id`: because history lives in `Conversation.Log` keyed by `conversation_id` (stable,
platform-independent) and identity is shared (item 3), a new platform's session resumes the same
conversation. This closes Gap 4. This betters Hermes: its `/handoff` rebinds the session key and
forges a synthetic summary turn rather than carrying the transcript; because Raxol persists full
history in `Conversation.Log`, the destination resumes the actual conversation, not a summary.

### 5. Package boundary and reuse

`raxol_gateway` depends on `raxol_core` (Events, behaviours), `raxol` (Lifecycle, optional), and
`raxol_agent` (Conversation.Log, optional). Platform adapters depend on their client libs
(`telegex`, etc.) as optional deps, guarded by `Code.ensure_loaded?/1` (the existing
`raxol_telegram` pattern). `raxol_watch` plugs in as a delivery-only adapter (push, no inbound
session). Existing surface packages keep working standalone; the gateway is additive.

## Consequences

### Positive

- **One daemon, many platforms, one contract.** Adding a platform is implementing five callbacks,
  not forking a package. Routing, sessions, auth, history, and handoff are written once.
- **Durable per-chat history for free.** Reusing `Conversation.Log` gives every chat the same
  snapshot/live-tail history the agent stack already has, and unlocks `session_search` (ADR-0022)
  over chat history.
- **Cross-platform identity and handoff.** A user paired once is known everywhere; a conversation
  follows them across platforms with its history intact.
- **The OTP advantage is structural, not incidental.** Process-per-chat removes the entire class of
  SQLite-convoy + message-queue + race-guard complexity Hermes carries. This is the clearest place
  Raxol's runtime beats Hermes outright.

### Negative

- **A new package and a behaviour refactor.** `raxol_telegram` must be reworked to implement
  `Gateway.Adapter`, with a deprecation path for its standalone `SessionRouter`.
- **More moving parts** (router + pairing + delivery + per-platform adapters) than the current
  single-surface setup.
- **Each new platform is real integration work** (auth, webhooks/long-poll, rate limits) even with
  the shared contract.
- **A unified identity store is a security-sensitive surface** (pairing codes, cross-platform
  mapping) that must be hardened.

### Mitigation

- Keep `raxol_telegram` runnable standalone during migration; the gateway wraps it rather than
  replacing it in one step. Ship Telegram first (refactor), prove the contract, then add platforms.
- Default the pairing store to deny, rate-limit and lock out code attempts, store codes with
  restrictive permissions, and record auth decisions to the `ThreadLog` (ADR-0020).
- Reuse the battle-tested idle/cooldown/max-session logic verbatim from the Telegram router rather
  than reinventing it.

### What this ADR does not decide

- **Which specific platforms ship, and in what order** beyond "Telegram first." Discord/Slack/
  Signal/Matrix are follow-ups against the stable behaviour.
- **A general user-facing `cronjob` tool** (report H2.2) that would use the home-channel delivery
  mode. The delivery mode is defined here; the cron tool is separate.
- **Voice (`raxol_speech`) as a gateway adapter.** Speech is an in-process I/O pair, not a remote
  platform; it stays a Lifecycle adapter, not a `Gateway.Adapter`, unless a remote voice transport
  appears.
- **Web/LiveView as a gateway platform.** `raxol_liveview` is a render surface, not a messaging
  platform; out of scope.
- **Distributed gateway across BEAM nodes.** Single-node router; a clustered router (sessions
  sharded across nodes via the swarm layer) is a future ADR.
- **A browser admin panel / web UI for gateway + platform config.** Hermes's v0.16 added a Channels
  page and admin panel (plus Portal `use_gateway` tool routing) for configuring platforms from the
  browser. The gateway here is headless and config-driven; a web control surface is a separate,
  later concern.

## Alternatives considered

### Keep per-platform packages, add cross-cutting helpers

Leave `raxol_telegram`/`raxol_watch` independent and share only small utilities.

Rejected. Unified session keying, pairing, cross-platform identity, and handoff are inherently
cross-platform; they cannot live in per-package routers. The shared daemon is the point.

### One gateway process multiplexing all chats

A single GenServer holding every chat's state (closer to Hermes's single-engine model).

Rejected. It recreates Hermes's contention problem on the BEAM voluntarily. Process-per-chat with a
Registry is the idiomatic, fault-isolated, race-free design.

### Adopt Hermes's SQLite session store

Port the `state.db` schema for session persistence.

Rejected. `Conversation.Log` + `Conversation.Store` already provide durable, snapshot/live-tail
session history with stable ids. Adding SQLite would duplicate it and import the convoy problem the
BEAM design avoids. (A SQLite `Conversation.Store` adapter could exist for scale, but it is not the
gateway's contract.)

### Put the gateway in `raxol` (main) instead of a new package

Avoid a new package boundary.

Rejected. The gateway pulls platform client libs and is optional for most consumers; a separate
package keeps those deps out of the core and mirrors how `raxol_telegram`/`raxol_watch` are
already factored.

## Validation

- **Existing surfaces keep working.** `raxol_telegram` and `raxol_watch` tests pass; the Telegram
  refactor preserves `InputAdapter`/`OutputAdapter` behaviour (asserted by the existing adapter
  tests) while routing through the new `Gateway.Adapter`.
- **Adapter contract test:** a fake in-memory `Gateway.Adapter` drives the full path: inbound raw
  event -> `normalize_event` -> session routing -> Lifecycle render -> `send_message`, with no
  Telegram dependency.
- **Session key + isolation test:** two chats on the same platform get distinct
  `agent:main:...:chat_id` keys and isolated processes; a crash in one does not affect the other;
  idle timeout and cooldown match the Telegram router's behaviour.
- **History test:** a gateway chat's turns land in `Conversation.Log` keyed by `conversation_id`;
  `session_search` (ADR-0022) finds them.
- **Pairing test:** an unpaired DM is denied; a valid code pairs and is then allowed; codes expire,
  rate-limit, and lock out after repeated failures.
- **Handoff test:** `/handoff <platform>` resumes the SAME `conversation_id` on the destination
  platform with prior history intact.

## References

- `~/Desktop/hermes-extraction-report.md` (item H1.4; the Hermes Gateway, session keys, pairing, delivery, handoff)
- ADR-0014: Telegram AI Guardian (applicant tracking + pluggable decision module; reused for pairing)
- ADR-0020: Agent Sandbox/ThreadLog/Policies (auth decisions recorded to `ThreadLog`)
- ADR-0021 / ADR-0022: skills + memory (`Conversation.Log` history unlocks `session_search` over chats)
- `packages/raxol_telegram/lib/raxol/telegram/session_router.ex:1-277` (the router pattern generalized; idle/cooldown/max at `:11-14,196-201`)
- `packages/raxol_telegram/lib/raxol/telegram/session.ex:154` (`Lifecycle` per chat, `environment: :telegram`; gateway adds `:gateway`)
- `packages/raxol_telegram/lib/raxol/telegram/bot.ex:34,139` (`handle_update/2`; `chat_allowed?/2` generalized into pairing/auth)
- `packages/raxol_telegram/lib/raxol/telegram/{input_adapter.ex:36,72,output_adapter.ex:104}` (the translate/render pattern the `Gateway.Adapter` contract formalizes)
- `packages/raxol_watch/lib/raxol/watch/{device_registry.ex:31,notifier.ex:46,push/backend.ex}` (delivery-only adapter)
- `packages/raxol_agent/lib/raxol/agent/conversation/log.ex` (the unified per-chat history store)
- `packages/raxol_core/lib/raxol/core/events/event.ex` (the shared event type every adapter targets)
