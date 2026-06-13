# ADR-0014: Telegram AI Guardian admin behaviour

## Status

Accepted, 2026-06-13. Revised same day to incorporate landscape research (see Context > Landscape) before acceptance. Implementation tracked under Phase T2 of the `telegram.org/blog/watch-apps-and-more` rollout. ADRs 0008 (LiveView) and 0012 (MCP as rendering target) are the closest priors. This one adds a Telegram-side admin surface in the same shape, with MCP-export symmetry to ADR-0012.

## Context

Telegram's June 2026 release lets bots act as group admins that screen `chat_join_request` updates and present applicants with a mini-app interface for verification. The Bot API gives us three new things at once: the admin role, the join-request update type, and the `web_app` inline-keyboard button that launches a user-facing mini-app over HTTPS.

`raxol_telegram` today is a per-chat TEA session bridge. `Bot.handle_update/2` dispatches `message` and `callback_query` updates to a `SessionRouter`, which owns one `Session` per `chat_id`. Each `Session` wraps a `Raxol.Core.Runtime.Lifecycle` in `:telegram` environment and renders TEA model state as `<pre>` HTML messages with inline keyboards. There is no admin-level handler. There is no notion of a "group" that survives across applicants. Sessions are tied to interactive chats, not to moderation decisions.

The forces shaping this ADR:

- **Different lifetime.** A join-request handler is bound to a *group* and processes a stream of unrelated applicants. A per-chat `Session` would be wrong: there is no recurring user, no persistent TEA model, and the work is usually one async decision per applicant, not a render loop. Reusing `Session` here would couple two unrelated concerns and pull the Lifecycle stack into a workflow that doesn't need rendering.
- **AI fit.** "AI Guardian" is the blog's framing. Screening a join request is the canonical agent task: pull applicant metadata, decide approve / decline / ask for proof. `raxol_agent` already provides `Raxol.Agent.Stream` and `Action` patterns. Wiring an agent in as the screener is the natural shape, not a special case.
- **Mini-app hosting is out of band.** Telegram mini-apps are HTTPS-served HTML/JS launched by `web_app: %{url: ...}` inline-keyboard buttons. A bundled mini-app would force `raxol_telegram` to ship a Phoenix endpoint, deal with TLS, and pull in `raxol_liveview` as a non-optional dep. The package today is intentionally narrow (`raxol_core + raxol (optional) + telegex (optional)`). Keeping mini-app hosting on the consumer side preserves that.
- **No persistence in v1.** Pending applicants live in process memory. A `Bot` restart loses in-flight `ask_mini_app` decisions. The blog doesn't promise atomic delivery and Telegram itself reissues `chat_join_request` updates on bot reconnect, so the cost of dropping in-memory state is bounded.

The shape we're picking has to fit alongside the existing per-chat model without leaking into it.

### Why the per-chat session model is the wrong home

Three concrete reasons:

1. A `chat_join_request` arrives with a `from.id` (the applicant) and a `chat.id` (the group). The TEA `Session` keys by `chat.id`, but the *subject* of the screening is the applicant, who has no chat with the bot. A session-per-applicant would create a `Session` that never receives a render and never gets keystrokes.
2. `SessionRouter` enforces `max_sessions: 1000` with a 5s cooldown to throttle interactive chat churn. Applying that to admin moderation throttles legitimate join floods (e.g. a public group post-share).
3. The `Session` idle-timeout (10 min) auto-stops the Lifecycle. Guardian decisions are typically resolved in seconds (approve/decline) or hours (ask_mini_app pending applicant completion). Neither matches the 10 min budget.

The right shape is a thin, stateless module invoked from `Bot.handle_update/2`, with the decision logic pluggable through a behaviour.

### Why we don't bundle the mini-app

A bundled mini-app would need:

- A Phoenix endpoint (or Bandit + Plug) listening on a public HTTPS URL
- Telegram's `WebAppInitData` HMAC verification using the bot token
- An `approve_chat_join_request` / `decline_chat_join_request` callback path back to the Bot API
- Configurable challenge UX (CAPTCHA, question, signed attestation, etc.)

Each one is a real product decision the consumer should make. `raxol_telegram` ships *structure* (the `Guardian` behaviour, `MiniApp` URL builders, telemetry) and leaves the hosted surface to the consumer. A follow-up package (`raxol_telegram_guardian_app`?) can bundle a default LiveView mini-app once the contract is settled.

### Landscape (digest research, 2026-06-13)

A 90-day platform digest (HN + GitHub + Reddit) surfaced three signals that shape the design:

