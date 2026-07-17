I'll audit the harness UI design docs adversarially against each other, the research dispositions, and the real terminal/UI seams. Loading the eng-review skill and the source documents now.Pulling the agent-lane roadmap and verifying the cited code seams against the actual tree.Checking one more seam: how environment is selected, and whether fold/repaint conflicts are acknowledged anywhere.# Eng-review: Harness UI (north-star + roadmap)

## Summary

The vision is sharp and mostly disposition-aligned. The DAG is **not ready to build against**: it treats “seal history once + never repaint” and “salience / fold / jump-flash / full-screen overlays” as if they share one render model, and the critical path mis-names both the terminal mechanics and the agent-lane hard deps. Close the RED findings before T2\* commits; T0 is the right first move, but only if its failure matrix is rewritten to answer the real questions.

---

## Findings

### 1. RED — Seal-once history kills the moat (salience) and half of AD-U2

**Where:** north-star §3.2 (“older context perceptually faded”); research FI-U3 / AD-U2; roadmap T2b, T4, T8, T9, T15, T17.

**Claim conflict:** T2b makes history “written above the region, **never repainted**.” T9 assigns per-block prominence that *changes over time* (recency tier-down, needs-input promote). T4 fold/unfold, T15 “flash the target block,” and T17 unread divider all require mutating already-printed rows.

**Why it fails:** Once ANSI is in terminal scrollback, Raxol does not own those cells. You cannot fade, fold, flash, or inject a divider without rewriting scrollback (which is exactly the Ink failure mode you rejected). DiffViewer-style H-K paint only works on content still in the app buffer (T2c region).

**What the docs silently assume:** “Prominence is paint-time metadata” without saying *when paint is allowed*. Either:

- prominence/fold apply only at seal time (frozen forever after), or  
- history is soft-owned and may be rewritten under strict rules, or  
- only the live viewport is salience-graded (north-star §3.2 must be narrowed).

No unit names this fork. Highest design risk in the lane.

---

### 2. RED — DECSTBM orientation is wrong (or at best ambiguous)

**Where:** research AD-U1 + cohort brief §C (“scroll region **excluding** N bottom rows”); roadmap T0/T2a (“DECSTBM region at **bottom** N rows”).

**Terminal reality:** DECSTBM defines the **scrolling** region. The classic pin is:

- `CSI 1 ; (H-N) r` → rows `1..H-N` scroll; bottom `N` rows sit **outside** the region and do not scroll away.

Setting the region *to* the bottom N rows makes only the strip scroll — history above is non-scrolling margin. That is not “print history into native scrollback while streaming.” Research §C and Ratatui `Viewport::Inline` / vim-status patterns match “exclude the footer,” not “region = footer.”

**T0 must decide and name:** region = history (footer frozen) vs region = footer (history frozen). Current wording points at the second, which breaks the hybrid thesis.

---

### 3. RED — Full-screen keyframe path is incompatible with sealed history

**Where:** roadmap T2c (“existing buffer-diff pipeline scoped to bottom N rows”); real code `lib/raxol/core/runtime/rendering/backends.ex` `build_terminal_frame/4` (`"\e[2J" <> emit_rows(...)` on keyframe/resize/`force_repaint`); `engine.ex` State still full-screen `ScreenBuffer`.

**Why:** A keyframe clear (`\e[2J`) wipes the visible screen, including sealed history that only exists as terminal pixels. Resize today forces keyframe (`prev.width != next.width or height`). T2c “scope diffs to bottom rows” is necessary but **not sufficient** — you must also forbid full-screen clear, rehome CUP origins to absolute screen rows for the strip, and define resize without replaying history (or accept one controlled history rewrite).

No unit owns “keyframe policy under `:inline_log`.” T2c acceptance (“keypress repaints touch only region rows”) can pass while resize still nukes history.

---

### 4. RED — Overlay picker vs seal-once (absolute_layer assumes a full buffer)

**Where:** research AD-U3; roadmap T14 (`absolute_layer` + `CellDim`); north-star §3.4; code: `absolute_layer` / modal tests paint full trees into the cell grid.

**Why:** fzf-scale pickers need most of the screen. In hybrid mode the app only owns ~bottom N rows; history is not in `state.buffer`. “Dismiss restores screen exactly” is free on alt-screen or full retained buffer; **false** when history was seal-printed. Options not priced:

| Escape | Cost |
|---|---|
| Overlay only inside pinned region | Unusable for 10k-item palette |
| Overlay = temporary full-buffer redraw of recent history | Violates T2b; needs a history cache |
| Overlay = alt-screen escape | Collides with NC-U1 / AD-U1 spirit unless explicitly scoped |
| Overlay = print-over scrollback then hope | Broken on scroll/tmux |

T14 is listed “unblocked TODAY, no hard deps.” That is false relative to T2\*; it is only true as a pure component on the old full-screen backend — which is not the S1 substrate.

