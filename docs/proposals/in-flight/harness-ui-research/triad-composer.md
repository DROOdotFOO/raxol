Reading the proposal docs and checking terminal/UI code seams to ground the audit.
Verifying code seams the docs reference: capabilities, scroll regions, OSC marks, salience, and the render engine.
## Adversarial audit

### Findings

**1. RED — Current driver is alt-screen-first; AD-U1/NC-U1 promise the opposite, and no unit fixes it.**  
North-star §3.1 and research AD-U1/NC-U1 commit to inline scrollback-native. `packages/raxol_terminal/lib/raxol/terminal/driver.ex` enters `\e[?1049h` on init; `termbox_lifecycle.ex` exits with `\e[?1049l`. The roadmap’s T2b `:inline_log` branch and T2a DECSTBM manager never address bypassing termbox + alt-screen. Building T2 on the existing path ships NC-U1’s forbidden shape by default.

**2. RED — T13 omits T5 (and T9) while north-star §2–§3 and M1 require them for S1.**  
Roadmap DAG: T13 ← T2c, T3, T7, T10–T12 only. M1 explicitly includes T5; AD-U6 (expandable diff at approval) and §3.2–3.3 (semantic blocks, salience landscape) land in T5/T9. T13 acceptance (“live session, streaming tail, sealed blocks”) can pass with empty block stubs — visually broken while green.

**3. RED — Print-once scrollback (T2b) conflicts with reattach / multi-attach (U4, T13, T18).**  
T2b: sealed ANSI “never repainted.” T13 accepts “detach + re-run shows identical transcript”; U4 is a second CLI attaching mid-run. New process has no prior scrollback; replay must re-emit history → violates T2b. Same terminal, second subscriber also duplicates history unless attach is in-process only (not what `harness-roadmap.md` U4 describes). Unpriced: `historyPolicy` behavior for printed vs in-memory blocks.

**4. RED — Overlay picker (T14–T16, T22) assumes a full Raxol grid; T2b delegates history to the terminal.**  
T14 uses `absolute_layer` + `CellDim` and “dismiss restores screen exactly.” With T2b, scrollback is terminal-owned, not in `state.buffer`. Overlays cannot dim/restore printed history; acceptance is untestable on the inline hybrid without a new overlay model (pinned region only).

**5. RED — Research/category-empty claim “F0 + R1 + mode-2026 already” is false in code.**  
`harness-ui-cohort-research.md` §7.2. `background_query.ex` is OSC 11 + DA only — not F0’s DECRQM 2026 battery. `advanced_features.ex:432-436` `query_synchronized_output_support/0` always returns `false`; detection is `TERM_PROGRAM` sniffing. T1 is a slice, not the gate F0 describes (tmux clamp, Alacritty 2026=`2`, SSH timeout). Emitting 2026 without T1 invites blind emission F0 forbids.

**6. RED — T13 acceptance requires interrupt/steer/approval but agent deps are under-specified.**  
Roadmap lists four agent touchpoints; T13 also needs U5 (interrupt), U6 (steer), U8 (approvals) for its acceptance criteria. Agent chart: U1.5 + SS block Wave 2; U5 before honest checkpointing. UI can mock journal fixtures for T7, not for “interrupt kills `sleep 30`” or live approval surface.

**7. YELLOW — Stated critical path drops T2b→T3.**  
Roadmap §1: `T0 → T2a → T2c → T13`. T13 requires T3; T3 requires T2b; T2b requires T2a. Correct longest path: **T0 → T2a → T2b → T3** (parallel **T2c**) **→ T4 → T7 → T10–T12 → T13**, gated on **U1.5**. Omitting T2b hides that the append path, not the pinned viewport alone, is the substrate bet.

**8. YELLOW — R1 incremental render vs inline hybrid: two architectures, no decision unit.**  
`harness-spec-frontend.md` §3–§4 maps `item_delta` to R1 (`backends.ex` grid diff + 2026 wrap — in flight on `pr/r1-incremental-render`). UI roadmap T2b/T2c replaces that with print-above + DECSTBM. T2c says “existing buffer-diff scoped to bottom N rows” — hybrid of both without an ADR or spike comparing flicker, bytes, tmux, and fold/search. Risk: two half-wired render paths.

