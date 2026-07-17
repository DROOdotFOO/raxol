# Harness UI — North Star

Date: 2026-07-15 · Status: vision. The "why" above `harness-ui-roadmap.md` (the
"how") and `harness-ui-cohort-research.md` (the evidence). When a unit decision
is ambiguous, this document breaks the tie.

---

## 0. The thesis in one line

**An instrument panel grown around a log — never a replacement for the log.**

The terminal stays a terminal. The harness adds instrument-grade glass over it.
Trust comes from legibility, not reassurance.

## 1. The lineage (what we descend from — and don't)

**fish, not htop.**

- From **fish**: enrich the line the user is already on. Ambient intelligence
  rendered at low prominence — fish's dim autosuggestion is the proof that
  salience-graded disclosure is the most loved pattern in shell UX: *available,
  not asserted*, promoted by the user's own action. Depth summoned (Tab) and
  dismissed. The shell never takes the screen.
- From **tmux statusline**: exactly one pinned strip of instrumentation — a
  border, not a room.
- From **Warp/Wave blocks**: one action = one semantic unit with its own
  metadata and fold. (And Wave's failure: the moment blocks stop being units of
  *work* and become tiles of *layout*, users leave.)
- From **nothing in htop/k9s**: no inhabitation. Their patterns (context keybar,
  panel grid) are pattern *sources* for our overlays, never a target shape.
  The regret asymmetry is settled: every alt-screen adopter begs for native
  scrollback back; no inline adopter asks to cross over.

## 2. The three operator moments

The whole UI optimizes three moments; everything else stays out of the way.

1. **Watching** — glanceable truth. Three questions answered by one pinned
   strip, zero interaction: *what is it doing now* (stage, not spinner) ·
   *what has it consumed* (context %, cost, live) · *what does it need from me*
   (nothing / approval / decision). Working-vs-hung distinguishable at sight.
2. **Deciding** — review at the decision moment, not archaeology after. The
   approval arrives with the diff *there*: syntax-under-diff, full-screen
   expandable, scroll still alive, blast radius stated. The prompts that remain
   after ambient gates must be maximally legible, because 93% of illegible ones
   get blind-approved.
3. **Returning** — catch-up as evidence. Unread divider marks "new since you
   looked away." Reattach renders a restoration diff (turns elapsed, files
   touched, cost delta, current state) — never a success toast. "Done" carries
   its evidence.

## 3. What it IS

1. **A stream you don't have to distrust.** Inline, scrollback-native. Native
   scroll, copy, find, tmux keep working. Within an attach, history is printed
   once and never repainted — *streaming* flicker structurally impossible, not
   carefully avoided. (Resize/reattach behavior of sealed history follows the
   D-PA paint-authority policy, decided from measured terminal behavior in T0
   — see roadmap §0.)
2. **An attention instrument.** The screen tells you where to look: current
   work at full prominence, older context perceptually faded (H-K-solved, even
   across hues), needs-input glowing. The transcript is a priority landscape,
   not uniform noise. Category-empty in the entire cohort; ours because the
   solver already ships. (Reach — live region always; sealed history only as
   D-PA permits. This is the product shape and M3's gate, not S1's.)
3. **Semantic blocks.** One tool call = one collapsible unit with outcome
   metadata on the row (exit, duration, cost). Distinct kinds: message,
   reasoning, tool call, diff, approval. Jumpable, foldable, searchable,
   OSC-marked so even the terminal understands them.
4. **Depth summonable, silence default.** One picker shape for every
   pick-one-of-N. Panels are opt-in, information-bearing, and keep living when
   dismissed. Chrome earns pixels by carrying information.
5. **Structurally honest.** Pixels are a projection of the journal — what you
   see is provably what happened. The UI owns nothing; kill it, respawn it,
   same truth. Even agent-generated panels (C4) are declarative components on
   the same stream — the agent's own UI cannot lie outside the vocabulary.
6. **Degrading with dignity.** Light theme, 80 cols, no nerd fonts, mosh,
   screen reader → flat mode is a first-class rendering, test-pinned, not an
   apology. (Flat mode is simultaneously the a11y answer, the pipe/CI answer,
   and the block-hater answer.)
7. **One lens among several.** Terminal, LiveView, SSH, phone attach to the
   same loop; the TUI is a subscriber, never the owner (L5).
8. **Quietly escalating.** Attention tiers gated on focus: in-view accent →
   tab title → OS notify → bell. Never escalates while you're looking. Sound
   off by default.

## 4. What it is NOT

- **Not an app you inhabit.** No alt-screen jail, no IDE cosplay, no file
  trees, no editor.
- **Not decorated.** No motion that doesn't encode state change. Every pixel
  passes "what does this tell me right now?" Restraint is the trusted
  register; ornament reads as slop.
- **Not a firehose.** Tool output folds. Probe meta-chatter stays in an
  advisory side-channel, never raw-appended to the primary feed.
- **Not a nag.** Never interrupts focus; never asks what ambient gates can
  enforce structurally.
- **Not a liar.** No spinner-forever, no success toasts, no "done" without
  evidence, no hidden context.
- **Not a metrics wall.** The slot belongs to the work; passive readouts never
  win it.

## 5. The isomorphism underneath

The cohort builds TUIs that **perform activity** — spinners, animations,
reassuring chrome. The dream harness **discloses state** — every visual
element a projection of durable truth, prominence proportional to relevance.

This is the journal's economic law surfacing at the pixel layer: *write
lavishly, inject selectively* becomes **know everything, show what matters.**
The salience system is the injection discipline made visual; the block model
is the journal made navigable; the strip is the materialized view made
glanceable. One system, not three features — the same shape as the backend's
"one event-sourced system, not seven features."

## 6. How to use this document

- Every roadmap unit (T0–T23) should trace to §3/§4; a unit that doesn't is
  suspect.
- Every visual proposal gets the two tests: **"what does this tell me right
  now?"** (information-vs-decoration, §4) and **"which operator moment does it
  serve?"** (§2). Failing both = cut.
- Dispositions with binding force live in `harness-ui-cohort-research.md`
  (AD-U1..7, FI-U1..5, NC-U1..4); this document is their spirit, that one is
  their letter.


## Substrate position: BEAM, and what the Rust rewrites actually taught

The cohort's Rust rewrites (and Ink's collapse) encode two lessons, not one:
**GC pauses** and **install weight + heap residency**. Per-process heaps with
no global stop-the-world sidestep the first entirely — a deliberate BEAM
advantage we get for free and now state explicitly. The second does NOT
evaporate: GC pauses ≠ data growth. Unbounded projection residency (the block
list), sub-binary refs pinning large stream chunks (the one leak class BEAM
adds over Node), and shipped-artifact weight are real and tracked — memory
acceptance tests at T13a, :binary.copy at the seal boundary, ScrollWindow as
the virtualization substrate, install/distribution as an owned backlog item.
Rule of thumb inherited from the cohort's graveyard: anything built to
compensate for a weakness (model's or platform's) carries a measured exit
criterion, or it outlives its reason.