---

### 5. RED — AD-U6 full-screen diff expand has no unit and no substrate

**Where:** research AD-U6; north-star §2 “Deciding”; roadmap T5 (mount DiffViewer) only.

**Gap:** Expanding a diff from an approval prompt to “full screen” while “scroll stays live” is a layout/substrate problem, not a component mount. No T-unit owns expand/collapse of the pinned region height, temporary history cover, or non-alt-screen full-viewport mode. T5 can go green with a 12-line DiffViewer body while the #1 reaction cluster (P2) stays unsolved.

---

### 6. RED — T13 acceptance depends on agent units the DAG does not require

**Where:** roadmap DAG “Agent-lane touch points (only 4)”; T13 accepts; `harness-roadmap.md` U5/U6/U8.

| T13 claim | Real agent dep | DAG says |
|---|---|---|
| “interrupt kills” | **U5** supervised OS group-kill (U3 is only `%Command{}` routing) | U3 → T12 only; T13 ← U1.5 |
| “steer queues” | **U6** | missing |
| Approval / blast blocks useful in live S1 | **U8** | missing (T5 mounts components; no live gate) |
| Live session + journal identity | U1.5 + **SS** (session registry) | only U1.5 |
| Reattach half of T13 accept (“detach + re-run identical transcript”) | U4-ish attach path | T18 has U4; T13 does not |

T13 can ship a TEA shell that *sends* `interrupt` and still leave the tool process alive — green UI, red product. Same shape as agent-lane’s “bus half of keystone” failure.

Also: node is labeled `U15ext` for U1.5 — collides with agent **U15** (C3 tools). Rename.

---

### 7. RED — T2a acceptance “shell usable after kill -9” is untestable / false

**Where:** roadmap T2a.

**Reality:** `kill -9` does not run BEAM `terminate/2`, traps, or `TermboxLifecycle.cleanup_terminal/1`. Existing cleanup writes `1000/1006/1004/2004` off and `1049l` — **no DECSTBM reset** (`CSI r`) today (`termbox_lifecycle.ex:105–111`). Even clean exit is missing scroll-region teardown until T2a adds it.

Rewrite accept to: clean exit / SIGTERM / crash trap reset region; document kill -9 as *known stuck* unless an external wrapper (shell trap / parent) fixes the TTY — same class as CSI-u sticky state, not something the app process can promise.

---

### 8. YELLOW — Critical path is understated; T2b→T3 is co-critical

**Where:** roadmap §1 “Critical path: T0 → T2a → T2c → T13”.

T13 needs **T2c + T3 + T7 + T10 + T11 + T12 + U1.5**. T3 needs T2b. So the substrate spine is:

```
T0 → T2a → T2b → T3 → T13
         ↘ T2c ───────↗
```

not T2c alone. T2b (seal path + engine branch) is at least as hard as T2c (scoped diff). Calling T2c “the” critical path biases staffing toward the wrong half of the hybrid.

---

### 9. YELLOW — “Unblocked TODAY: T0, T1, T4, T8, T11, T14” overclaims

