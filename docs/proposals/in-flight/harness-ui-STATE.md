# Harness UI — STATE ledger

Updated: 2026-07-16 (FULL DESTALE — Drew merged the W1 wave; tables reconciled).
States: planned · building · committed · PR#n · merged · blocked.

## MERGED (on master)

**W0:** T0 #554 · T1 #552 · T4 #548 · T11 #549 · TF #551 · TP #550 · TB #553 ·
TE #555 · invariant suite #556.
**W1 (Drew merged 2026-07-16):** T2d #565 · T7 #562 · T8 #560 + T8b #568 ·
T26 #563 · T14 #561 · T27 #564 · T28a #567.
**Agent lane (other split, merged):** TH #557 · SS #558 · MS #559.
**EXT block components:** #535–#541 ALL MERGED (transcript/tool/diff/approval/
projection/status-bar blocks + palette origin) — T5's EXT dep is SATISFIED.
**D-PA:** RB ran live; RULING in roadmap §0 = ship (A) seal-time-only, (B)
runtime-detected per-terminal (iTerm2 reflow measured). No longer :pending.

## OPEN PRs (this lane — merge authority is Drew's/V's, never mine)

| PR | unit | state |
|----|------|-------|
| #574 | T2a scroll-region manager | Drew adversarial review CONCERNS (1 HIGH: degenerate `CSI 1;1r` silently unpins footer — real terminals ignore top==bottom; 3 MED: unconditional resize re-emit + cursor-home side effect, dual DECSTBM owners IOAuthority vs SRM, moduledoc arity/jargon; 3 LOW). Fix commit BUILDING (Sonnet, review-response commit on same PR). |
| #589 | T2b append path (keystone) | Opus SHIP; stacks on #574 branch — rebases after T2a fix; merge after #574. |
| #585 | RB Ring-B driver | Opus APPROVE; live-matrix rerun deferred (watched-only). |
| #588 | docnit tp_pty :skip_on_ci | green; inline_driver moduledoc fix folding in (T2d merged → unblocked). |

**Agent-lane open PRs (other split, FYI):** U*-R red suites #569–573, #581–587
(U4/U5/U6/U7/U8/U9/U10/U11/U12/U21) — these are T13b's deps materializing.

## IN FLIGHT (W3 — M1 fan-out)

- **T3** degradation ladder: RED fixed (degenerate now outranks tmux, corner
  regression-pinned both signal paths) → d5e09c89 → **PR #593** (stacked on
  #589 — needs InlineAuthority+degenerate?/2).
- **T5** block bodies: built dcbbbc5b (BodyProvider schema contract +
  fold-aware mount; block.ex :diff clause verified additive/collision-free vs
  T26/T8; telemetry name distinct from both :recovered events). Opus review
  **RED**: expanded mount lacks try/rescue — a schema-valid-but-crashing body
  ESCAPES to the render loop, reachable via a REAL approval event missing
  blast_radius (BadMapError from BlastRadiusPreview) — moduledoc claimed
  total-safety falsely. Fix amending (rescue → existing {:error}
  fallback+telemetry; + Y1 blast_radius ||%{} default). Same lesson class as
  T3's RED: SAFETY CLAIMS GET TRACED, NOT ASSERTED.
  → FIXED f9aa053a (rescue at BlockBody, the promise-making layer; both
  vectors red-proven; blast_radius ||%{} renders real prompt) → **PR #594**.