1. **Bot API 10.1 introduces `sendRichMessage` as a dedicated endpoint family.** Source: [openclaw/openclaw#92258](https://github.com/openclaw/openclaw/issues/92258) referencing `sendRichMessage`, `sendRichMessageDraft`, and `RichBlockThinking`. The blog's tables / collapsible / math features are not a MarkdownV2 extension. They're a new endpoint. T1 (rich text formatter, separate from this ADR) targets that endpoint family. Guardian decline messages produced by `apply_decision/2` use it where present and fall back to MarkdownV2 when not. The fallback is honest: Telegex 1.8 predates 10.1, so the raw-`Req` path is the expected one for the first months after release.
2. **MCP-driven Telegram bots are an emerging pattern.** Three independent projects in 90 days expose the Bot API as MCP tools ([timoncool/telegram-api-mcp](https://github.com/timoncool/telegram-api-mcp), [0xDEADBEEF-all/telegram-bot-mcp](https://github.com/0xDEADBEEF-all/telegram-bot-mcp), plus a Claude skill). The direction of travel is clear: external agents controlling Telegram surfaces over MCP. Guardian sits at exactly the kind of decision boundary an external agent would want to observe and override. ADR-0012 already established MCP as a first-class rendering target. Guardian gets the same treatment (see Decision > MCP tool derivation for Guardian).
3. **Self-hosted Bot API server is mainstream for high-volume bots.** [gramiojs/telegram-bot-api](https://github.com/gramiojs/telegram-bot-api) ships a signed, multi-arch, auto-updating Docker image. Consumers running Guardian on large public groups will hit the public Bot API's 30 req/s cap during join floods. The README documents this as a recommended deployment, not a hard dependency.

## Decision

Introduce a `Raxol.Telegram.Guardian` behaviour with one required callback and a default implementation. Route `chat_join_request` updates through it from `Bot.handle_update/2`. Do not couple it to the per-chat `Session` model.

### Behaviour

```elixir
defmodule Raxol.Telegram.Guardian do
  @type decision ::
          {:approve, reason :: String.t() | nil}
          | {:decline, reason :: String.t() | nil}
          | {:ask_mini_app, url :: String.t(), button_text :: String.t()}

  @type applicant :: %{
          required(:user_id) => integer(),
          required(:chat_id) => integer(),
          optional(:username) => String.t() | nil,
          optional(:first_name) => String.t() | nil,
          optional(:bio) => String.t() | nil,
          optional(:invite_link) => String.t() | nil
        }

  @callback screen(applicant()) :: decision()
end
```

### Module surface

- `Raxol.Telegram.Guardian`: behaviour above, plus `decide/2` and `apply_decision/2` that wrap Telegex `approve_chat_join_request` / `decline_chat_join_request` and, for `:ask_mini_app`, send an invite message to the applicant with a `web_app` button.
- `Raxol.Telegram.Guardian.Static`: default impl backed by a predicate function in config, useful for tests and as a fallback. Returns `{:approve, nil}` when unconfigured.
- `Raxol.Telegram.MiniApp`: pure helpers that build `inline_keyboard` rows with `web_app: %{url: url}` buttons. No HTTP, no LiveView.
- `Raxol.Telegram.Bot`: new clause matching `%{chat_join_request: _}` updates, gated by the existing `allowed_chat_ids` access control. The clause emits `[:raxol_telegram, :guardian, :received]` telemetry, calls `Guardian.decide/2`, then `Guardian.apply_decision/2`. The configured Guardian module comes from `opts[:guardian]` or `Application.get_env(:raxol_telegram, :guardian, Raxol.Telegram.Guardian.Static)`.
- `Raxol.Telegram.InputAdapter`: `translate_join_request/1` normalises Telegex's `ChatJoinRequest` struct (or a raw map) into the `applicant()` type. No `Event.new/2`; Guardian decisions are not TEA events.

### Telemetry

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:raxol_telegram, :guardian, :received]` | `system_time` | `chat_id, user_id` |
| `[:raxol_telegram, :guardian, :approved]` | `system_time` | `chat_id, user_id, reason` |
| `[:raxol_telegram, :guardian, :declined]` | `system_time` | `chat_id, user_id, reason` |
| `[:raxol_telegram, :guardian, :asked]` | `system_time` | `chat_id, user_id, url` |
| `[:raxol_telegram, :guardian, :error]` | `system_time` | `chat_id, user_id, kind, reason` |

The `:received` event fires before `screen/1` runs, so consumers can measure decision latency by pairing it with one of the terminal events.

### Mini-app hand-off contract

When `screen/1` returns `{:ask_mini_app, url, button_text}`:

1. `apply_decision/2` sends a private message to the applicant (`user_id`) with an inline keyboard whose only button has `web_app: %{url: url}`.
2. The mini-app runs in the user's Telegram client. Its backend is consumer-hosted.
3. The mini-app's backend is responsible for calling Bot API `approveChatJoinRequest` or `declineChatJoinRequest` directly once it reaches a verdict.
4. Raxol does not observe completion. The `chat_join_request` update either resolves (Telegram removes the pending request) or expires.

The contract is documented in the `Raxol.Telegram.Guardian` moduledoc and the package README. The `:asked` telemetry event is the last observable signal Raxol emits for that applicant.

### AI agent integration path

A consumer can wire a `Raxol.Agent` as the Guardian by implementing `screen/1` to invoke an `Agent.Stream` synchronously with the applicant payload, then map the agent's structured output to a `decision()`. The framework provides no special agent glue here. The behaviour is small enough that a 10-line custom impl is clearer than a generic adapter.

### MCP tool derivation for Guardian

Symmetric with ADR-0012, which treats MCP as a first-class rendering target. The same shape applies here: Guardian is a decision boundary, and an external agent should be able to observe pending applicants and override decisions over MCP without the consumer writing protocol glue.

The `raxol_telegram` package registers four MCP tools with `Raxol.MCP.Registry` when `raxol_mcp` is available at runtime (existing `Code.ensure_loaded?` pattern):

| Tool | Inputs | Effect |
|------|--------|--------|
| `telegram_guardian_list_pending` | `chat_id` (optional filter) | Returns applicants currently mid-`:ask_mini_app` decision. Backed by an opt-in ETS table; empty list when persistence is off (the v1 default). |
| `telegram_guardian_approve` | `chat_id`, `user_id`, `reason` | Calls `Guardian.apply_decision/2` with `{:approve, reason}`. Emits the `:approved` telemetry event with `source: :mcp` metadata. |
| `telegram_guardian_decline` | `chat_id`, `user_id`, `reason` | Mirror of approve, for declines. |
| `telegram_guardian_screen` | `applicant` map | Invokes the configured `Guardian` module's `screen/1` on a synthetic applicant (no Bot API side effect). Useful for testing the screener via an external agent before binding it to a real chat. |

The tools register only when `raxol_mcp` is loaded. The package adds no compile-time dependency. This keeps `raxol_telegram` at its current dep footprint and lets consumers opt in by adding `raxol_mcp` themselves.

Resources (read-only views on MCP) are out of scope for v1. Pending-applicants persistence is the prerequisite, and the ADR explicitly defers that.

### What this ADR does *not* decide

- Persistence of pending `:ask_mini_app` applicants across Bot restarts. Out of scope for v1; revisit if production usage shows real drop rates.
- Throttling of approve/decline calls against Telegram rate limits. Out of scope; consumers handle bulk-screening with their own queue if needed.
- The default mini-app implementation. Defer to a follow-up package once two or three real consumers show what they want.
- Whether Guardians can sit in front of *interactive* chats too (using a different update type). v1 covers `chat_join_request` only.
- T1's rich-text formatter. `sendRichMessage` endpoint coverage and chunking strategy belong to ADR-T1 (not yet written) or the T1 implementation PR. Guardian only consumes T1's helpers for decline-reason rendering; it does not specify them.
- Self-hosted Bot API server deployment. Recommended in the README for >30 req/s scenarios but not a framework concern.

## Consequences

### Easier

- **Clean separation of concerns.** Per-chat interactive sessions (`Session`, `SessionRouter`) and group-level admin moderation (`Guardian`) share nothing but the `Bot` entry point. A change to one cannot regress the other.
- **AI agents drop in.** A consumer that already runs `Raxol.Agent` sessions can pipe applicant payloads through an agent without any framework-level coupling.
- **No hosting concerns inside raxol_telegram.** The package stays at its current dep footprint (`raxol_core + raxol (optional) + telegex (optional)`). No Phoenix, no Plug, no TLS, no bundle.
- **Telemetry is uniform.** Reuses the existing `[:raxol_telegram, :*, :*]` namespace and follows the same `system_time` / typed metadata convention as `[:raxol_telegram, :bot, :*]` and `[:raxol_telegram, :session, :*]`.
- **Testable in isolation.** `Guardian.Static` + `Bot.handle_update/2` with a mocked Telegex covers the full surface. No Lifecycle, no SessionRouter, no Phoenix.

### Harder

- **The ask-mini-app path is a hand-off, not a workflow.** Raxol emits `:asked` and stops observing. Consumers who want to track completion must wire their mini-app backend to telemetry or their own store. This is documented but it is a real ergonomic cost.
- **No persistence.** A Bot restart with pending mini-app decisions in flight loses no in-process state (there is none), but if a consumer adds local memoisation later they'll need an ETS/DETS layer. We're not building it now.
- **Two telemetry namespaces to attach to.** Consumers who want full Bot observability now attach to `[:raxol_telegram, :bot, :*]`, `[:raxol_telegram, :session, :*]`, and `[:raxol_telegram, :guardian, :*]`. The package README will list all three in one table.
- **One more behaviour to document.** `Guardian` joins `Push.Backend` (raxol_watch), `TTS.Backend` (raxol_speech), and the various agent behaviours as a pluggable surface consumers can implement. Worth it for testability, but it does grow the public API.
- **Telegex coverage risk.** If Telegex doesn't surface `chat_join_request`, `approve_chat_join_request`, or `decline_chat_join_request` cleanly, the implementation falls back to raw `Req` against `https://api.telegram.org/bot<token>/...`. The existing `@compile {:no_warn_undefined, [Telegex]}` + `Code.ensure_loaded?` pattern accommodates this, but the fallback path is more code than calling Telegex.

### Neutral

- Package version bumps from `0.1.0` to `0.2.0` (additive surface, no breaking changes; the new `Bot` clause only fires for an update type that was previously ignored by the catch-all).
- Tests: the existing test suite (34 tests) grows by an estimated 10-15 to cover `Guardian.Static`, `Bot` join-request routing, `MiniApp` builders, and the decision telemetry.
