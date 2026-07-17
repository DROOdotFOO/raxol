# Harness Roadmap — units, gates, and open decisions across both lanes

Fused from: `../proposals/in-flight/harness-roadmap.md` (agent lane, v3),
`harness-ui-roadmap.md` (UI lane, v2 + D-PA resolution),
`harness-ui-grok-reshaped-dag.md` (SHG overlay), `harness-ui-STATE.md`
(ledger), `harness-ui-agent-lane-intersection.md` + the two agent-lane
responses, the SYNC ACCORD, and the proposal docs' build-unit tables.

**Staleness warning:** unit statuses below are stamped with their as-of
dates. The STATE ledger's last full destale was 2026-07-16 and the accord
itself was negotiated because ledgers ran ~35 merges stale; **PR-verified
reality on `integration/harness-endgame` + master is the baseline**, not any
table here. This document's value is the *shape* — the DAG, the gates, the
open decisions — not day-fresh status.

---

## 1. Lane split and coordination

Two lanes since 2026-07-15 (`harness-session-split` memory): **harness-agent**
= agentic layer + protocol (U-units); **harness-ui** = components/rendering
(T-units). Cross-lane terms are the SYNC ACCORD
(`../proposals/in-flight/harness-SYNC-ACCORD.md`, binding). The V-escalation
list (never re-litigated lane-to-lane): D-PA retroactive ratification,
PA-2..PA-5 (proposed constitution amendments), the full-U14 gate, one-way
doors, salience constants, golden re-bless, T22 scope.

## 2. Agent lane (U-units)