**9. YELLOW — Fold/search/navigation (T4, T15, T16) vs sealed scrollback: two transcripts.**  
T2b prints sealed ANSI into scrollback; T7 keeps fold state in memory. Native find/copy see printed form; T16 searches the block list. Fold-then-seal vs seal-then-fold ordering is unspecified. North-star §3.3 “foldable, searchable” can pass in-memory while scrollback is always expanded noise — P3 “position-preserving scroll” only half-delivered.

**10. YELLOW — AD-U6 / north-star §2.2 “scroll live during approvals” has no owning unit on the T13 path.**  
AD-U6 binds to T5 (DiffViewer/ApprovalPrompt). T13 doesn’t depend on T5. P2’s highest-reaction pain is explicitly deferred past S1 while north-star §2 treats “Deciding” as co-equal with “Watching.”

**11. YELLOW — FI-U5 “last-seen offset already in the protocol” is overstated.**  
Research FI-U5 / T17. `harness-spec-protocol.md` has `attach{from_offset}` only — no per-surface `last_seen_offset`. T17 can use client-local state, but cross-surface unread (north-star §3.7, L5) needs a spec addition or stays single-surface-only silently.

**12. YELLOW — T23 cites U11 meta events; DAG omits it.**  
T23 spec: “(+U11 meta events)”; chart shows only T22 → T23. Agent lane: U11 is Wave 3, far behind U1.5/SS. C4 panels before meta substrate is a false parallel.

