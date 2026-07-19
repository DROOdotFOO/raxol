# Harness Spec — Protocol (the contract)

Date: 2026-07-15
Status: spec draft. The shared typed contract both `harness-spec-backend.md` and
`harness-spec-frontend.md` conform to. This is the "zod schema" of the zod-style split.
Grounded in: `harness-design.md` (design), `harness-synthesis.md` (research dispositions),
`harness-facts-two-perspectives.md` (evidence).

---

## 0. Purpose

One typed contract between the headless core and any UI. Both sides encode/decode through a
**single validation seam** — the pydantic-ai/Zod property the corpus praises near-universally:
*"fully typed results or an error, never malformed data that crashes later."* Malformed traffic is
rejected loudly at the seam, not swallowed — this is the same discipline as AD-4 (tool-call
validation), whose analogue swung SWE-bench Pass@1 by 54.3 points with zero model change.

The contract is **internal** (drives *our* surfaces). Exposing it as a third-party-pluggable
protocol (an ACP *server*) is deferred — that relocates us to the commodity side (NC-3, L6).

---

## 1. The two-populations model (the keystone frame)

The stream carries **two populations of events**, not one:

- **Primary loop** — the agent's turns: reasoning, tool calls, results, model changes. Codex
  Thread→Turn→Item shape. This is what the seam analysis alone saw ("transcript-as-truth").
- **Probe swarm** — the background meta-processes (C1–C7): gate decisions, extractions,
  calibration observations, drift verdicts, promotions. Cheap, non-reasoning, cache-riding.

Both write the **same journal** and subscribe to the **same bus**. Every downstream shape (plural
projections, two event families, the Oban-scheduler-vs-table split) falls out of this one fact: the
journal serves two populations. A UI or a probe is just a subscriber; the difference is what it
does with the stream, not how it attaches.

---

## 2. Transport (agnostic from day one — L2)

The contract works **in-process and over the wire**, same envelope both ways:

- **In-process:** `Phoenix.PubSub` topic per session; subscribers include local UIs *and* probes.
- **Wire:** SSE for events (the `GET /sessions/:id/events` surface in `session_stream_server.ex`
  already exists), a POST/WS channel for commands. Reattach over the wire = the mobile payoff.

An **envelope** wraps every message so transport is swappable:

```elixir
%Envelope{
  v:          integer(),        # protocol version (FI-2: every transcript version-tagged)
  session_id: binary(),
  kind:       :event | :command,
  body:       Event.t() | Command.t()
}
```

Serialization: term-based in-process; JSON on the wire. One codec module owns both directions.

---

## 3. Events (core → subscribers)

Common envelope on **every** event — this is what makes the two populations uniform and the
journal foldable:

```elixir
%Event{
  id:         integer(),        # monotonic per session = journal offset (seek target)
  turn_id:    binary() | nil,   # groups events within one primary turn
  ts:         integer(),        # microseconds
  family:     :loop | :meta,    # which population
  type:       atom(),           # see tables below
  tier:       :ephemeral | :durable,   # §5 — ephemeral never persisted
  scope:      :session | :global,      # meta events promote to global (auto-ADR)
  provenance: %{source: atom(), trust: :trusted | :tainted},  # FI-5 taint, C3 boundary
  payload:    map()
}
```

`provenance.trust: :tainted` marks any event whose payload derives from untrusted tool output
(FI-5). `provenance.source` names the writer (`:primary`, `:probe_c1_gate`, `:probe_c2_rules`,
`:probe_c6_verdict`, …) so a projection folds only its own inputs and the UI can show origin.

### Family `:loop` — the primary population (Codex Thread→Turn→Item on SessionStreamer's 7 types)

| type | tier | maps to | payload |
|---|---|---|---|
| `turn_started` | durable | Turn open | `%{prompt_ref}` |
| `item_started` | durable | Item open | `%{item_id, item_type}` |
| `item_delta` | **ephemeral** | streaming token | `%{item_id, chunk}` — live UI only, never journaled |
| `item_completed` | durable | Item close | `%{item_id, item_type, content}` |
| `turn_completed` | durable | Turn close | `%{turn_id, usage, cost}` |
| `state_change` | durable | projection moved | `%{projection, diff}` |
| `approval_requested` | durable | gate asks | `%{action, blast_radius, options}` |
| `error` | durable | fault | `%{where, reason}` |
| `idle` | durable | thread quiescent | `%{}` |

`item_type` ∈ `:message · :reasoning · :tool_use · :tool_result`. SessionStreamer's existing
`:text_delta/:tool_use/:tool_result/:state_change/:turn_complete/:done/:error` map directly;
`item_started`/`item_completed`/`turn_started`/`approval_requested`/`idle` are the extension.

### Family `:meta` — the probe population (the design-doc addition)

