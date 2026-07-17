# Harness-UI × Agent-Lane — intersection audit (2026-07-17)

Alignment doc for the agent-lane owner (protocol work / #613 / #569). Ground truth
verified against origin/master this session — the UI lane's ledger had trailed the
agent lane's merge pace, so every status below is grep/log-verified, not assumed.

## 1. Touchpoint matrix (UI unit ← agent-lane dep)

| UI unit | agent dep | dep status | UI status | verdict |
|---|---|---|---|---|
| **T13b live harness (M2)** | U1.5 ✓ #547 · SS ✓ #558 · U5 interrupt ✓ #572 · U6 steer ✓ #573 | **ALL MERGED** | blocked only on UI's own seal-hardening chain | **agent lane owes NOTHING for M2** — the gate is ours |
| T19 evidence-rendered done | U21 evidence-gated done ✓ #570 | **MERGED** | unblocked, unspawned | spawnable now |
| T18 restoration diff | U4 reattach/replay | reds only (#586 draft) | waiting | needs U4 impl |
| T22 projection panels | U14 C2 projections | **not found on master** | T14 ✓ merged | needs U14 — status? |
| T23 agent-generated panels | U11 meta family ✓ #584 (+T22) | MERGED | waiting on T22 | transitively on U14 |
| T21 attention escalation | (T13b) | — | post-M2 | — |

**Headline: M2 (T13b) is no longer cross-lane blocked.** U-side interrupt/steer
are on master; the UI side needs its seal-hardening chain (G2/G4/G5 + full-logical
seal), then T13b wires `%Command{}` `:interrupt`/`:steer` for real.

## 2. Contract surfaces the UI consumes (what we depend on staying stable)

1. **Command channel (U3/U6):** UI emits `%Command{}` for `:interrupt` (staged
   kill, U5) and `:steer` (CAS on `expected_turn_id`, U6). UI-side emitters are
   live (keymap T12: ESC/Tab `:always` binds; composer steer queue T11). The
   bifurcation rule is pinned UI-side: `:interrupt`/`:steer` cross the lane;
   `:fold_toggle`/`:jump_*` never do.
2. **Event vocabulary (U1.5 turn vocab + U11 meta family):** the projection
   (journal-fold) consumes `turn_*`, `item_delta`, tool events; blocks derive
   from durable events only. Any vocab change breaks fixture goldens LOUDLY
   (byte-golden CI, #608) — treat event schema as a frozen contract, additive only.
3. **attach{from_offset} (U4):** T18's reattach summary derives from replayed
   events only. Also T17 v1 is client-local last-seen; cross-surface last-seen
   needs a protocol addition (deferred, noted in the unit spec).
4. **Evidence payload (U21):** T19 renders `turn_completed{final: true}` evidence
   verbatim + renders ABSENCE explicitly ("no evidence"). Schema question below.
5. **Session lifecycle (SS):** one supervised session tree per live session;
   T13b's Surface attaches to it.

## 3. What the UI provides back

- Canonical input path: T27 shim → keymap → typed commands (agent lane never
  sees raw key events).
- Stall/doom-loop detector (merged #603): pure observer over the event stream,
  verdict+evidence surfaced to the human. Deliberately NEVER acts on the agent —
  if the agent lane grows self-correction signals (hidden-channel resample), the
  detector stays display-only; wire telemetry, not control.
- Golden fixtures as protocol regression net: any event-schema drift fails
  byte-goldens in CI before it reaches a live session.

## 4. #613 Boundary seam — direct UI-lane impact (the audit's hot item)

`Raxol.Core.Boundary.TermText` centralizes exactly the confinement this lane has
independently implemented at 5+ sites:
`ViewText.sanitize` · `ContentGuard.sanitize_line` · `MarkdownBody.to_text` strip ·
OverlayPicker label handling · stall-alert text sweep · (incoming: divider text).

Post-merge migration (UI-lane follow-up unit, propose after #613 lands):
- Migrate sites to `Boundary.TermText` where semantics MATCH. Caution: they are
  not all the same contract — ContentGuard is an SGR-allowlist ("visible-honest"
  neutralization, sanitize==identity is a tested seal-seam invariant in #608),
  while ViewText/MarkdownBody are strip-all. If TermText models one of these,
  the other must stay local or TermText needs a mode. DO NOT flatten them blindly
  — the #608 seam invariant test will catch drift, but the review should decide
  intent first.
- The shared test vectors (boundary_vectors/*.json) should absorb our corpus:
  G11 wrap/ESC cases, #607's fence-label injections, #608's residue classes.

## 5. Open protocol questions for the agent-lane owner

1. **context_pct denominator:** `turn_completed.usage` has token counts but no
   context-window size; the strip renders `—` honestly (producer decision,
   pinned). Add window size to usage, or a `context{used, budget}` meta event?
2. **Evidence schema (T19):** what does U21's evidence payload actually carry
   (tests-run? diffs? links?)? UI needs a bounded shape to render; "render
   verbatim map" is the fallback but a typed contract is better.
3. **Cross-surface last-seen (T17 v2):** protocol has attach{from_offset} only;
   a per-operator last-seen offset would make the unread divider survive
   reattach/multi-surface. Spec addition — worth it now or defer?
4. **View-descriptor vocabulary (T23):** U11 meta events are the transport;
   the bounded declarative vocabulary (never eval) is unspecified. Who owns the
   schema — agent lane (emitter) or UI lane (renderer)? Propose: UI owns the
   vocabulary + validates; agent lane owns transport only.
5. **U14 C2 projections status:** not found on master; T22 is the only
   pre-M2-adjacent UI unit still cross-lane blocked. Timeline?
6. **Stall detector signals:** does the agent lane plan hidden-channel quality
   signals (retry/resample telemetry)? The UI detector currently infers from
   observable events only; native signals would upgrade evidence quality.

## 6. Risks / collisions to coordinate

- **surface.ex churn:** 4 UI PRs merged into it this week + #610 pending; if
  agent-lane work touches Surface wiring for T13b prep, coordinate merge order
  (we absorbed 3 rebase-conflict rounds already this week).
- **Frozen contracts:** storage/event contract is constitutionally frozen
  (#569 pending) — both lanes' changes must be additive; the UI's byte-golden CI
  is now an enforcement mechanism for that freeze, not just a rendering net.
- **De-flake debt (shared):** MetricsCollector env failure, PlatformGraphics
  global-TERM mutation, renderer-SGR trio — repo-wide, hits both lanes' CI;
  candidates for one shared sweep.