- **T1** “T0 informs” but has no edge from T0; DECRQM 2026 quirks (Alacritty stuck `Pm=2` — F0 doc) should gate emit policy after T0 torture. Soft dep should be hard or explicit.
- **T8** continuous `prominence: 0.0..1.0` vs shipped `Salience` discrete tiers (`:alarm|:recede|:differentiate|:baseline|:anchor` in `lib/raxol/ui/theming/salience.ex`). Mapping layer undefined; “byte-exact like DiffViewer” while DiffViewer is not in main tree (T5 cites PRs #535–540 as external).
- **T11** composer without T2c is a buffer component only; paste/$EDITOR OK, but “queued steer display in strip” is layout-coupled.
- **T14** — see finding 4.

---

### 10. YELLOW — Mode 2026 claims vs code reality

**Where:** research “we have … mode-2026 support already”; T1/T2c; `engine.ex:86–88`, `advanced_features.ex:235–244`, `backends.ex:31–37`.

Today: **env-sniff** `supports_synchronized_output?()` (`TERM_PROGRAM`), then wrap frames in `?2026h/l`. Not DECRQM. Not “gated on F0.” Blind emit is mostly harmless (ignored) but wrong under tmux without passthrough, and F0 already documents Alacritty DECRQM lies.

T1 is correctly scoped as a slice — but T2c accept “no flicker at 60fps on a 2026 terminal” assumes T1 is live and that 2026 alone implies human-visible zero flicker (2026 prevents *torn frames*, not bad region math). Untestable as written; replace with “no half-frame on captured 2026-aware oracle” or “region bytes only between 2026h/l.”

---

### 11. YELLOW — Resize / reflow / tmux underpriced relative to research

**Where:** research P1 + brief §C (Codex resize reflow #18575/#2086/#984; tmux corruption #29937; OSC 133 not forwarded in tmux #3064/#5237); T0 torture list; T3 ladder only `:inline_log | :flat`.

**Missing:**

- Explicit **tmux tier** in the ladder (not just `TERM=dumb`). Multiplexer is the #1 corruption host and kills OSC 133 jump features even when you emit them (FI-U1 accept “terminals without support unaffected” — true; operators *inside tmux* still get no jump).
- Resize policy after seal: terminal reflow of scrollback is incomplete across emulators; “terminal owns reflow” is aspirational. T0 must produce a per-terminal matrix, not a vibe go/no-go.
- Bubble Tea pattern of **set region → insert → reset region** (brief) is a different algorithm than “leave DECSTBM set for the session.” T2a assumes long-lived region; cohort uses transient region. Spike must compare both.

---

### 12. YELLOW — OSC 133/777 acceptance is too weak; semantics underspecified

**Where:** FI-U1; T6; research §D (OSC 133 is shell A/B/C/D; Warp 777 is proprietary agent superset).

“Paired marks per block” does not specify A/B/C/D mapping for agent turns vs tool calls, exit codes, or duration. Wrong mapping = broken jump in supporting terminals. tmux swallows them. Accept should include golden byte sequences for one turn + one tool call, and document multiplexer no-op.

---

### 13. YELLOW — Milestone order demotes the stated differentiators

**Where:** north-star §3.2 salience as core “IS”; roadmap §3 M1–M3; T8/T9 after T13 in M3.

S1 ships without salience policy, without T20 degradation CI (FI-U4), without T17 unread (FI-U5). That is a legitimate Hold-Scope cut **only if** north-star is revised: S1 is “honest stream + strip,” not “attention instrument.” As written, M2 “live” claims the product shape while the moat is M3.

---

### 14. YELLOW — False / weak acceptance criteria (can go green while broken)

| Unit | Criterion | Problem |
|---|---|---|
| T2b | “zero rewrites of prior lines” on captured stream | Passes if you never resize/fold/salience-update; fails product goals that need those |
| T2c | “60fps synthetic stream” | Not a terminal-valid metric; host can batch |
| T3 | “NVDA-shaped = no cursor-jumping sequences” | Necessary but far from sufficient a11y |
| T10 | “unknown → `—` never stale” | Needs explicit invalidation on missing `turn_completed`; easy to leave last good % |
| T13 | “identical transcript from journal” | Fold/prominence/UI-only state not in journal — define identity |
| T14 | “10k filter &lt;16ms” | Scorer-only; not full render+preview |
| T18 | summary “from replayed events only” | Good; but needs SS+U4, not just T7 |
| T21 | focus-gated | mode 1004 enable/disable exists (`AdvancedFeatures`); must not fire when focus reporting unsupported (assume focused?) |

---

### 15. YELLOW — Missing units (north-star / research promises with no deliverer)

| Promise | Source | Gap |
|---|---|---|
| Probe meta-chatter side-channel (never raw-append) | north-star §4; frontend spec §6 | No T unit |
| Working-vs-hung (stage ≠ spinner; elapsed) | north-star §2; P4 | T10 “stage” only; no hung heuristic / ticks |
| Markdown / message body quality | frontend A9 | No unit (blocks assume it) |
| Scroll-while-reading during stream (scroll lock) | research pi #4679; T0 torture | No product unit after spike |
| Multi-surface subscriber (L5) | north-star §3.7 | TUI-only lane OK, but S1 LiveView twin from frontend §7 absent even as EXT node |
| Soft fold *at seal* vs post-seal | AD-U2 | Policy unit missing (see #1) |
| T5 external PRs #535–540 | roadmap T5 | Not EXT nodes; build can block silently |
| T23 needs U11 | roadmap text | DAG only shows T22→T23 |

---

### 16. YELLOW — AD-U4 vs T22 scope cut not declared as disposition override

Research AD-U4: opt-in **persistent** side panels (lazygit grid). T22: summonable overlays only, “no persistent side-column in inline mode v1.” Fine as v1, but it is an **NC-adjacent cut** not listed under NC-U\*. North-star §3.4 matches T22 more than AD-U4. Align letter (research) with roadmap or amend AD-U4.

---

### 17. GREEN — Strong alignments worth keeping

- Thesis “instrument around a log / fish not htop” matches AD-U1, P5 asymmetry, NC-U1.
- T0 spike-before-commit matches agent U5-spike discipline.
- Block model + flat mode dual-use (a11y / CI / haters) matches AD-U2.
- FI-U2 restoration diff / anti-success-toast is correctly late-bound to U4.
- F2 not blocking T15 is correct.
- One picker primitive (AD-U3) is the right abstraction *if* substrate (#4) is solved.
- Salience solver really exists and is category-empty paint math — the moat is real; the *application surface* is the problem.

---

### 18. GREEN — Engine environment seam exists and can take `:inline_log`

`engine.ex` `case state.environment` (`:terminal | :liveview | :ssh | :agent | …`) is the right switch. T2b’s “new atom at Lifecycle start” is mechanically plausible. What is *not* free: `Backends.render_to_terminal` is full-grid CUP+diff; inline_log needs a different emit vocabulary, not a flag on the same path.

---

### 19. GREEN — Research dispositions are mostly mirrored

| Disposition | Roadmap home |
|---|---|
| AD-U1 | T0–T3 |
| AD-U2 | T4–T7, T3 flat |
| AD-U3 | T14–T16 |
| AD-U4 | T22 (weakened) |
| AD-U5 | T9 + T21 |
| AD-U6 | **missing** (#5) |
| AD-U7 | T10 |
| FI-U1–5 | T6, T18, T8, T20, T17 |
| NC-U1–4 | §3 guards |

---

## Coverage by checkpoint (skill)

1. **I/O** — ⚠ block/event shapes gestured (T7) but OSC mark grammar, fold state ownership, and command payloads for expand/jump underspecified.  
2. **Data flow** — ⚠ journal → blocks → seal vs live tail is the right sketch; missing flow for salience updates and overlay restore.  
3. **State machine** — ✗ no explicit modes: `inline_log | flat | (overlay?) | expanding_diff | degraded_tmux`.  
4. **Error paths** — ⚠ T10 `—`; weak on cap-query hang (T1 good intent), stuck DECSTBM, 2026 false positive.  
5. **Concurrency** — ⚠ T14 stale preview cancel good; stream+resize+seal races unstated.  
6. **Recovery** — ⚠ T2a crash path incomplete; no Ctrl-L recovery story under seal-once (R1 has force_repaint — lethal if full clear).  
7. **Test matrix** — ⚠ fixture-driven T7 is good; hybrid needs byte-stream + real-terminal matrix from T0, not only unit asserts.  
8. **Foundation invariants** — ✗ FI-U3 vs T2b; FI-U1 tmux; FI-U4 after S1.

---

## Verdict on critical path

**T0 → T2a → T2c → T13 is not the right critical path as stated.**

**Corrected substrate spine:**

```
T0 (go/no-go matrix)
  → T1 (emit gates from real caps)
  → T2a (region lifecycle + teardown; orientation fixed)
  → T2b ∥ T2c  (seal path and pinned diff are co-equal)
  → T3
  → T4 → T7 → T10
  → T11 → T12 (+ U5 for real interrupt)
  → T13 (+ U1.5 + SS; U6 for steer accept)
```

**Highest-risk unit:** not T13 — **T2b** (or the unresolved T2b↔T8/T9/T4 contract). T2c is hard but localized; T2b decides whether the entire north-star (fade, fold, jump flash, picker restore, full-screen review) is even possible. T0 is the gate only if it is forced to answer that contract, not just “does DECSTBM kinda work in kitty.”

**Second-highest risk:** T13’s fake agent deps (interrupt/steer without U5/U6).

---

## Top 3 concrete changes

1. **Write a one-page “paint authority” invariant** (amend north-star §3 + roadmap foundation):  
   *What may be rewritten after seal?* Freeze options: (A) seal-time paint only, (B) soft history cache + controlled rewrite, (C) live-region-only salience/fold. Make T8/T9/T4/T15/T17 depend on that choice. Do not start T2b until this is chosen.

2. **Fix T0/T2a terminal model and acceptance:**  
   - DECSTBM = scrolling history region, footer **outside** (unless spike proves otherwise).  
   - Compare long-lived region vs Bubble-Tea transient set/reset.  
   - Per-terminal matrix: resize, tmux, scroll-while-stream, SIGTERM cleanup (`CSI r`), kill -9 = out of scope.  
   - Explicitly ban full-screen `\e[2J` keyframes on the `:inline_log` path; add a T2\* sub-acceptance for resize without history wipe.

3. **Rewire the DAG for honesty:**  
   - Critical path includes **T2b→T3**, not only T2c.  
   - T13 depends on **U5** (and U6 if steer is in accept); SS as EXT; drop “only 4 touch points” or list the real ones.  
   - Add units (or explicitly NC): **AD-U6 expand layout**, **overlay substrate under hybrid**, **tmux degradation tier**, **meta side-channel**.  
   - Move T14’s hard dep to “T2\* resolved or buffer-mode-only prototype.”  
   - Rename U15ext → U1_5ext.

---

**Recommendation:** structural revision on the render contract (checkpoint 2/3/8 failed), then implement T0 with the revised matrix. Do not staff T2a–T2c in parallel with T8/T9/T14 as if they compose — they currently don’t.