| type | source (example) | scope | payload |
|---|---|---|---|
| `gate_decision` | `:probe_c1_gate` | session | `%{gate, score, threshold, choice, seed}` (seed = replayable dice) |
| `extract` | `:probe_c2_rules` / `_memory` / `_worktracks` | session | `%{class, op: :add\|:update\|:drop, item}` |
| `residual` | `:probe_c2_residual` | session | `%{description}` (the named unknown) |
| `calibrate` | `:probe_c7` | session | `%{gate, observed_score, quantile, new_threshold}` |
| `verdict` | `:probe_c6` | session | `%{family, drift_score, advice}` (cross-family, independent) |
| `research` | `:probe_c5` | session | `%{conclusion}` (advisory, never an interrupt) |
| `promote` | `:probe_meta_adr` | **global** | `%{item, justification, journal_refs}` (auto-ADR, provenance-linked) |

`promote` is the only `scope: :global` event and the **irreversibility boundary** — it requires a
human `approval_decision` before commit (design §5). Its `journal_refs` list the event ids that
justify it (provenance mandatory, auditable).

---

## 4. Commands (subscribers → core)

```elixir
%Command{ session_id: binary(), type: atom(), payload: map() }
```

| type | payload | semantics |
|---|---|---|
| `prompt` | `%{text, attachments}` | start a turn (primary population) |
| `steer` | `%{text}` | **inject at next safe tool boundary** — distinct signal, AD-2 |
| `interrupt` | `%{}` | **supervised kill now** — not a cooperative flag, AD-1 |
| `approval_decision` | `%{ref, decision: :allow\|:deny, scope: :once\|:session\|:root}` | answer a gate; `:root` covers a whole spawn subtree |
| `attach` | `%{from_offset}` | subscribe; replay durable events from offset to rebuild view |
| `detach` | `%{}` | unsubscribe (no durable state lost — core owns it all) |
| `seek` | `%{to_offset}` | time-travel a read-model to a journal offset (checkpoint/rewind) |

`steer` and `interrupt` are **two distinct OTP messages** to the session process, never one queue
the loop polls — the corpus's named steer-vs-interrupt primitive (Tab=queue / Enter=now, #50246;
*"Codex already ships turn/steer… table stakes"*).

---

## 5. The two-tier stream rule

- **Ephemeral tier** (`tier: :ephemeral`): `item_delta` only. PubSub-delivered to live subscribers,
  **never journaled**. Lost on detach; rebuilt-from-nothing is fine because the `item_completed`
  durable event carries the final content.
- **Durable tier** (everything else): appended to the journal *before* or as it hits the bus.
  Reattach/replay/seek operate on this tier exclusively.

This is the economic law made mechanical: **write the durable tier lavishly** (both populations,
cheap), **inject selectively** into scarce primary context (the projections + curated reminders,
not the raw stream). Ephemeral deltas are the one thing too high-volume to keep and never needed
after the turn.

---

## 6. Validation seam (the "zod" boundary)

One codec module, both directions, single source of truth (the codex_sdk lesson — own validation
in one place, prevents policy divergence):

- `decode/1` — wire/term → `%Envelope{}`, or `{:error, reason}`. Malformed → loud reject, never a
  best-effort partial (COMPASS: string-level leniency is where enforcement fails 60–87%).
- `encode/1` — `%Envelope{}` → wire/term.
- Every `Event.type` / `Command.type` has a payload schema checked here. An unknown type or a
  payload-shape mismatch is an error at the seam, surfaced with an actionable message.

Continuity-token discipline (AD-5) lives here too: when replaying loop history to a provider,
**never filter content blocks by type** — opaque reasoning-continuity tokens
(`thinking.signature` / `reasoning.encrypted_content` / `thought_signature`) hard-fail (HTTP 400)
if not replayed byte-for-byte; 5 OSS projects broke on Gemini's alone.

---

## 7. Versioning & provenance (cheap now, painful later — FI-2)

- `Envelope.v` tags every message; a transcript records `{harness_version, backend/model,
  config_hash}` at turn granularity so a future behavior change is attributable (the 2073👍
  "Claude regressed" forensics, done for free).
- `Event.provenance` is first-class from day one — retrofitting taint/source onto a live journal is
  the painful path. C3's injection boundary and the auto-ADR provenance both depend on it.

---

## 8. What this protocol is NOT

- **Not an interchange standard.** Session/checkpoint/policy formats are category-empty across the
  cohort *because that's where lock-in lives*; we own our shape, we don't standardize it away.
- **Not an ACP server.** Consuming ACP/MCP entrenches us above a commodity; exposing our loop as an
  ACP server puts a commodity copy of us on an editor's platform (NC-3). Deferred, eyes open.
- **Not a graph/DSL.** Message structs + one codec. Elixir has the control-flow primitives; a
  framework re-introduces the state opacity LangChain was ripped out for (NC-1).
