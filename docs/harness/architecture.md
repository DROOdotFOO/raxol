# Harness Architecture — the event-sourced core, the contract, the substrate

Status: **settled** unless marked. Fused from:
`../proposals/in-flight/harness-design.md` (L1–L7 + C1–C7),
`harness-spec-protocol.md`, `harness-spec-backend.md`,
`harness-spec-frontend.md`, `harness-synthesis.md` (AD/FI/NC dispositions),
`harness-storage-research.md` (D1 resolution), the freeze constitution
(branch `docs/harness-freeze-constitution`, PR #569 —
`harness-freeze-contracts.md` / `harness-invariants.md`), the D-PA/SHG line
(`harness-ui-roadmap.md` §0, `harness-ui-grok-reshaped-dag.md`,
`harness-ui-SHG-spec.md`), and the V substrate rulings of 2026-07-17/18.

---

## 1. The shape in one paragraph

A headless agent-harness **core** owns 100% of durable state and speaks a
typed **contract** of events (core→UI) and commands (UI→core); **detachable
UIs** (TUI, LiveView, web, mobile, MCP) are pure subscribers holding nothing
persistent. The core is an event-sourced **journal** (durable truth) plus
**materialized views** (the live TEA model and the C2 projections). Around
the primary loop runs a swarm of cheap, non-reasoning, cache-riding
meta-probes that gate/shape/extract/verify, writing structured events into
the same journal. Background inference is nearly free; primary attention is
the scarce resource; discipline lives at the *injection* boundary, not
generation. The category-empty seams the whole cohort leaves open (durable
session state, supervised kill, checkpoint/compaction, N-surface attach) are
exactly OTP's native strength — that coincidence is the thesis.

## 2. Locked decisions (L1–L7, plus the dispositions)

- **L1** Headless core + detachable UIs over a typed contract.
- **L2** Transport-agnostic from day one (in-process PubSub and wire/SSE, one
  envelope).
- **L3** Contract granularity = Codex Thread→Turn→Item, folded into TEA
  (turn = one fold cycle).
- **L4** Event sourcing = journal + materialized views, NOT pure
  re-fold-on-read. Reattach = replay; checkpoint = offset + snapshot.
- **L5** Core owns 100% of durable state; **a UI owns nothing persistent** —
  the single non-negotiable invariant.
- **L6** The contract is internal (not a third-party-pluggable protocol; see
  NC-3 — but see §7 on the separate ACP *client* package).
- **L7** Contract stays lightweight: message structs + one validation seam;
  no graph/DSL/CQRS framework (NC-1).

Research dispositions that bind design (full text in `harness-synthesis.md`
and `harness-ui-cohort-research.md`): AD-1 interrupt = supervision-tree kill;
AD-2 steer ≠ interrupt (two distinct messages); AD-3 compaction and resume are
one subsystem with a structured (term, not prose) checkpoint; AD-4 tool-call
validation at dispatch; AD-5 never filter content blocks when replaying
history; AD-6 blast-radius/spend gates reserve atomically before the call,
fail-closed; AD-7 safety constraints are typed state enforced outside the
model; AD-8 own the MCP wire directly. FI-1..6: durable transcript,
version-tagging, housekeeping gated like agent actions, kernel-sandbox seam at
the Port, taint markers, evidence-gated done. NC-1..5: no loop framework, no
swarm headline, no ACP *server*, no A2A/AG-UI/Temporal, no MCP sampling.

## 3. The contract (protocol)

Every message rides one envelope `%Envelope{v, session_id, kind, body}`; one
codec module owns encode/decode both directions; malformed traffic is
rejected loudly at the seam (the "zod boundary").

**Two populations, one journal, one bus:** family `:loop` (the agent's turns:
`turn_started · item_started · item_delta · item_completed · turn_completed ·
state_change · approval_requested · error · idle`) and family `:meta` (the
probes: `gate_decision · extract · residual · calibrate · verdict · research ·
promote`). Every event carries `id` (= journal offset), `turn_id`, `family`,
`type`, `tier`, `scope`, and `provenance{source, trust}` (FI-5 taint).

