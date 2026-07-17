Let me verify the key code seams that the roadmap makes claims about.Now let me check the engine backend switch, the driver/background_query, and key components.Let me check the engine backend switch and the terminal rendering pipeline.Let me verify the components the roadmap references (DiffViewer, ApprovalPrompt, BlastRadius) and the lifecycle environments.Let me check the DECSTBM handler, the absolute_layer/CellDim, and the multi_line_input to ground the composer/overlay claims.Let me verify a few more seam claims and check the tui-steal-list reference.Let me verify a couple more seam claims before writing the audit.Now I have enough grounding. Let me verify one last seam (the DECRQM response parser) and the existing scroll-region cleanup path.I've grounded the claims in real files. Here's the adversarial audit.

---

# Harness UI — Adversarial Audit

References: `NS` = `harness-ui-north-star.md`, `RM` = `harness-ui-roadmap.md`, `CR` = `harness-ui-cohort-research.md`, `F0` = `f0-capability-detection.md`, `R-04` = `harness-ui-research/04-rendering-theory.md`.

---

## Findings

### Contradictions (NS ↔ RM ↔ CR)

**1. 🔴 RED — T2b's "never repainted" promise contradicts the resize reality the research itself surfaced.**
NS §3.1: *"History is printed once and never repainted — flicker structurally impossible."* RM T2b: sealed blocks render once, *"never repainted."* But R-04 §E (resize + reflow) documents that on terminal resize, scrollback reflows corruptly — "ghost columns of stale-width wrapped text," "every intermediate width during a drag-resize getting written as a full new frame into scrollback" — and calls it *"well-documented and not fully solved by anyone in the cohort."* A block sealed at width 80 is **permanently** corrupt at width 120 if it's truly never repainted. The plan has **no unit** addressing resize-reflow of sealed history. The north star's "flicker structurally impossible" is therefore false as literally stated; it can only hold if "flicker" is narrowly scoped to streaming repaint, which the doc does not do. *(RM §2 T2b; NS §3.1; R-04 §E)*