W3 COMPLETE (all 4 leaves PR'd): #591 T10 · #592 T12 · #593 T3 · #594 T5.
T13a BUILT e87d44aa (fusion: 4 clean merges, zero conflicts): HarnessSurface
TEA core + ViewText bridge + 9 acceptance tests (1039 suite green) + demo
`mix run --no-start examples/harness_fixture_demo.exs [fixture] [--speed ms]`.
All 7 preconditions honored with moduledoc sections. DESIGN FINDING: T7's
BlockBuilder only emits completed(=sealed) blocks, so "fold pre-seal" needed
an assembly-level painted_count high-water + hold-newest-back-one-step —
possible T7 contract gap (a distinct completed-not-yet-sealed phase), flag
as follow-up. Opus review: **SHIP, no RED** — held-back block VISIBLE in
footer preview (not a lie); painted_count strictly monotonic (double-seal
impossible, test-asserted); keymap-first on EVERY input path; immutable-prefix
at every checkpoint; flat scanner fail-closed; \e[K + newline-push-up honored.
7 yellows: folding Y1 (sealed-fold silent no-op → footer notice), Y2 (unicode
fixture end-to-end), Y3 (resize test real geometry change), Y5+Y7 (doc
honesty: hold-back one-per-advance limit; teardown ownership). Declined: Y4
(synthetic RED half — GREEN half is the real guard, noted). BACKLOG: Y6 =
T7/T9 follow-up unit — Block lifecycle needs a distinct completed-but-not-
yet-sealed phase (assembler works around it via painted_count high-water +
fold_after_seal :allow, T9's intended seam).
→ Yellows FOLDED 1093a646 (notice + unicode suite + real-geometry resize +
doc honesty; Y3 fix caught a real subtlety: pre/post-resize replays must use
the SAME emulator width or false prefix-violation) → **PR #595** (M1).

## M1 STATUS: BUILT + REVIEWED + PR'd. 10 open PRs, all green:
#574 T2a → #589 T2b → #590 T2c → {#593 T3, #595 T13a(M1)} · #594 T5 ·
#591 T10 · #592 T12 · #585 RB · #588 docnit. Merge order: spine first.
DRAFT status = blocked-by-base: #589/#590/#593/#595 are GitHub drafts until
their base PR merges; #574/#585/#588/#591/#592/#594 are ready (master-based).
UNBLOCK RITUAL as bases merge: retarget child PR to master (gh api PATCH
base), rebase branch, mark ready (gh pr ready).
Demo (playable now): cd .claude/worktrees/agent-afcae528f737e0469 &&
mix run --no-start examples/harness_fixture_demo.exs [fixture] [--speed ms]
NEXT (post-merge wave): T13b live wiring (needs agent-lane U1.5/U5/U6; SS
merged) · T6 · T9 (binding model decided) · T20 degradation CI · T7
completed_but_unsealed phase (Y6 follow-up) · T15-T17 nav polish.

NOTE (2026-07-16 ~16:00): the OTHER session (agent lane, U9/U11 work) stashed
all untracked in-flight docs (`git stash -u`, stash "pr/r1 wip before U9
work") and detached the primary checkout. Lane docs live in that stash's ^3;
canonical working copies extracted to this session's scratchpad/lane-docs/.
RECONCILE this file back into docs/proposals/in-flight/ when the checkout is
restored. Two sessions share one checkout — coordinate via stash, never clean.
- **T10** status strip: SHIP → **PR #591** (context_pct live-vs-snapshot
  surfaced as T13a decision in moduledoc).
- **T12** keybinds: SHIP → **PR #592** (shape-match proven vs real T27
  emitters; Tab=steer, ESC=interrupt :always).
After T3+T5 land: **T13a assembly** (M1 — first visible harness).

## T13a PRECONDITIONS (accumulated from reviews — assembly acceptance inputs)

1. Input-shape shim (from T11 re-review, earlier): driver `key: :char` /
   integer shapes vs component `key: "a"` — T27 canonical layer is the fix;
   wire ALL surfaces through it.
2. **Dispatch order (T12 Y1): keymap-first for `:always` binds.** T11's
   composer catch-all delegates every unhandled key into MultiLineInput —
   component-first wiring kills ESC-interrupt AND Tab-steer dead.
3. Focus model must resolve ESC-always vs ESC-to-close overlays (T12 Y3 /
   T14) and own composing?/focused_block_id context for the keymap.
4. context_pct producer semantics (T10 Y1): decide live vs turn-boundary
   snapshot; if live, relax the strip's turn_completed gate to a
   context_fresh liveness flag. NEVER fake turn_completed mid-turn.
5. Footer contract (T2c): compose `resize |> keyframe`; pre-truncate lines
   via TextMeasure; check degenerate?/1 before assuming a pin.
6. Command bifurcation (T12 Y2, for T13b): :interrupt/:steer cross to agent
   lane as %Command{}; :fold_toggle/:jump_* stay UI-local.
7. Seal path on dirty screens (lesson #4): \e[K discipline / newline push-up
   at startup.

## DONE THIS SESSION (housekeeping wave, 2026-07-16)

- T2a review response 091353505 on #574 (HIGH degenerate→\e[r + degenerate?
  signal; resize geometry-gated; ownership doc; red-first both fixes; response
  comment posted). Chain rebased: T2b 9a79cdbb → #589; T2c folded yellows
  (footer content-render pin \e[K red-proof, degenerate tests, width-contract
  doc, degenerate?/1 delegation) → 5ac66747 → **PR #590** (stacked on #589).
  Merge order: #574 → #589 → #590.
- #588 upgraded: + T28a destale (inline_driver moduledoc rewritten to
  T28a-fixed/T28b-open split; UNSKIPPED the graceful-stop teardown test that
  T28a's merge left dangling — swept 30/30, retagged SIGTERM test to T28b).
- STATE fully destaled (this file).

## UNLOCKED NOW (deps merged — next fan-out after housekeeping)

| unit | needs | note |
|------|-------|------|
| T3 degradation ladder | T2b ✓(branch) | base on T2b branch until #589 merges |
| T5 block bodies | T4 ✓ + EXT #535–541 ✓ | base master; Block content-map contract first (advisory note below) |
| T10 status strip | T7 ✓ | base master |
| T12 keybinds | T11 ✓ | base master |
| T6, T9 | T2b/T4 ✓, T7/T8 ✓ | T9 binding model decided (below) |
| T25 | T11 ✓ T2d ✓ TP ✓ | base master |
| T28b | T28a ✓ | SIGTERM Facet-2 rework (deadlock fix + one-per-VM + :on_teardown) |

**M1 = T13a** (first assembled visible harness, fixture-driven): remaining
T2c(review) + T3 + T5 + T10 + T12 + assembly. **M2 = T13b** (live agent):
+U1.5/SS✓/U5/U6 from agent lane.

## SESSION LESSONS (2026-07-16, logged so they stop recurring)

1. RB GUI matrix: WATCHED-ONLY, never unattended (stuck close-sheets on
   background Space; Guard still_open?+keystroke insufficient there).
2. Builder agents MUST get isolated worktree + shell. A no-Bash lightweight
   builder edited files INSIDE the T2b review worktree (cleaned; redone right).
3. Primary-checkout branch-pointer wobble happened TWICE (agents branching in
   the shared repo). Worktree isolation is mandatory, verify after every agent.
4. Inline substrate on a dirty screen: sealed lines MUST clear-to-EOL (\e[K)
   and startup must push existing screen content into scrollback via newlines
   (NEVER \e[2J). Found via first real-tty demo run (examples/
   harness_substrate_demo.exs in the T2b worktree — throwaway, uncommitted).
   → T13a input; consider a small T2b follow-up (seal path \e[K).
5. T2c resize CONTRACT: resize/3 does NOT auto-repaint footer (T2b regression
   pins resize bytes = DECSTBM re-set only); callers compose
   `resize |> keyframe`. T13a assembler must know.
6. `mix run` demos: use `--no-start` (InlineAuthority is pure; app boot logs
   interleave the byte stream otherwise).
7. Deferred cosmetics: T2b review yellows #3 (new/5 guards width only) + #4
   (direct region_top field access) — documented, not fixed.
8. BACKLOG (T3 review side-find): SequenceScanner.scan/2 infinite-loops on a
   lone trailing \e at EOF (matches 0x1B, slices zero, recurses unchanged).
   Hangs rather than falsely passes, so fail-closed holds — but the shared
   test oracle needs a guard clause. Micro-fix, any future changeset.
9. T3 review RED (caught pre-push): tmux-before-degenerate ordering shipped a
   history clobber — at degenerate geometry InlineAuthority pins next_row=1,
   every seal overwrites row 1 PRE-scrollback. Degenerate now outranks tmux.
   LESSON: "graceful degradation" claims must be byte-traced, not asserted.

## HISTORY — W1 review-round fix loop (all now merged)

| unit | state | sha | PR | note |
|------|-------|-----|----|------|
| T2d  | merged (CI blockers + init-crash trap + stty execve) | 16016690 | #565 | was BLOCK, then green |
| T7   | merged (forward-id-gap→:damaged + tail-key + delta-cap) | 4b0dd816 | #562 | |
| T8   | merged pre-Drew-fix; follow-ups: block.ex → #563, prominence.ex → T8b #568 | e94442dd | #560 | merged BEFORE T26 (order flipped) |
| T8b  | merged (ground-validation + neg-prominence + wcag-guard + ceiling + de-jargon) | 36a8add7 | #568 | prominence.ex only |
| T26  | merged (review fixes + deterministic cap + rebase onto T8 + markdown-fade union) | eac96bc3 | #563 | absorbed block.ex union; Drew fade-gap closed |
| T14  | merged (K-clamp + allowlist + empty-label) | 3f7a13d2 | #561 | |
| T27  | merged (real keycodes + wire composer + state + validate) | ced9442f | #564 | EventTranslator keycodes were wrong repo-wide (verified vs termbox2.h) |
| T28a | merged (sequence-order assert, not timestamp) | 6c598bac | #567 | trap_exit + driver-first |
| T28b | planned (Facet 2 reworked, after T28a) | — | — | SIGTERM deadlock fix |

Upstream bugs found during W0 (backlog, separate micro-changesets):
- handle_ri (control_codes.ex:339) destructures {_col, row} — RI's at-top
  scroll-down check wrong, exact mirror of the LF bug TE fixed; handle_hts
  (:331) sets tab stop at ROW. Same swapped-tuple class, found by TE review.
- Dual region stores (emulator.scroll_region vs buffer region) — coherent
  per-path, latent debt, future unit.
- CI FLAKES (reddened W1 PRs #560/#561, both green on rerun, neither in the
  changeset): (1) TP drain-barrier tp_pty_test.exs:174 20x-loop → :spawn_timeout
  under loaded CI macos — widen CI spawn_timeout / tolerate one retry; it will
  intermittently redden every full-suite PR run. (2) modal_demo_headless_test
  cross-terminal render assertion — pre-existing flake. Both backlog.
- **Lifecycle shutdown bug (T2d find, ALL environments)**: Lifecycle.Shutdown
  .stop_process/2 does GenServer.stop(pid, :shutdown) but neither Lifecycle nor
  caller traps exits → first dependent's :shutdown cascades as fatal EXIT
  through the untrapped start_link link. Raxol.stop/1 NEVER reaches the Driver's
  terminate/2 in any environment → graceful-stop teardown/cleanup doesn't run
  today. Own dedicated unit — affects terminal/ssh/agent, not just :inline.
MultiLineInput dispatch_key sends {:input, binary} where EditOps expects
integer codepoint (single-key typing path crashes); TextHelper wrap drops
trailing blank line on values ending in "\n".

Advisory-derived notes for future dispatches (longcat, T4-concept):
- T7 MUST retain raw events (not just block structs) — D-PA policy (B)
  re-emission and retroactive opaque-kind recognition both need re-fold.
- T5 prerequisite: define the Block content-map schema as an explicit
  contract (per-kind shapes / BodyProvider seam) BEFORE mounting components.
- T9: centralize D-PA verdict in one ambient resolver; Block's per-call
  fold_after_seal opts stay as the test-override seam.
- Width is a render arg, never baked into content (verified) — keep it so.
- T9 BINDING MODEL (Fable decision, corrects 05-salience.md floor-everywhere):
  prominence resolve = PURE ground-aware fade, no floor by default (the
  gradient is the moat; context recedes; "faded not lost" = legible-on-
  promotion-to-1.0, not at-a-glance). Floor is OPT-IN (`legibility_floor:
  true`), set by T9 ONLY for acting tiers (current-turn / needs-input /
  composer). T9 promotes focused/approval blocks to full prominence for
  recoverability. Floor is truecolor-only; 256-color needs a redistributed
  tiers_for(ground, :color256) ladder (deferred) — T9 must not assume the
  clamp survives quantization.
- T18/T13a IDENTITY CONTRACT (Fable, from T7 longcat advisory): T7 exposes
  TWO keys. transcript_identity/1 (event_refs-keyed, excludes fold_defaults +
  recovered_reasons) = T18 reattach-consistency + restoration-diff key (an
  event_refs-keyed diff, recovered-reasons masked, NEVER a position-only diff,
  NEVER diff the tail directly — tail→seal shows as "new block appeared").
  identity/1 (full + fold_defaults) = T13a regression-freeze snapshot key.
  T18 INVARIANT: reattach converges only when replay is in journal offset
  order (never a peer's live tail); ids strictly monotonic, offset canonical.
- T2a WIRING NOTES (from T1 review, both yellows carried): (1) the probe
  driver loop must re-derive `remaining = deadline - now` each iteration —
  a resetting `receive ... after budget` is defeated by a flooding terminal;
  (2) the full clamped Capabilities record is the emit-gate authority —
  `sync_output?/0`'s raw mode_replies fallback bypasses the tmux clamp and
  must not answer in multiplexer contexts.
- T13a PREREQUISITE (from T11 re-review): system-wide input-shape gap —
  driver paths emit `key: :char, char: "a"` (InputParser) / integer keys
  (termbox converter) while components match `key: "a", modifiers: []`.
  Nothing typed ever reached MLI through the driver. T13a needs an input
  normalization shim at the surface boundary (mini-F1a slice) or typing is
  dead in the assembled app. Budget it into T13a's spec.
TRIAD+Opus VERDICT on T28 (2026-07-16): 4 reviewers converge. Facet 1 (trap_exit
+ terminate/2 driver-first) CLEAN — die-together + restart preserved (Opus+all
grok). Facet 2 (SIGTERM handler on :erl_signal_server) RED — self-deadlock:
handle_event runs IN erl_signal_server, stop_and_await blocks it, terminate/2's
:gen_event.delete_handler waits on that same callback → circular wait → 5s stall,
System.stop fires via timeout mid-terminate → terminate_manager severed. Hidden
by the excluded/under-asserting :integration pty test. SPLIT: ship Facet 1 (merged
#567), rework Facet 2 (=T28b). Longcat: supervision-tree-native (driver as ordered
Supervisor child, rest_for_one) is the eventual end-state that drops signal-hijack
entirely — future.

## PLANNED (post-M1 unless noted)

| unit | needs | note |
|------|-------|------|
| T13a | T2c+T3+T5+T10+T12 (rest ✓) | M1 assembly; budget the input-shape shim (advisory below) |
| T13b | T13a + U1.5/U5/U6 (agent lane; SS ✓) | M2 live |
| T15/T16/T17 | deps ✓ (T14,T4,T7) | nav polish — unlocked but post-M1 |
| T18 | T7 ✓, U4 | reattach |
| T19 | T4 ✓, U21 | evidence |
| T20 | T3, T10 | degradation CI |
| T21 | T13b | |
| T22/T23 | T14 ✓, U14/U11 | |
| T24 | T5, T2c | diff expand |

W0+TE+TB MERGED. W1 PRs got Drew (DROOdotFOO) adversarial reviews — all CONCERNS,
#565 BLOCK(red CI). Meta-theme across all: "test built so it can't catch the bug"
(synthetic maps not driving real emitters; single-golden prefix walks; no forward-
id-gap fixture). Opus analysts triaged each → Sonnet fixers (amend-in-place):
- #561 T14: DONE 3f7a13d2 — K-clamp (slice raw key before split; 1M label 0.7ms) +
  props-allowlist + empty-label + doc. longcat-confirmed. Pushed.
- #565 T2d: 2 CI test-bugs (positional byte-order assert; precondition-gate SIGSTOP)
  + HIGH init-crash trap+restore + SECURITY stty-interp validation. FIXING
- #562 T7: HIGH forward-id-gap → :damaged flag (hard-mark/soft-render) + telemetry +
  the missing gap test (violates merged #556 invariant); composite tail key; delta cap. FIXING
- #564 T27: HIGH agreement-is-fiction → fix EventTranslator control-keycodes +
  drive real emitters in test + WIRE composer (was dead code) + carry key state. FIXING
- #563 T26: analysis pending → fixer next (nested-emphasis leak, mid-grapheme mojibake,
  ANSI-from-LLM security, O(N²) render cap).
- #560 T8: fix REBASES onto fixed-#563 (markdown-body-fade test only exists merged) +
  ground-validation + jargon-strip + memoize. HOLDS for #563.
longcat cross-checks of Drew's findings running in parallel (held to compare vs fixes).

RB DONE 92790747 (PR-pending review): automated Ring B ran LIVE. C-2 fed on
iTerm2/wezterm/kitty (3/3 tier-1). C-4: iTerm2 REFLOWS (=(B) real, 1 tier-1).
N06: \e[2J wipes scrollback on wezterm/kitty (validates keyframe-ban). Resolver:
provisional (A). D-PA RULING (roadmap §0): ship (A), (B) runtime-detected per
terminal. AUDIT #1 RISK RETIRED. Async-modal safety bug caught+hardened (Guard
still_open? + keystroke fallback). 17 ringb tests, :ring_b/:macos_gui excluded.
RB v2 follow-up: generic AXUIElement text-reader (covers ghostty, no per-app API).

RB (NEW unit, building): automated Ring B driver — device-control terminal
matrix (iTerm2/wezterm/kitty/Terminal.app via osascript/cli/@), measures
C-1..C-4/N06/N07 programmatically, writes verdict + runs resolver. Tagged
:ring_b/:macos_gui, CI-excluded, runnable via `mix t0.ringb`. RETIRES the
manual Ring B gate (the audit's #1 risk → automated, re-derivable any time).

RING B — C-2 KEYSTONE MEASURED via device control (2026-07-16, osascript+CLI):
scrollback-feed FED on iTerm2 (tier-1, osascript contents), wezterm (tier-1,
wezterm cli get-text), Terminal.app (osascript history) — 100/100 lines in
order on every real terminal + tmux-proxy fed earlier, ZERO lost. The core
inline-hybrid assumption (the audit's #1 unvalidated risk) is VALIDATED — worst-
case "flat mode primary" is OFF the table. Resolver still formally :pending
because my own C1∧C2-join fix requires footer-pin (C-1) + cursor (C-3) measured
alongside C-2 — those need mid-stream capture + precise sizing (harder). kitty
remote-control flaked headless. C-4 (resize) = the A-vs-B differentiator, unmeasured.

W1 100% MERGED (2026-07-16, master a25bfca8, green): #561 T14 · #562 T7 ·
#563 T26(+markdown-fade union) · #564 T27(+real keycodes) · #565 T2d · #567
T28a · #568 T8b. Verified all late fixes on master. Drew self-fixed 2 CI issues
during merge: (a) #565 Tier-B pty describe → :skip_on_ci (mix-run app can't
cold-boot in CI 15s); (b) #567 REAL cross-unit telemetry collision — Block AND
Projection.Recovery both emitted [:raxol,:harness,:projection,:recovered];
Drew renamed Block's → [:raxol,:harness,:block,:recovered]. LESSON: shared
telemetry names across units are a latent collision the fusion should catch.

W2 SPINE HISTORY (compressed — current state is in the header tables):
T2a 3f7fde81 → PR #574 (Opus SHIP, then Drew CONCERNS → fix in flight). T2b
bcc2d732 → yellows folded → 2c9de129 → PR #589 (Opus SHIP; genuine fail-first,
INV-5-A byte-exact, try/after cursor guard). T2c 80331f1a built (in review).
RB 92790747 → yellows fixed compile-only 7eb60994 → PR #585 (Opus APPROVE).
GATE-1/D-PA: closed by RB measurements + Fable ruling (roadmap §0).

Preview-demo intel for W1/W3 (from the fusion demo build):
- normalize_for_composer/1 shim in the demo = the working prototype of T13a's
  input-normalization prereq (driver shape → component shape).
- T13a needs a real focus model (composer-focused vs transcript-focused);
  the demo's flat keymap steals j/k/s/z from typing.
- T7: Block duration_from_timestamps picks the first started/completed pair
  in merged tool_use+tool_result lists — projection layer owns the fix.


## RESEARCH FEEDBACK INTAKE (V's TUI-track analysis, 2026-07-16)

Verdict: lane ahead of the report's core findings (R1 grid-diff shipped;
inline-vs-alt-screen owned; Zed lessons absorbed; thin-UI ethos). Three blind
spots ACCEPTED + landed as hardening (builder on T13a branch, new commit):
1. Unbounded projection memory → 5k-block bounded-heap acceptance at T13a;
   ScrollWindow (on branch) named as the virtualization substrate.
2. BEAM sub-binary pinning (stream chunks pinned by block-content refs — the
   leak class BEAM adds vs Node) → :binary.copy at the seal/retention
   boundary + referenced_byte_size test; possible T7 BlockBuilder follow-up.
3. No keystroke-path budget (Ink's exact failure path) → composer-echo
   byte-bound suite: footer-rows-only + bounded bytes/keystroke + linearity
   property over typing bursts.
4. BEAM-position paragraph added to north-star (GC lesson sidestepped by
   design; install weight + heap residency stay tracked, not dismissed).

CROSS-CUTTING (V to arbitrate / both lanes):
- Eval-first: UI lane now has render+memory+latency evals; agent lane lacks
  the structure — their call.
- DISTRIBUTION/INSTALL WEIGHT: unowned by either lane. Options: burrito/
  bakeware-style single-binary packaging as a UI-lane backlog unit (harness
  is the shipped artifact) vs core-repo concern. OPEN — needs V's ruling.
- Falsifier meta-pattern (binding for future units): anything built atop
  model behavior (or platform weakness) ships with a measured exit
  criterion — the report's graveyard was compensators that outlived their
  reason. Applies to: interrupt stubs (exit = U5), tmux_conservative tier
  (exit = T0 re-measure on tmux 3.4+), (A)-vs-(B) paint authority (exit =
  RB C-4 on more terminals).


## ROUND-2 CLOSE-OUT (Drew adversarial reviews, 2026-07-16)

Drew posted adversarial reviews on all 10 PRs. Adjudicated by 4 parallel
Fable decision-makers (FIX-NOW / DECLINE / DEFER-with-exit / ALREADY-ADDRESSED);
9 Sonnet fixers landed every FIX-NOW. Content-injection class closed at all
four seams with empirical red-proofs (pre-guard OSC set the emulator window
title; dangling CSI ate the next block's leading byte — "block one lock two").

Reply ledgers drafted per-PR (10 Fable agents) and posted to each PR:
accepted-fixed (with sha) / declined (rationale) / deferred (exit criterion).

DECLINE/DEFER ledger (exit criteria):
- moduledoc-jargon pass → lane→master
- O(n²) replay → T13b entry
- CharacterHandling Emoji_Presentation width table → raxol_terminal backlog
- BlockBody recovered-log dedup → before live streaming
- T12 command-parity test → T13b acceptance
- :diff absent-payload state → first real :diff producer
- RB sheet-scoped dismissal → next watched matrix
- tp_pty CI quarantine → own lane
- dying-tty atomicity, negative-cost display, T10 float-width,
  T12 opaque block_id, RB Task.Supervisor → DECLINED (rationale in PR replies)

### T13a branch divergence RESOLVED (2026-07-16)
Drew pushed b2c31128c "sanitize view_text line content" (sanitize_cell/1 in
lines/3: strips C0 incl \n + DEL) DIRECTLY onto feat/harness-ui-T13a while the
finisher chain built in parallel. Reconciled via merge 3f22b57fe (Drew's commit
kept as a parent — NEVER force-past a collaborator's commit):
- KEPT the split-newline variant (add_lines/3 splits embedded \n into one
  collected line per row = correct one-row-per-line accounting; Drew's strips
  \n → joins rows, lossy). This is the superset.
- FOLDED IN Drew's DEL-strip: 0x7F is >= 0x20 so the prior allowlist wrongly
  passed it. sanitize/1 guard is now `(byte >= 0x20 and byte != 0x7F) or byte == ?\t`.
- REMOVED Drew's redundant lines/3 seam — add_lines/3 is the SOLE builder of
  the {content, style} entries and scrubs each before lines/3 sees them.
- KEPT Drew's injection test (renumbered describe "9." — "8." is memory-residency);
  passes against split impl (ESC stripped, printable residue survives). 18 passed.
Courtesy note posted to #595 explaining the supersession.

## STILL ON V'S DESK (unattended-blocked)
1. RB width-only-resize DECSTBM-persistence probe — WATCHED run only (~2 min of
   V's eyes across iTerm2/wezterm/kitty/tmux). GATES #574 merge (Fable A ruling).
   Probe not yet added to the RB branch.
2. Cross-lane payments finding — validate_base_url!/1 in agent_stream.ex (#576,
   MERGED) does prefix matching bypassable by `localhost.evil.com`, and raises
   inside an unlinked Task. NOT this lane's code — route to agent/payments session.


## RB PROBE RESULT — width-resize DECSTBM persistence (2026-07-16, WATCHED w/ V)
Manual probe (region rows 3..10, header outside on rows 1-2, width dragged
mid-sequence, more content written after) across the full matrix:
- Terminal.app / iTerm2 / WezTerm / kitty: TRUE mid-resize (zsh `read` paused,
  V resized width, Enter, THEN AFTER lines printed). Margins PRESERVED in all
  four — header intact, content confined to region.
- tmux: region held, BUT pause didn't fire (pane shell is ksh-family, `read -rp`
  errored "no coprocess") so not a true interleaved-resize reading. tmux is a
  full emulator and preserves its own region across resize; screenshot confirms
  header intact.

VERDICT: no terminal resets DECSTBM on width-only SIGWINCH. #574 zero-byte
resize gate VALIDATED, probe is the cited measured basis. Posted to #574.
Exit criterion for the T2a HIGH deferral = MET (gate stays, cited).

SUBSTRATE NOTE (not a gate issue, reinforces `:tmux` mode): under tmux,
content scrolled out of the region lands in TMUX's scrollback (revealed by
growing the pane / copy-mode), not the host terminal's native scrollback.
Confirms tmux is a distinct substrate — the reason `:tmux` mode + the
tmux_conservative tier exist. Growing the tmux pane pulls scrolled-out history
BACK into the grid (tmux reflow) — a height-resize concern already covered by
the needs_keyframe latch, not width.

TODO: fold probe into RB branch as a recorded unit (automated GUI-driven resize,
no interactive pause) so it re-runs on the next watched matrix. Optional: a
TRUE mid-resize tmux reading by forcing bash for the pause (`read -rp` is
ksh-incompatible) — low value, tmux region-preservation already confirmed.


## WIDTH-AXIS REFLOW FIX (from RB probe, 2026-07-16) — T2c 5d6fc5f7a
Probe exposed a structural bug: `resize/3` gated needs_keyframe AND the
reflow_capable_resize telemetry on `ScrollRegionManager.geometry_changed?/2`,
which is VERTICAL-only (history_bottom, row-based). Reflow is HORIZONTAL
(width-driven — RB probe: 4/5 terminals soft-wrap on width change; kitty no
reflow; iTerm2 bottom-anchors). So a width-only resize set neither the latch
nor the (B)-unit's trigger hook — the detector watched the wrong axis.

FIX (V ruled "fix now", red-first):
- `width_changed? = t.width != width`; `reflow_relevant? = geometry_changed?
  or width_changed?`.
- needs_keyframe now sets on reflow_relevant? (was geometry_changed? only).
- reflow telemetry fires on reflow_relevant? and carries old_width/new_width.
- Region RE-EMISSION stays vertical-only (width resize = zero DECSTBM bytes,
  T2b pinned regression untouched). Two jobs, two axes, now separated.
- Inverted the prior test (had asserted width-only resize does NOT latch —
  that WAS the bug); added telemetry-on-width-shrink test. T2c 20/20,
  T2b/footer/seal 66/66. Posted to #590.

DOWNSTREAM: T13a merged the T2c chain earlier, so T13a is now behind T2c by
this commit — re-merge/rebase T2c into T13a before T13a graduates. Not urgent.

(B) REFLOW UNIT — probe data banked for its brief: reflow width-triggered;
per-terminal (kitty no-reflow = stable rows, could skip keyframe; iTerm2
bottom-anchors on resize; rest top-anchor + soft-wrap). Telemetry now emits
on the correct (width) axis so the unit can observe its own trigger.