**Two-tier rule:** `item_delta` is the only ephemeral event — per-chunk
publish, single-publisher order, PubSub-only, never journaled, reconstructable
from `item_completed` (codified in the SYNC ACCORD). Everything else is
durable and journaled before/as it hits the bus.

**Commands:** `prompt · steer · interrupt · approval_decision · attach ·
detach · seek`. Steer and interrupt are two distinct OTP messages, never a
polled queue; steer carries `expected_turn_id` CAS (AD-13/U6); approval
decisions adopt Codex `ReviewDecision` semantics (`Denied` ≠ `Abort`,
`TimedOut` first-class, decision-carries-policy-amendment; scopes
`:once/:session/:root`).

**Governance: the contract only grows.** No rename/repurpose/type-narrow/
optional→required, ever; producer seam strict, reader seam tolerant
(skip-unknown ONLY — malformed known shapes are a red test against the codec,
never a UI workaround). Surfaces must never need lockstep updates.

## 4. Journal + storage (frozen)

One directory per session; the directory IS the session:
`~/.raxol/sessions/<id>/` = `meta.json` + `HEAD` (offset + config sidecar,
NEVER model state) + `journal/NNNNNN.jsonl` (framed JSONL, size-capped
segments) + `snapshots/<offset>.json`. Writer is a single per-session
GenServer (batched datasync ≤200ms, immediate on side-effect events); Reader
is tolerant (torn final line → truncate; interior corruption → hard alarm,
nothing deleted, nothing injected into model context); indexes are derived
and disposable; retention is an explicit previewed command (no automatic
deletion path exists); secrets are redacted at the write boundary. SQLite/
DETS/Mnesia/CubDB were eliminated on evidence (NC-6/7); Oban is the probe
*scheduler*, never the journal.