**Merged (as of 2026-07-17):** U0 contract v0 + CLI (#542) · U1 keystone bus
(#546) · U2a journal core (#545) · U3 command channel (#543) · U22 asciicast
fix (#544) · U1.5 close-the-keystone (#547) · SS Session.Supervisor (#558) ·
TH tool hook (#557) · MS model snapshot (#559) · U5 interrupt = staged
supervised kill (#572) · U6 steer CAS (#573) · U21 evidence-gated done
(#570) · U11 meta family + taint (#584) · U7/U8/U9/U10 red suites + impls
landed through the red-first wave (#569–#587 arc; U10 carried the final
checkpoint impl). The freeze constitution is PR #569 / branch
`docs/harness-freeze-constitution`.

**Sequencing laws (ratified):** control plane before continuity ("you cannot
honestly checkpoint a turn you cannot kill" — U5 before U10, unanimous);
U4 → U9 serialized (false parallel: both touch the tip rules + record
schema); vocabulary only grows.

**In flight / gated:**
- **U4 reattach/replay** — accord terms: repeat-attach idempotence red, #586
  undrafted in 48h (of 2026-07-17); UI determinism reds ≤2d after merge;
  U4-green PR ≤7d after. Carries the Dormammu regression (tip-finding never
  selects a non-conversational record).
- **U14 C2 multi-track compaction (crown jewel)** — GATED behind the
  eval-first Wave-4 ruling (V-only lift). **U14-proj** (projection
  read-models + `state_change` emission, no LLM/swap) is outside the gate,
  PR ≤14d after U4-green.
- **U23 eval unit** — journal-replay based; gates all of Wave 4 (U13–U18);
  every probe spec carries a sunset criterion; U14 gets a control arm vs
  provider-native compaction.
- Wave 4 probes (U13 gate, U15 intent, U16 research, U17 cross-family, U18
  servo) and Wave 5 meta layer (U19 ontology, U20 auto-ADR) — after U23.
- Packaging (ruled 2026-07-16): hermetic dual-channel, embedded ERTS,
  NIF-free agent CLI; implementation choice (burrito vs hand-rolled) open;
  agent lane owns.

## 3. UI lane (T-units)

**Merged (as of 2026-07-17):** the W0/W1 foundation (T0 keystone matrix, T1
capability slice, T2d inline driver, T2a/T2b/T2c scroll-region/append/
viewport spine, T4 block core, T7 projection, T8+T8b prominence, T26
markdown body, T27 input canonicalization, T28a teardown facet, T14 overlay
picker, TB/TP/TF/TE test infra, RB Ring-B driver) · W3 (T3 degradation
ladder, T5 block bodies, T10 status strip, T12 keybinds) · T13a fixture
assembly (M1) · the block-component EXT wave #535–#541 · post-M1 units
through the #587–#629 arc (stall detector #603, seal-frontier/seal-hardening
chain, unread divider, recency policy, markdown stable-prefix, diff expand,
editor suspend, transcript search, projection panels, command palette,
ansi16 salience, live-session driver...). Verify against master/endgame for
anything load-bearing.

**Resolved gates:**
- **D-PA (paint authority):** measured on real hardware (RB, 2026-07-16) —
  ship **(A) seal-time-only** with **(B) soft-owned history as a
  runtime-detected per-terminal upgrade** (iTerm2 reflows). `\e[2J` wipes
  scrollback on wezterm/kitty → keyframe ban is load-bearing. Retroactive
  ratification sits on the V-escalation list.
- **SHG (seal-hardening gate)** between M1 and M2: G1 shared frontier · G2
  two-phase seal · G3 pending-input holds frontier · G4 frame order · G5
  synchronized output — the 1WD items carried by the full-logical-seal impl.
  Off-path riders: G6 seal-display-mode, G7 ANSI16 downgrade (preserve
  category/polarity, never nearest-RGB), G8 md-stream O(N), G9 cadence +
  input priority, G10 stall detector (shipped), G11 wrap corpus.

**Milestones:** M1 fixture skeleton (T13a) ✓ · M2 live (T13b — accord split:
T13b-live buildable now vs merged U1.5/SS/U5/U6; T13b-reattach rides
U4-green) · M3 legible (T8+T9+T16+T20) · M4 navigable (T14+T15+T24) · M5
honest (T17+T18+T19+T21) · M6 instruments (T22+T23).

**Cross-lane touch points:** T13b ← U1.5+SS+U5+U6 (ALL MERGED — the gate is
UI-side) · T18 ← U4-green (+ `{:tip_uncertain, reason}` rendered
first-class) · T19 ← U21 ✓ (buildable) · T22 ← U14-proj (builds vs frozen
U11-CONTRACT shapes, merges vs real ones) · T23 ← U11 ✓ via T22.

**The 2026-07-18 substrate pivot** (see `architecture.md` §6) re-weights the
remaining UI DAG: inline-substrate polish (T2*-line hardening, SHG byte
laws) drops off the live critical path in favor of the full-viewport mode;
the logical seal laws, block model, salience, navigation, and honesty units
carry over unchanged. Machinery stays in-tree; fixture demo + goldens still
pin it.

## 4. Proposed units, not yet built (design docs are decision-ready)

| Cluster | Units | Source | Notes |
|---|---|---|---|
| Composer commands | U-C1 specs+catalog+interpreter → U-C2 composer primitives → U-C3 surface glue; then parallel: UI-local `/`-commands, prompt-templates, `@file` completer, `0x` completer (payments lane), plugin bridge | `harness-composer-commands.md` | F2-convergent local registry; ship-now recommended over blocking on F2 |
| Confirmation UI | P3-1 SelectorWithComposer ∥ P2-1 tool-widget router ∥ A-1 Discuss decision kind (agent); P1-1 assembly joins | `harness-confirmation-ui.md` | freeze the `approval_answer.text` field first; both lanes then proceed |
| Gundam widgets | G1 WidgetSpec/registry → G2 cells→rows + first ports, G3 settlement line; G4 MCP inbound ∥ G5 MCP sampled source (agent); G6 ACP diff producer (independent); G7 client resources (deferred) | `harness-gundam-widgets.md` | v2 (interactive, Arrival programs, multi-instrument rim, pins) gated on doctrine §9 decisions |
| Foundations | F0 capability detection (one batched probe pass, DA1 sentinel) · F2 unified action registry (the moat: one identity, one invocation semantics, N projections) | `f0-capability-detection.md`, `f2-action-registry.md` | F2 unbuilt is the named dependency of the three convergent local registries |

## 5. Open decisions (deferred, owned)

- **Salience-vs-parity after the pivot:** seal-time prominence grading was
  forced by sealed-byte parity; a repaintable logical-history substrate
  relaxes it. Does salience now apply across full history (the original
  north-star §3.2 reach), and what happens to the seal-time-grade law? V
  ruling needed. Related parked items: FLOOR_RATIO value, 256-color tier
  ladder (redistribute vs assert-distinct), G7 gray-collapse audit.
- **Overlays-in-viewport:** overlay strategy was specced per D-PA for the
  inline substrate (footer-anchored growth, scoped full-viewport covers);
  the full-viewport default changes the constraint space. Redesign owed.
- **F2** — build the real registry (effort 6) and absorb the three local
  catalogs; G-focus-scope (per-surface focus), G-effect-boundary (plugins
  reaching `update/2`), G-sensitive-semantics remain open V questions.
- **MCP client resources (G7):** `resources/read` + `resources/subscribe` on
  `MCP.Client` — unlocks pushed widget sources, `@mcp` completer, and the
  cross-session remote viewport (ADR-0012's missing client half).
- **ACP bridge stitch:** wire `raxol_agent_client_protocol` sessions as a
  `SessionLane` so ACP agents render in the harness surface; binds the
  fresh-session-default + durable-sessions (`session/load`) rulings.
- **Accent hue · pin/accretion policy · v2 interactive widget contract**
  (doctrine §11).
- **Protocol questions to the agent lane** (intersection doc §5):
  context-window denominator for context_pct; U21 evidence schema (typed
  shape vs render-verbatim); cross-surface last-seen (T17 v2); T23
  view-descriptor vocabulary ownership (proposal: UI owns vocabulary +
  validates, agent owns transport); stall-detector native signals.
- **Backlogged debt:** completed-but-unsealed block phase (T7/T9 follow-up,
  Y6); Lifecycle shutdown bug (graceful-stop teardown never reaches
  Driver.terminate — all environments); SequenceScanner trailing-`\e` hang
  guard; handle_ri/handle_hts swapped-tuple class; dual region stores; MLI
  dispatch_key shape bug; CI flakes (tp_pty spawn_timeout, modal_demo);
  de-flake sweep shared with agent lane.

## 6. Research corpus index (evidence, not to be fused away)

- `../proposals/in-flight/harness-research/` — 15 agent-lane briefs
  (leaders, framework libs, BEAM cohort, protocols, horror stories,
  permissioning, user voice, eval science, storage 10–15, U5 kill spike).
- `../proposals/in-flight/harness-ui-research/` — 6 UI briefs + the 3 triad
  reviews. `harness-ui-testing/` — the 6 pre-implementation suite designs.
- `../proposals/research/tui-aesthetics/` — 39 dossiers + 3 sections +
  `LANDSCAPE.md` (the doctrine's evidence base; decision order in §5).
- `../proposals/in-flight/harness-reviews/` — the Drew corpus + meta-analysis.
- Syntheses: `harness-synthesis.md` (agent), `harness-ui-cohort-research.md`
  (UI), `harness-storage-research.md` (round 2), `harness-facts-two-perspectives.md`
  (raw facts, two vantages), `harness-baseline-features.md` (the †-marked
  floor), `tui-steal-list.md` (modern-terminal patterns; parent of F0/F2).
