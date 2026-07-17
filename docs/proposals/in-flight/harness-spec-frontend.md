# Harness Spec — Frontend (the detachable UIs)

Date: 2026-07-15
Status: spec draft. The UI side of the zod-style split: pure subscribers to the protocol, holding
nothing durable. Conforms to `harness-spec-protocol.md`. Grounded in `harness-design.md`,
`harness-facts-two-perspectives.md`, and Raxol's existing multi-surface rendering.

---

## 0. The one invariant

**A UI owns nothing persistent.** It is a projection of the stream — subscribe, render, send
commands. All durable state lives in the core (L5). This is what lets N surfaces attach to one loop
and what makes reattach trivial: a UI can die and respawn with zero state loss because it never held
state worth losing.

---

## 1. Surface model — one loop, N surfaces (the category-empty differentiator)

Every surface is the same shape: a subscriber to a session's protocol stream + a command sender.
Terminal / LiveView / SSH / mobile / MCP all attach to **one supervised loop**. *"A multi-surface
front end for one agent loop — nothing in the entire survey has this shape"* (protocols brief; the
differentiation seam #3). No incumbent has it because in Python/TS it's hard; on BEAM the loop is
already a supervised process and the bus is already PubSub/SSE.

| surface | transport | status |
|---|---|---|
| Terminal (TUI) | in-process PubSub | Raxol native — capability-detection, theming, incremental render exist |
| LiveView | PubSub → WS | `raxol_liveview` bridge exists (TerminalBridge, animation CSS) |
| SSH | in-process | `Raxol.SSH` exists |
| Mobile / remote | SSE + WS (wire) | the L2 payoff — reattach over the wire |
| MCP | stdio/JSON-RPC | MCP-as-render-target (ADR-0012); tools from the Component tree |

---

## 2. Attach / detach / reattach lifecycle

```
attach{from_offset}   → core replays durable events offset..now → UI folds them into a local view
(live)                → UI receives ephemeral item_deltas + durable events, renders both
detach{}              → UI unsubscribes; core keeps everything (UI held nothing)
re-attach{from_offset}→ same as attach — this IS the mobile "resume session" feature
```

The UI's local view is a **throwaway materialized-view** rebuilt from the durable tier on every
attach. It never persists; it never becomes a second source of truth (the failure L5 forbids).
Contrast the cohort: `--resume`/`--continue` start fresh (#26123), resume loses state → the model
*hallucinates* to fill the gap (#31330). Reattach-from-journal is the structural fix.

---

## 3. Rendering the two-tier stream

- **Ephemeral `item_delta`** → live incremental render, no full repaint, no flicker (A1;
  `r1-incremental-render`). The "feels fast" tier. Dropped after the turn; the durable
  `item_completed` carries final content for the transcript and for a fresh attach.
- **Durable events** → the transcript + the projections. `state_change` events update the rendered
  read-models (rules/memory/worktracks panels). `turn_completed` carries usage/cost for the status
  line.

The two tiers map to two render paths: a fast delta path (append-only, cheap) and a
transcript/projection path (folded, durable). A UI that only implements the durable path still
works — it just loses the token-by-token feel, not correctness.

---

## 4. UI capability floor (baseline §A), mapped to the protocol

| feature | protocol wiring | notes |
|---|---|---|
| A1 streaming render | `item_delta` (ephemeral) | built (`r1-incremental-render`) |
| A2 **interrupt** | `interrupt` command → supervised kill | the fix for "Stop doesn't stop it"; UI side is one keybind |
| A3 **steer** | `steer` command | distinct key from interrupt (Tab=queue / Enter=now, #50246) |
| A4 transcript/scrollback | fold durable events | the trust-rebuild surface |
| A5 diff render | `item_completed{tool_result}` + `approval_requested` | show **before apply** (pre-apply > post-hoc undo, Aider #649) |
| A6 approvals | `approval_requested` → `approval_decision` | offer `:once/:session/:root` (Devin's 3 buttons; `:root` covers a subtree) |
| A7 **status/context indicators** | `turn_completed{usage,cost}`, context-% | hiding context loses trust (Cherny reply −83); observability is the multiplier |
| A8 multi-line input | `prompt` command | paste, `$EDITOR` |
| A9 markdown render | `item_completed{message}` | code blocks, tables |
| A10 **resume/reattach** | `attach{from_offset}` | the differentiator; category-empty + regressing cohort-wide |
| A11 slash commands | client-local + `prompt` | |
| A12 @-mention refs | `prompt{attachments}` | pull by reference, not paste |
| A13 progress indication | `item_started` / long-op ticks | "working" vs "hung" |
| A14 theming/color | client-local | built (capability-detection + theming) |

Interrupt/steer/reattach/status are the load-bearing four — each a baseline feature whose *weak*
version is some harness's top complaint. The UI side of all four is small; the power is that the
backend makes them real (supervised kill, journal replay).

---

## 5. C4 — agent-generated UI (the Raxol-native moat)

When a dynamic dashboard helps, the agent calls a tool that emits a **view descriptor** — a Raxol
component tree, **declarative, not eval'd code.** The thing that makes agent-generated UI dangerous
elsewhere (arbitrary execution) is absent by construction: the agent emits components the framework
renders, bounded to the existing Raxol vocabulary.

- The emitted UI is **just another subscriber**: it binds to the same session stream and renders
  C2's projections (worktracks/memories) live. No new channel — it rides the protocol.
- No other harness can make this move cheaply; the reactive frontend already exists. Ties C4 to the
  multi-surface contract directly — an agent-built panel is a surface like any other.

---

## 6. Observability surface (the multiplier)

Observability is *why* state/blast-radius/steering failures go undetected as long as they do (C6 in
the synthesis). The frontend must **show what the agent reads and knows**, not hide it — hiding
tool-call file paths drew 186👍 of complaint; Anthropic's lead defending the hide netted −83
(*"I now trust the LLM less, not more"*).

Render from the protocol envelope, for free:

- `provenance.source` — which population/probe produced an event (primary vs C1-gate vs C6-verdict).
- `provenance.trust: :tainted` — flag content derived from untrusted tool output (the lethal-trifecta
  visibility C3 marks).
- `gate_decision` / `calibrate` / `verdict` meta events — surface the probe swarm's reasoning as an
  **advisory side-channel**, clearly separated from the primary feed (never raw-appended — that
  re-creates Cognition's "conflicting implicit decisions").
- Time-travel: `seek{to_offset}` drives a read-model to any journal offset — Raxol's Time-Travel
  Debugging answers most of this for free once the agent action log is the same journal, not a
  separate mechanism.

---

## 7. Build order

1. **TUI + LiveView as the first two subscribers** off the protocol — proves N-surface attach with
   two surfaces that already exist, only needing the subscribe + command wiring.
2. **Interrupt + steer + status keybinds** — small UI, load-bearing backing (backend §3, §8).
3. **Reattach-from-offset** — the mobile payoff; the same `attach` path, exercised across the wire.
4. **Then** C4 agent-generated UI + the observability side-channel, once the probe swarm (backend
   §5) is emitting meta events to render.

The surfaces exist; the work is making them pure protocol subscribers and deleting any durable
state they currently hold (the L5 audit).