**One-way doors (ratified — never reopen; full text and contours in the
freeze constitution, branch `docs/harness-freeze-constitution`, PR #569):**

- **Offset law:** every journal record consumes exactly one offset from the
  single Writer counter; `Event.id = journal offset`; one id space.
- **`refs` = offsets-only, session-scoped, forever.** Cross-session
  references live in the consuming store, never as a journal field.
- **Tip is derived, never stored** — frozen predicate over CONVERSATIONAL
  loop events, positive whitelist, branch-aware; plus the tip skew-guard: a
  reader degrades to `{:tip_uncertain, reason}` when an unknown loop event
  sits above its computed tip on a higher-minor journal.
- **Session lineage = list of typed edges** at session level
  (`:fork|:spawn|:merge|:import`); journals stay strictly linear forever;
  **NC-12: no multi-writer/CRDT journal, ever.**
- **actor on every record** (stamped at the single producer seam);
  **model fingerprint on every LLM-bound completion**; `bill_to` never
  per-record (Ledger is the single money truth).
- **Decision-time-fold law:** admission decisions fold the truth
  synchronously at decision time; a stamped `trust` field is display/audit
  metadata only.
- **git-shape storage:** the log holds small facts + pointers; a
  content-addressed store holds bytes; everything else derived-and-disposable.
- **Two record kinds only** (event + checkpoint); compaction =
  `checkpoint{reason: "compaction"}` (AD-3b's one artifact).
- The axiom that decided the contested rulings: *every offset states the
  complete fact of what happened there; folds derive, never reconstruct.*

## 5. Process topology and the safety substrate

Per session, `:rest_for_one`: Journal → Dispatcher (sole live model owner,
one typed emit) → EmitBus (SessionStreamer: PubSub + SSE) → Projections
(model, rules, memory, worktracks, promoted classes) → Gates (SpendGate,
BlastRadiusGate) → Probes. The keystone emit (U1/U1.5) unified the fold
sites behind one typed event and gave the journal authority over `Event.id`
(append → offset → stamp → publish — the dual-id landmine's grave).

- **Interrupt (U5, merged):** staged supervised kill — cooperative signal →
  bounded wait → OS process-group SIGTERM → SIGKILL, death confirmed at the
  OS level, each stage an event (`turn_canceled{reason}`). The spike proved
  BEAM-native paths (Port.close, Process.exit) insufficient and that
  `:exit_status` must never be trusted as the death signal.
- **Steer (U6, merged):** distinct message, `expected_turn_id` CAS, injected
  at the next safe tool boundary.
- **SpendGate (U7) / BlastRadiusGate (U8):** atomic reserve before the call
  (the `Ledger.try_spend` pattern), fail-closed; shell routes through one
  wrappable chokepoint (the future kernel-sandbox seam, FI-4); housekeeping
  gated identically (FI-3). String-denylists are provably incomplete —
  enforce on typed intent outside the model.
- **Evidence-gated done (U21):** `turn_completed{final: true}` carries
  verification artifacts as data; absence renders explicitly.

## 6. The render substrate — history, and the 2026-07-18 pivot

**The inline-hybrid line (built and measured).** The UI lane built the
category-empty inline hybrid: native scrollback + DECSTBM-pinned footer
viewport + sealed print-once history. The paint-authority question (D-PA:
what may be rewritten after a block seals into scrollback?) was resolved on
real hardware (unit RB, 2026-07-16): **ship (A) seal-time-only, with (B)
soft-owned history as a runtime-detected additive upgrade** where the
terminal provably reflows (iTerm2). Ring B validated the core assumption
(scrollback-feed FED 3/3 automatable tier-1; `\e[2J` wipes scrollback on
wezterm/kitty — the keyframe ban is load-bearing). The Seal-Hardening Gate
(SHG, from the grok-build harvest) banked the one-way-door seal laws:

- **G1 single shared frontier classifier** — one pure
  `SealOracle.classify/3` + `scan_frontier/2` consumed by sealer,
  footer-sizer, resize gate, and tail renderer; consumers never inline their
  own.
- **G2 two-phase seal** — write → confirm → mark; a failed write halts the
  walk and retries; mark-before-write forbidden; post-seal content frozen;
  fill paths check `sealed?` and append fresh.
- **G3 pending-input holds the frontier** — unconditional on turn state; two
  running exceptions only (BgTask-started; non-last AgentMessage).
- **G4 frame-order law** — adopt resize dims first, size viewport to
  post-seal height, then seal, then repaint; wrap in DEC 2026
  synchronized-output (G5). Named failure modes: "input snaps to top",
  "stale width permanently garbles sealed history".

Full spec + ported test corpus: `../proposals/in-flight/harness-ui-SHG-spec.md`;
external validation: the `grok-build-substrate-parallel` memory (xai-org/
grok-build independently ships the same model and confirms every law).

**THE PIVOT (V, 2026-07-18 — governing):** the inline-hybrid substrate
(DECSTBM + native scrollback + print-once byte seals) is **SHELVED** —
"causing too much problems right now, maybe return later." **Full-viewport
mode (alt-screen, owned virtual scrollback, free repaint) is the live-demo
default.** What this changes and what it does not:

- Suspended: the byte-level print-once law and the DECSTBM machinery on the
  live path.
- In force: **logical immutability of sealed blocks** (content never mutates
  post-seal — G2's logical half), the seal frontier as the logical
  live/settled boundary (G1/G3), event-clocked motion, and every honesty
  rule. The doctrine survives at the model layer; only the byte substrate
  changed.
- Kept in-tree: the inline machinery (InlineAuthority, seal path, fixture
  demo, byte-goldens still pin it) — the pivot is reversible, and the
  measured D-PA/RB evidence stays valid for a return.
- Open (flagged in `README.md`): reconciling AD-U1/NC-U1's ratified
  inline-first language with the pivot; overlays-in-viewport design; what
  "salience over sealed history" means when history is repaintable (the
  seal-time-grade constraint was reveal-cadence-driven byte parity — a
  logical-history substrate relaxes it; needs a V ruling, not silent drift).

## 7. Surfaces and the live-session wiring

Every surface is a subscriber + command sender; attach/detach/reattach =
replay from offset; the UI's local view is a throwaway materialized view.
The UI capability floor (A1–A14) and how each maps to the protocol lives in
`harness-spec-frontend.md` §4; the load-bearing four are interrupt, steer,
reattach, status — each a baseline feature whose weak version is some
harness's top complaint.

**The live TUI chain (built, as of 2026-07-18 on `integration/harness-endgame`):**

```
SessionLane (behaviour, main raxol — the seam raxol must not need raxol_agent for)
  ← Raxol.Agent.Harness.SessionLane (agent-side impl: SessionStreamer out, Command in)
LiveSessionDriver (plain-process loop, NOT a GenServer — owner-consumption
  contract: input messages received ahead of render batches)
  ← linked forwarder owns subscribe/1, re-shapes {:session_event, ...}
      through EventBoundary.normalize/1 (the security seam: live events are
      untrusted input at the process boundary)
  → StreamCadence (decouples event rate from render cadence)
  → Surface (pure new/update/render map machine; keymap-first input;
      command_sink closure)
  → back out: lane.interrupt / lane.steer; submit path: command_sink
      %{type: :submit} → SessionLane.submit → SessionInbox {:start_turn}
      → ToolExecutor.stream; approvals: approval_answer →
      answer_permission → "approval_decision" wire → SessionInbox
      resolve_decision → the parked gated_run await resumes
StallDetector — pure observer over the stream; verdict + evidence surfaced
  to the human; deliberately never acts on the agent.
```

**External-agent drivers (NativeHarness):** `Raxol.Agent.Harness.ClaudeCode`
(drives `claude -p --output-format stream-json`, tools injected via
`--mcp-config`; the CLI owns its loop) and `.Cursor`, both parsing NDJSON via
`StreamJson`.

**ACP (Agent Client Protocol — the Zed editor↔agent protocol):**
`packages/raxol_agent_client_protocol/` is a full ACP v1 implementation,
both roles, OTP-native, with a vendor extension for **durable resumable
sessions** (offset-based reattach/replay, `_raxol/*` methods) — the journal
model exported onto the ACP wire. Pre-alpha; distinct from `raxol_acp`
(Virtuals commerce). NC-3 (don't relocate *our* loop onto an editor's
platform) still governs strategy; the package makes the choice available,
eyes open. **The ACP bridge stitch** — wiring an ACP session as a
`SessionLane` so an ACP-speaking agent renders in the harness surface — is an
open roadmap item (see `roadmap.md`).

## 8. The probe swarm and the meta layer (Wave 4+, gated)

C1 reasoning gate · C2 multi-track structured compaction (the crown jewel:
typed extraction tracks — when→then rules split hard-to-enforcement /
soft-to-reminders, session memory, worktracks — plus the named residual; at
75% context, projections replace the raw tail) · C3 intent-gated tools (also
the injection-sanitization boundary — a security primitive) · C4
agent-generated UI (declarative view descriptors, never eval — the
Raxol-native moat) · C5 background research (recognition-framed, hardest
gate) · C6 cross-family consensus (≥1 independent family is what makes
probability-stacking multiply instead of echo) · C7 calibration servo (rank
not magnitude; servo to a human setpoint; variance-floor, damping,
hysteresis). The control layer (recognition-framing + servo + independence)
is what turns fragile probes load-bearing. The meta layer (fluid ontology,
local/global promotion → auto-ADR with the one human confirm) is Wave 5.

**Eval-first governance (V-ratified 2026-07-16):** an eval unit (U23,
journal-replay based) **gates Wave 4**; every probe spec carries a one-line
sunset criterion ("delete when provider-native X matches on eval"); U14/C2
gets a control arm against provider-native compaction. Meta-pattern: anything
built atop model behavior ships with a measured exit criterion. The full-U14
gate lift is V-only (SYNC ACCORD).

**The economic law:** background inference is nearly free (non-reasoning,
cache-riding); the scarce resource is primary attention. Write the durable
tier lavishly; inject selectively. Stakes gate injection, not generation.

## 9. Packaging (ruled)

Hermetic dual-channel — `curl | bash` + system installers, embedded ERTS,
zero prereqs; agent-surface CLI stays NIF-free (termbox2 is TUI-lane) so
Windows is cheap. Owner: agent lane. Remaining decision is implementation
only (burrito vs hand-rolled release+launcher).