**13. YELLOW — T5 external dependency (#535–#540) is not a DAG node.**  
DiffViewer/ApprovalPrompt don’t exist under `lib/raxol/ui/` (grep empty). T5 is a hard external gate masquerading as “needs T4 + harness component PRs merged” with no tracking edge — M1 can stall with no named owner.

**14. YELLOW — T1 acceptance is too weak for downstream emit gates.**  
T1: “2026-terminal reads true; dumb pipe false.” Missing: tmux conservative clamp (`f0-capability-detection.md` §7.4–9), Alacritty false positive/negative, SSH widened timeout, “emit-only no probe” for OSC 133/777 (T6 needs paired emit gates). T6 can ship marks on terminals that strip OSC, breaking copy (P5).

**15. YELLOW — T0 torture list omits SSH-via-tmux and mosh.**  
T0: resize, tmux, scroll-while-streaming. North-star §3.6 and P6 name mosh/256-color; F0 §9 centers SSH→tmux passthrough off by default. A passing T0 on bare iTerm doesn’t validate the deployment path `Raxol.SSH` implies.

**16. YELLOW — DECSTBM resize/reflow semantics underspecified.**  
T2a: “recompute on resize.” Unstated: scrollback doesn’t reflow on SIGWINCH; region height vs composer growth; `\e[?7l` autowrap disabled in current driver conflicts with fish-style inline reflow; who owns cursor when printing above the region after resize. T0 should name these; T2a acceptance doesn’t.

**17. YELLOW — T3 “NVDA-shaped assertion” can pass while a11y is broken.**  
T3 accepts “no cursor-jumping sequences in flat output.” That’s not NVDA freeze behavior (cohort P6 #11002). FI-U4/T20 golden snapshots come after T13 — silent-bounce insurance arrives late for S1.

**18. YELLOW — T21 “mode-1004 shipped” overstates integration.**  
Driver enables `\e[?1004h` (`driver.ex:197`). No roadmap unit wires focus in/out to T17 unread divider or T21 escalation in the harness app — enable ≠ consume. T21 depends on T13 only; focus parsing in harness input path is unowned.

**19. YELLOW — North-star “fish, not htop” vs DECSTBM pinned strip.**  
North-star §1 credits fish for non-invasive inline enrichment; AD-U1/tmux-statusline is scroll-region surgery. Research §6.2 says “nobody cracked the hybrid” — fair, but the docs don’t reconcile fish minimalism with DECSTBM invasiveness or document the fallback when T0 fails (T3 flat shrinks T2c to “one-line prompt” — loses status strip AD-U7 “day one”).

**20. YELLOW — Observability side-channel (north-star §4, `harness-spec-frontend.md` §6) has no T-unit.**  
“Probe meta-chatter stays in advisory side-channel, never raw-appended.” No T0–T23 unit; depends on U11+ probes. North-star §3.5 “structurally honest” is incomplete for meta/provenance surfacing at S1.

**21. YELLOW — Agent-lane false parallel note applies to UI too: T18/T19 vs U4/U21 ordering.**  
Agent roadmap: U4 ∥ U9 is false parallel. T18 (reattach diff) and T19 (evidence done) can ship on fixtures before U4/U21 land, but T13 claims live reattach — same integration gap as T5.

**22. GREEN — T0-before-T2a gate discipline is sound.**  
Roadmap §3 “T0 verdict before T2a–c committed” matches research fix-caused-regression diagnostic. Keep it; expand torture matrix.

**23. GREEN — T7 fixture-driven projection is the right test substrate.**  
Aligns with agent U0 contract-only-grows and `harness-spec-frontend.md` throwaway materialized view. Correct parallel spine with T2.

**24. GREEN — NC guards (no triage v1, no blocks-as-tiles) are consistently placed.**  
Research NC-U3/U4 match roadmap §3; north-star §4 doesn’t smuggle them back in.

**25. GREEN — Salience solver exists; T8/T9 are well-scoped.**  
`lib/raxol/ui/theming/salience.ex` + tests. Research claim “H-K shipped” is true for the solver; false for harness `prominence` contract (T8). Moat is real if T9 isn’t perpetually post-S1.

---

### Critical path verdict

**Stated path (`T0 → T2a → T2c → T13`, parallel `T4 → T7`) is incomplete and slightly wrong.**

Honest path:

```text
U1.5 (+ SS for live kill/attach)
  ∥
T0 → [missing: inline driver mode, no 1049] → T2a → T2b → T3
                              └→ T2c
T4 → T7 → T5 → T10–T12 → T13
              ↑
         U5/U6/U8 for live acceptance
```

**Highest-risk unit: T0** (go/no-go on DECSTBM + print-above + tmux + resize). If T0 passes, **T2b** is highest implementation risk — it reverses the alt-screen/termbox/R1 assumption the rest of Raxol is built on. **T13** is highest *integration* risk (agent lane + render substrate + missing T5). The plan’s silent highest risk is the **undeclared driver migration** (finding 1): not on the DAG at all.

---

### Top 3 concrete changes

**1. Add an explicit unit (e.g. T2d or expand T2a): “inline harness driver profile.”**  
Acceptance: Lifecycle `environment: :harness` (or similar) skips `\e[?1049h`, uses raw `IO.write` for T2b/T2c, shares input with `BackgroundQuery`/T1 probe, tears down DECSTBM on crash. Block T2a–T13 on it. Without this, AD-U1 is prose.

**2. Re-cut S1 scope in the DAG: T13 must depend on T5 + U5/U6/U8 (or split T13 into fixture-S1 vs live-S1).**  
Either add edges and push agent dependencies into the UI critical path, or rewrite T13/north-star §2 acceptance so S1 is “live stream + pinned chrome” only, with AD-U6/§3.2–3.3 explicitly M3. Stop letting M1 include T5 while T13 omits it.

**3. Resolve the scrollback identity model before T2b ships — one-page decision in T0’s verdict doc.**  
Choose: (a) in-process subscribers only for reattach (U4 = PubSub, not second CLI), (b) reattach always replays/reprints with `historyPolicy` (T2b “never repaint” scoped to *within* one process lifetime), or (c) abandon print-above for history and keep R1 full-grid with 2026. Until then, T2b/T14/T16/T18 acceptance criteria will contradict each other.

---

**Meta:** Praise withheld. The vision/research alignment is strong; the roadmap understates substrate conflict with existing `driver.ex` + `backends.ex`, understates agent-lane gates for S1, and overstates capability readiness. T0 is the right gate — widen it and make its verdict binding on driver profile and reattach semantics, not just DECSTBM curiosity.