**2. 🟡 YELLOW — OSC 133 "so even the terminal understands them" vs. tmux deployment.**
NS §3.3: blocks are *"OSC-marked so even the terminal understands them."* CR FI-U1 / RM T6: emit OSC 133 + 777. But R-04 §D states OSC 133 is **not forwarded by tmux** (open tmux #3064/#5237), and the inline model explicitly runs inside tmux/ssh (NS §3.1 "tmux keep working"). So inside tmux — a primary deployment — the terminal does *not* understand the marks. T6's acceptance ("captured stream carries correct paired marks") only verifies emission, not consumption, masking the gap. *(NS §3.3; RM T6; R-4 §D)*

**3. 🟡 YELLOW — T8 claims salience is "shipped in DiffViewer"; DiffViewer does not exist.**
RM T8: *"generalizes the DiffViewer tier mechanics to any component... shipped in DiffViewer."* `Raxol.UI.Theming.Salience` is real and shipped (verified), but there is no `DiffViewer` component anywhere in `lib/`. The DiffViewer reference is a phantom (see #10). The salience solver is genuine; the claim it was already proven in a nonexistent component is not. *(RM §2 T8; lib/raxol/ui/)*

### DAG errors

**4. 🔴 RED — T5 hangs on phantom components; the DAG hides a multi-PR build.**
RM T5: *"Mount DiffViewer (#537), ApprovalPrompt/BlastRadius (#538), tool/status blocks (#535–540) as block bodies."* grep for `DiffViewer|ApprovalPrompt|BlastRadius|HarnessBlock|HarnessSurface` in `lib/` returns **zero matches.** None of these components exist. T5 is not a "mount" unit — it's a multi-component build that the DAG prices as S–M with a single parent (T4). Because T20 (degradation CI, FI-U4) depends on T5, the research's first-order "silent-bounce insurance" is blocked on building components that aren't in the plan. *(RM §2 T5, T20; lib/raxol/ui/components/)*

**5. 🔴 RED — T13's DAG omits its dependency on T2b.**
DAG edges into T13: T2c, T3, T7, T10, T11, T12. But T13's own prose says it renders *"sealed blocks entering scrollback"* — which is T2b's entire contract. The sealed-history append path (T2b) is the load-bearing wall for "streaming tail, sealed blocks entering scrollback," yet the DAG draws no T2b→T13 edge. This hides the deepest architectural risk (a second, raw-append renderer) inside T13 and makes the critical path look cleaner than it is. *(RM §2 T13 prose vs. DAG; T2b)*

**6. 🟡 YELLOW — T2c secretly depends on T2b sharing stdout/cursor.**
T2c renders only the bottom region; T2b appends sealed history above it. Both write to the same stdout and share one terminal cursor — they must coordinate or the region paint corrupts the history (and vice versa). The DAG shows T2a→T2b and T2a→T2c as if they're independent siblings; they're not, they're co-owners of one output stream. This coordination is unpriced. *(RM §2 T2b, T2c)*

**7. 🟡 YELLOW — T20→T5 is an unnecessary dependency.**
FI-U4 (degradation floor, silent-bounce insurance) is a first-order research finding, but T20 is sequenced after T5 (phantom DiffViewer etc.). Degradation snapshots could be taken of the status strip (T10) and composer alone. T20 being blocked on T5 delays the a11y/CI safety net for no technical reason. *(RM §2 T20; CR P6)*

### Terminal-reality errors

**8. 🔴 RED — T2b's stated seam is fictional: there is no `inline_log` atom switch.**
RM T2b: *"Seam: a new `:inline_log` branch at the engine backend switch (`engine.ex` atom switch, chosen at Lifecycle start)."* The real dispatch is `safe_render_to_backend` (engine.ex:503), which switches on `state.environment` (`:terminal|:vscode|:liveview|:ssh|:telegram|:agent`). There is **no `:inline_log` atom** in the codebase. T2b is not "a new branch at an existing switch" — it's a second, parallel rendering pipeline (raw ANSI append vs. cell-buffer diff) that must coexist with the existing `Backends.render_to_terminal` frame emitter. This is a fundamental architectural fork, priced as Size M with a one-line seam description. Both the price and the seam are wrong. *(RM §2 T2b; lib/raxol/core/runtime/rendering/engine.ex:503-540; backends.ex)*

**9. 🔴 RED — T2a's "shell usable after kill -9" acceptance is unsatisfied by the described mechanism.**
RM T2a: *"teardown on exit and on crash... shell usable after kill -9 of the app."* SIGKILL (`kill -9`) **cannot be caught** — no `terminate/2`, no `at_exit`, no cleanup runs. The scroll region then persists in the terminal until something else resets it. The roadmap cites "the CSI-u stuck-state lesson" but then relies on exactly the teardown-that-can't-run to fix it. The only real mitigations are (a) the kernel tty reset on carrier loss/hangup (not SIGKILL), or (b) a watchdog/parent process — neither is in the unit. As written, the criterion is either tautological (terminals reset on hangup) or false (SIGKILL leaves the region stuck). *(RM §2 T2a; driver.ex:606)*

**10. 🔴 RED — T0 is the keystone of the entire architecture but is sized "S · throwaway."**
RM T0: *"S · throwaway, gate for everything."* T0 validates print-above-a-scroll-region mechanics — the single terminal behavior the whole inline-hybrid thesis rests on. If print-above-region fails on a tier-1 terminal, the plan collapses to flat mode (RM §3 admits this). A keystone that gates T2a→T2b→T2c→T13 is not a throwaway spike; it's the highest-risk item in the lane and should be priced and scoped as such (with a defined terminal matrix and explicit fallback triggers), not written off as scratch. *(RM §2 T0; §3)*

**11. 🟡 YELLOW — T1 under-scoped: no DECRQM reply parser exists.**
RM T1: *"add DECRQM 2026 query behind the existing DA1-style sentinel discipline."* The DA sentinel exists (background_query.ex), but there is **no DECRQM response parser** in the codebase — input_parser.ex only has comments *mentioning* that DECRQM replies get "consumed whole" (lines 39, 199). Parsing `CSI ? 2026 ; 1 $ y` mode replies is the harder half of the job; T1 prices only the query emit. *(RM §2 T1; packages/raxol_terminal/lib/raxol/terminal/ansi/input_parser.ex; background_query.ex)*

**12. 🟡 YELLOW — DECSTBM + mode 2026 composition is assumed clean; the F0 doc says it isn't.**
T2c wraps region repaints in 2026 frames. F0 §3/§9 flags that Alacritty reports 2026 support but its DECRQM value is stuck at `2`, and that composing synchronized output with scroll regions is terminal-specific. The roadmap surface units don't reference or handle these quirks. *(RM §2 T2c; F0 §3, §9)*

**13. 🟡 YELLOW — tmux treated as "mild degradation" but it's a primary deployment with three breakage modes.**
T0 lists "tmux degradation" as one spike axis. But tmux is the ssh-surface norm, and it breaks the plan three independent ways that no single unit addresses: (a) OSC 133 not forwarded (R-04 §D), (b) DECRQM probes misbehave — passthrough off by default since tmux 3.3a (F0 §9), (c) nested scroll regions (tmux pane = region, Raxol status = sub-region). None of T1/T2a/T6 own the tmux case end-to-end. *(RM T0; F0 §9; R-4 §D)*

### Acceptance-criteria realism

**14. 🟡 YELLOW — T2c "no flicker at 60fps" is perceptual, not mechanically assertable.**
The testable half ("keypress repaints touch only region rows" via byte-stream assert) is fine. The "no flicker at 60fps synthetic stream on a 2026 terminal" half is a monitor/perception claim you cannot CI. Should be restated as the byte-stream property (diff-rows-only under 2026 frames) plus a documented human-eye pass. *(RM §2 T2c)*

**15. 🟡 YELLOW — T3 "NVDA-shaped assertion" is not CI-testable; the salvageable version should be named.**
T3: *"NVDA-shaped assertion = no cursor-jumping sequences in flat output."* You cannot run NVDA in CI. The real, testable criterion — "flat output contains no cursor-move/CUP/scroll sequences" — is sound and should be stated directly, with "NVDA-shaped" as commentary. *(RM §2 T3)*

**16. 🟢 GREEN — T8/T14/T20 acceptances are genuinely testable.**
T8 ("byte-exact hexes at 1.0/0.6/0.4"), T14 ("10k items <16ms/keystroke, stale previews canceled"), T20 ("five golden snapshots in CI") are all mechanically assertable. T14 and T20 are real components (`absolute_layer.ex`, `cell_dim.ex` both verified present). These are model criteria. *(RM §2 T8, T14, T20)*

### Sequencing risk

**17. 🔴 RED — The stated critical path is T0→T2a→T2c→T13, but the real critical path is T0→T2a→T2b→T2c→T13, and T2b is the biggest unit underestimate in the plan.**
T2b is the architectural fork (second renderer, stdout/cursor co-ownership, resize-fragile). It's on the load-bearing path to T13 but (a) missing from the DAG edge into T13 (see #5), (b) priced M with a fictional seam (see #8), and (c) contradicted by resize reality (see #1). The block-model spine (T4→T7→T13) is correctly parallel, but the render-substrate spine is where the plan can die. **Highest-risk unit: T2b** (with T2a's kill-9 recovery a close second). *(RM §1 "Critical path"; §2 T2b)*

### Unpriced risks / silent assumptions

**18. 🟡 YELLOW — Three silent assumptions the plan never prices:**
(a) **Suspend/resume (SIGTSTP) / job control.** T11's `$EDITOR` handoff in an inline (non-alt-screen) app requires suspending the BEAM, handing the tty to $EDITOR, resuming, re-entering raw mode, and restoring the scroll region. No unit covers job control.
(b) **A live-event subscription bridge.** T13 "subscribe live session" assumes a SessionStreamer→surface bridge that is the agent-lane Dispatcher; the UI lane treats it as a free boundary. Correct as a boundary, but the integration surface (event shape, backpressure, reconnect) is unpriced.
(c) **Cursor ownership protocol between the append renderer and the region renderer.** T2b and T2c share one cursor; the plan never specifies who saves/restores/positions it. *(RM §2 T11, T13; T2b/T2c)*

---

## Verdict on the critical path

The plan's **shape** is right (render substrate → block model → chrome → assembly), and the parallel spine (T4→T7→T13) is correctly identified. But the **stated** critical path T0→T2a→T2c→T13 is missing its most dangerous link, T2b, which the DAG omits as a T13 dependency even though T13's prose requires it. The render-substrate chain is where the plan can die: it rests on print-above-scroll-region mechanics (T0, underpriced as a throwaway), a DECSTBM crash-recovery that SIGKILL defeats (T2a), a second rendering pipeline at a fictional seam (T2b), and a region+pinned-viewport that must compose with mode 2026 (T2c). Four consecutive terminal-reality gambles, any one of which can force a retreat to flat mode.

**Highest-risk unit: T2b** — it's the keystone of the inline hybrid, priced M, its seam doesn't exist where described, and its "never repainted" guarantee breaks on resize (the research's own #2 unsolved problem). T2a's kill-9 recovery is a close second. The plan should be re-sequenced so T0's verdict explicitly gates the T2 chain with documented fallback triggers, and T2b should be re-specified as the architectural fork it actually is.

---

## Top 3 concrete changes

1. **Re-price T0 from "S throwaway" to a keystone prototype (size M) and expand its mandate.** It must validate, on a defined terminal matrix (kitty/Wez/iTerm/GNOME Terminal/Alacritty, plain + inside tmux 3.x, local + over SSH): print-above-region mechanics, **resize reflow of above-region history**, DECSTBM+2026 composition, and tmux-nested regions. Its verdict doc must name explicit fallback triggers — *"if print-above-region fails on ≥1 tier-1 terminal, default to flat mode and collapse the region to a one-line prompt."* The entire T2 chain gates on this; it is not scratch.

2. **Re-specify T2b honestly and reprice it to L.** The seam is not an `inline_log` atom switch (it doesn't exist) — it's a forked append-renderer sharing stdout/cursor with the existing cell-buffer diff renderer. Specify the cursor-ownership protocol between T2b and T2c. And narrow the north star's "flicker structurally impossible" to "flicker on streaming repaint," then add a resize strategy for sealed history (re-emit affected blocks on width change under 2026 frames, or fixed-width sealing with a gutter). Draw the T2b→T13 DAG edge.

3. **Close the phantom-component and crash-recovery gaps.** Either (a) add DiffViewer / ApprovalPrompt / BlastRadius as real units (or confirm PRs #537/#538 are dated and in-flight) so T5 and T20 have something to hang on, or (b) redefine T5 as "build the block-body components" and price it L. Separately, fix T2a's kill-9 acceptance: state the real mechanism (best-effort `at_exit` + reliance on kernel tty reset on hangup) and restate the criterion to "shell usable after SIGTERM / clean exit / hangup," documenting SIGKILL as accepted residual — or add a watchdog unit. And add a SIGTSTP/suspend-resume unit for T11's `$EDITOR` handoff, since the inline model can't escape to alt-screen.
