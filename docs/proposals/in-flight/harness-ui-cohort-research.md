# Harness UI — Cohort Research (TUI + visuals only)

Date: 2026-07-15
Status: priors written BEFORE research returned (calibration discipline).
Protocol: cohort-research skill (dappsnap). Scope: ONLY the TUI/visual layer of the
agent harness — the layout container, rendering, attention, navigation. The agentic
layer/protocol/storage was covered by `harness-cohort-research.md` + `harness-synthesis.md`;
this pass feeds the harness UI layout container design.

## Phase 1 — Frame

**User pain, not feature:** An operator delegates work to an agent and supervises it
from a terminal. The screen must let them (1) know at a glance what the agent is doing
*now* — alive / stuck / awaiting-me, (2) review what just happened (diffs, tool output)
at the moment a decision is needed, (3) find things again inside a long session,
(4) keep their terminal intact — scrollback, copy/paste, resize, no flicker,
(5) trust that the pixels reflect the actual state.

**JTBD frame:** "I want to supervise a working agent from my terminal without losing
my place, my scrollback, or my trust in what I see."

**Not the frame:** "we need panes/tabs/a sidebar" — those are solution shapes the
research must test, not assume.

Skill caveat applied up front: **forum-first under-samples presentation failure** —
people bounce silently on bad visuals and post about *content*. So this pass explicitly
adds demo/screenshot-reaction mining and design-writeup review beside the forum sweep,
and treats visceral on-sight reactions as first-class evidence.

## Phase 2 — Priors (marked confident vs guessing)

### Expected decomposition (7 concerns)

1. **Scrollback integrity & render substrate** — inline vs alt-screen, flicker on
   stream, native scroll/copy broken, resize corruption. Expect this to be the #1
   visual pain for agent CLIs (Claude Code's Ink repaints are notorious). [CONFIDENT]
2. **Glanceability of agent state** — working vs hung vs waiting-for-approval;
   spinners that spin forever; approval prompts that go unnoticed and block for
   hours. Cost/context indicators. [CONFIDENT]
3. **Long-transcript navigation** — collapsing/folding tool output, jump-to-previous
   diff/tool-call, search within session; Warp/Wave "command blocks" as prior art.
   [CONFIDENT-ish]
4. **Layout & density** — single stream vs panes/sidebars (todo, plan, context%);
   wide vs narrow adaptation. Prior: the cohort is almost entirely a single-column
   stream; persistent panels are rare and unproven demand. [GUESSING]
5. **Diff/code rendering quality** — syntax-under-diff, wrap vs truncate policy,
   review-at-approval-moment. (We just built this; test whether the cohort's pain
   matches what we built.) [CONFIDENT it matters]
6. **Input ergonomics** — multi-line editing, paste fidelity, $EDITOR handoff,
   visibility of queued/steered messages. [CONFIDENT-ish]
7. **Terminal-compat visual degradation** — light-theme unreadability, broken
   box-drawing/nerd-font glyphs, 256-color fallback, tmux/ssh. Low forum volume,
   silent-bounce shape. [GUESSING frequency, CONFIDENT on silent-bounce]

### Expected complaints

- "It flickers / repaints the whole screen while streaming"
- "I can't scroll up while it's generating" / mouse-wheel hijack
- "Copy-paste grabs border glyphs / breaks on wrap"
- "The approval prompt was buried, agent sat idle for an hour"
- Spinner with no elapsed/step info — "working or hung?"
- Tool output floods the transcript; can't collapse
- Unreadable on light background terminals
- Resize mid-run corrupts the layout
- "Where is the diff it just applied?" — review after the fact is hard

### Expected differentiation (DOMAIN-INTERNAL BIAS — research must test)

- **Perceptual salience layer** (H-K fades, prominence tiers, attention-directed
  dimming) — suspect category-empty: nobody grades visual prominence by relevance.
- **A real layout container**: persistent panels rendered from durable projections
  (worktracks/memory/context) beside the stream — the C2 projections made visible.
- **Multi-surface parity** (same tree → TUI/LiveView/MCP) — already validated
  category-empty at the protocol level; visual side unproven.
- **Agent-generated UI (C4)** — declarative panels the agent emits.
- Suspicion to test: cohort treats TUI as a *log*; the win may be treating it as an
  *instrument panel* around a log.

### Expected failure modes (cautionary priors)

- Ink/React reconciler repaint storms (Claude Code); Textual perf ceilings.
- Alt-screen jail: users hate losing native scrollback to a full-screen app.
- Over-chrome: borders/boxes everywhere reading as toy; "less is more" reactions.
- TUI-as-IDE overreach — file trees and editors nobody asked for in a harness.
- Density hardcoded for wide terminals; unusable at 80 cols.

### The deeper question

Is the harness UI a **stream you decorate** (inline, scrollback-native, minimal chrome —
the Codex/Claude shape) or an **application you inhabit** (alt-screen, panes, k9s/lazygit
shape)? The cohort split suggests unsettled design space — is that strategic disagreement
or has nobody cracked the hybrid (inline stream + summonable instrument panels)?

## Phase 3 — Cohort (6 briefs)

1. Leaders' TUIs: Claude Code (Ink), Codex CLI (Rust/ratatui) — visual/UX praise+rage
2. Challenger TUIs: Gemini CLI, opencode, Crush, Aider, goose, amp CLI
3. Adjacent power-TUIs: Warp/Wave blocks, k9s, lazygit, Zellij, btop, Yazi, Helix
4. Frameworks/theory: Ink vs Ratatui vs Bubble Tea vs Textual; inline-vs-altscreen;
   OSC 133 semantic zones; kitty text-sizing; sync output
5. Horror/presentation axis: flicker+corruption incidents, light-theme, screen-reader
   accessibility, screenshot/demo reactions (the silent-bounce mining)
6. Visual domain experts: delta/difftastic (diffs), glow (markdown), starship (status),
   multi-agent supervision UIs (claude-squad, Conductor, Crystal, tmux-based managers)

## Synthesis checklist (Phase 5 gate)

- [x] Priors corrected somewhere? (only confirmed → ran it wrong) — yes, 3 corrections
- [x] 5–8 pain clusters, not feature clusters — 7
- [x] Surprises explicitly listed — §6
- [x] Per finding: decision / foundation-invariant / non-commitment — §8
- [x] Category-empty opportunities named — §7
- [x] Failure modes with attribution — §5
- [x] Severity × irreversibility second pass (silent-bounce items surfaced) — P6 float-up
- [x] What did research NOT cover → second pass? — §9

---

# Phase 5–6 — Synthesis (research returned 2026-07-15)

Inputs: 6 forum-first briefs in `harness-ui-research/01–06` (leaders, challengers,
adjacent power-TUIs, rendering theory, presentation axis, visual experts). All claims
below carry attribution in the briefs.

## 4. Decomposition by pain (7 clusters, severity × irreversibility weighted)

### P1 — Render-substrate integrity *(freq #1, universal, framework-independent)*
Flicker + scrollback destruction + resize corruption + tmux corruption. Every tool,
every renderer (Ink, ratatui-Desktop-conflation aside, Bubble Tea, custom). Anchors:
Claude Code flicker vendor-admitted at "~1/3 of sessions see at least a flicker"
*post-fix*; the flicker fix itself caused the worst scrollback regression (#41965 →
#28077, 73👍 — highest reaction in the leader survey, same release cycle); tmux render
corruption unrecoverable (#29937); goose O(n²) streaming ("UI still typing minutes
after generation finished", #10075). **Two root causes explain nearly everything:**
(1) code-point-count vs true display width, (2) full-buffer redraw vs diff/append.
Raxol's diff renderer + `TextMeasure` sit structurally against both.

### P2 — Review-at-decision-moment (diff/approval UX) *(highest reaction density)*
The two highest single-issue reaction counts in the challenger cohort live here
(Aider #649 = 41 reactions, 18mo silence; opencode #17076). Codex: *"3 lines of
code... How TF am I supposed to review changes"* (#13561); can't scroll or open
transcript while an approval prompt is open (#22263). Demanded: full-screen
expandable diff review from the approval prompt; pre-apply confirmation. Long-line
truncation = the single most common unresolved diff complaint cohort-wide.

### P3 — Long-transcript navigation *(worse than priors assumed)*
No jump-navigation exists anywhere in the cohort. Folding is inconsistent
(Gemini Ctrl+O exists; Claude Code #50313/#51624/#17043 beg for collapse with
position-preserving scroll); transcript full-text search demanded (#8053), Amp's
actively broken by alt-screen. Emerging substrate: OSC 133 mature for shell blocks
but not agent turns; **Warp's proprietary OSC 777 superset already emitted by Claude
Code / Gemini CLI / opencode** — a de facto standard forming outside the standards
track.

### P4 — Glanceability + attention escalation
Context-% meter = converged unmet demand (Crush #875, Gemini #16130, goose — all
requested, none satisfied). Working-vs-hung ambiguity (goose horror). Approval
prompts buried. Converged solution across every serious supervision tool:
**needs-input sorted to top + one-line summary + peek-short-of-attach + single
approval funnel + four-tier focus-gated escalation** (in-view → tab title → OSC 9 →
OS notification), sound/notify default OFF, never fires while focused. White space:
nobody solved "new since you looked away" — the transferable answer is the chat-UI
unread divider, not anything in the monitoring corpus.

### P5 — Alt-screen affordance loss *(new cluster; priors folded it into P1 wrongly)*
Distinct from corruption: alt-screen *works* and still loses native find / copy-paste
/ mouse-select / scrollback search (Amp critique, Wave, opencode complaints; OSC 52
silent failures #66192; tmux mouse-capture stealing scroll from both leaders #38810).
**The asymmetry law:** every alt-screen adopter has open issues asking for
scrollback-native behavior back (Gemini rolled back, cmux, opencode); no inline
adopter asks to switch to alt-screen — inline camps patch viewport bugs instead.
The split is settled, not fragmented: inline wins; alt-screen is an escape hatch
(`CLAUDE_CODE_NO_FLICKER` = "the nuclear option").

### P6 — Degradation & accessibility *(silent-bounce; severity-floated)*
Light-theme invisible text is an 8-issue *cluster* at Claude Code (dark-only
testing); colorblind contrast 39👍 at Crush; nerd-font tofu; mosh 256-color;
width bugs filed independently against Microsoft Terminal, Lipgloss, fish, neovim,
hermes-agent — systemic. Screen readers: NVDA freezes on Claude Code + Gemini
(#11002 open); the only demanded fix is a **flat/linear/no-animation fallback mode**
— an escape hatch, not novel a11y features. Nobody in the cohort handles the full
degradation matrix gracefully.

### P7 — Decoration vs information *(the trust axis)*
Users cleanly split form-that-carries-information (sidebar, diff view, no-flicker,
per-row outcome context — praised) from form-that-doesn't (logo-burst animation:
17👎 + anxiety/dizziness complaints; gradient progress bars; "AI slop" markers).
Restraint is the default-trusted position; decoration must earn its pixels.
Prettiness wins the first 10 seconds but buys zero forgiveness for functional gaps.

## 5. Failure modes catalogued (attribution)

- **Ink full-tree redraw + `<Static>` re-render-everything** → Claude Code's year of
  flicker → custom double-buffer renderer rewrite → alt-screen escape hatch.
- **The fix-caused-regression pair**: flicker fix (#41965) shipped the scrollback
  destruction (#28077) in the same cycle.
- **Wave collapsing per-command blocks into tiles** → users left ("like any other
  terminal emulator", waveterm#1084). Blocks must stay 1-action=1-unit.
- **Blocks stealing focus from live input** (Warp #3189/#3227, closed-not-planned →
  resentment).
- **Resurrection success-toast lie**: zellij#4873 resurrects the *wrong* command
  (repro'd with `claude --resume`); tmux-resurrect#513 false-success no-ops.
  Universal failure: reports success while doing the wrong thing.
- **btop minimum-size wall** (#926 — below min cols you can't even quit).
- **k9s 78-single-key ceiling** (#2793) — single-key-per-action doesn't scale;
  palette + context keybar needed from day one.
- **DECSET 2026 sync-output closed not-planned at Ink** (#37283) — the cheap fix
  that would have avoided the renderer rewrite.
- **goose three divergent UI codebases** under one name.

## 6. Surprises (the honesty section — priors calibration)

Priors ~70% right. The corrections:

1. **Panels prior WRONG.** "Persistent panels rare/unproven demand" — actually 3/6
   challengers ship them and they're well-received *when information-bearing*.
   The real axis is P7 (information vs decoration), not panel-vs-stream.
2. **Alt-screen affordance loss is its own cluster** (P5), not a corruption subtype —
   and the inline-vs-altscreen "unsettled split" prior resolves via the asymmetry
   law: it's settled in inline's favor; nobody cracked the hybrid.
3. **Navigation is worse than assumed** — expected weak folding; found *zero*
   jump-nav anywhere.
4. Codex flicker complaints concentrate in the Electron Desktop app, not the
   ratatui CLI — easy conflation, matters for attribution.
5. Warp's proprietary OSC 777 is already the de facto agent-block mark (adopted by
   3 major CLIs) while OSC 133 stays shell-only.
6. Aider's minimalism = **neglect, not doctrine** (18mo silence on 41-reaction
   approval-UX issue) — its praise is for the *inline substrate*, not the gaps.
7. Multi-agent supervision tools invented no new mechanics — just an attention list
   on top of identical single-agent four-tier escalation. Single-agent-first is safe.
8. Perceptual prominence: dedicated hunt confirms **genuinely category-empty** —
   only static role-dimming conventions exist; no recency/focus-driven contrast
   anywhere.

## 7. Category-empty opportunities

1. **Perceptual salience rendering** — attention-tiered prominence (recency fade,
   focus-driven contrast, H-K-solved dimming). Confirmed empty; we already own the
   solver + shipped it in DiffViewer. The moat candidate.
2. **The inline hybrid** — inline scrollback + DECSTBM-pinned composer/status +
   sync-output framing. No cohort member combines all three. (Correction from
   triad review: our mode-2026 "support" today is env-sniffing —
   `query_synchronized_output_support/0` is hardcoded false and there is no
   DECRQM reply parser; F0 is a design doc, not shipped code. The seam
   advantage is real — diff renderer + TextMeasure + OSC 11 probe — but the
   capability layer is roadmap unit T1, not an existing asset.)
3. **Approval-queue triage** — batching, risk-scored ordering, cross-agent diff
   grouping. Every tool stops at "sorted list, needs-input on top."
4. **"New since you looked away"** — unread-divider semantics in a TUI transcript.
5. **Restoration diff on reattach** — evidence-of-state instead of success toast.
   Uniquely cheap for us: the journal already holds the truth (A10/L4).
6. **Context-% meter done right** — trivial, converged unmet, cheap win.
7. **Agent-turn semantic blocks** — emit OSC 133 *and* OSC 777 marks per turn/tool
   call; open asks at Claude Code + Copilot CLI; rides the forming standard.

## 8. Dispositions

### Architectural decisions (bind the layout container design)
- **AD-U1 Inline-first, never alt-screen-first.** The container = inline
  scrollback-native stream + DECSTBM-pinned bottom region (composer/status/keybar) +
  sync-output-framed repaints, all gated on F0 capabilities. Alt-screen exists only
  as explicit fallback (degraded terminals) or user escape hatch. *(P1, P5)*
- **AD-U2 One tool-call = one collapsible block.** Distinct block types
  (message / reasoning / tool-call / diff / approval), fold with position-preserving
  scroll, per-block outcome metadata (exit, duration, cost — the atuin row). A
  **flat-transcript mode** (no blocks, no animation, append-only) ships in v1 —
  it is simultaneously the screen-reader answer, the block-hater answer, and the
  degraded-terminal answer. *(P3, P6)*
- **AD-U3 One overlay-picker primitive** (fzf-shape: list + async cancelable
  preview, summon/dismiss) serves every "pick one of N" — sessions, runs,
  tool-calls, command palette, file mentions. One primitive, N projections (F2).
  *(adjacent corpus: convergent reinvention = category winner)*
- **AD-U4 Panels are opt-in information surfaces.** Persistent side panels
  (context meter, worktracks/plan, memory) must carry live information, be
  hideable, and follow the lazygit grid shape (concurrent state axes), not the
  k9s drill-stack. No decorative chrome. *(P4, P7; panels prior corrected)*
- **AD-U5 Four-tier focus-gated attention escalation** — in-view sort/color →
  tab-title → OSC 9 → OS notify; sound off by default; never escalate while
  focused. Needs-input sorts to top of any list. *(P4, converged pattern)*
- **AD-U6 Diff review is expandable to full screen from the approval prompt**;
  scrolling stays live during approvals; long lines never silently truncate
  (DiffViewer policy already conforms). *(P2)*
- **AD-U7 Context-% + cost in the status region from day one.** *(P4, cheap)*

### Foundation invariants (cheap now, painful to retrofit)
- **FI-U1 Emit OSC 133 + OSC 777 block marks** per agent turn / tool call.
- **FI-U2 Reattach renders a restoration diff** (what happened while detached,
  what state resumed), never a bare success message. Journal replay makes this
  nearly free; the resurrection corpus' universal lie is the anti-pattern.
- **FI-U3 Salience tier is first-class render metadata** in the harness component
  contract (prominence attribute → H-K solver), generalized from DiffViewer to
  every harness surface. Reserve the attribute shape now.
- **FI-U4 Degradation floor is test-pinned**: CI snapshot tests for light theme,
  no-nerd-font ASCII, 80 cols, 256-color, flat mode. Silent-bounce insurance.
- **FI-U5 Unread divider** on refocus/reattach (transcript remembers last-seen
  offset — journal offset, already in the protocol).

### Explicit non-commitments
- **NC-U1 No alt-screen application shape** (no inhabitation; k9s/lazygit is a
  pattern source, not a target).
- **NC-U2 No decorative animation.** Animation only encodes state change.
- **NC-U3 No approval-triage v1** (batching/risk-ranking) — single funnel + sort
  first; triage is the *named later* differentiator.
- **NC-U4 No blocks-as-tiles** (Wave's failure), no focus-stealing blocks.

## 9. Meta-review — what this pass did NOT cover

- **Reddit fetch-blocked for 2 agents** → power-user/GitHub skew again (same gap as
  the agent-layer pass). Casual first-run visual impressions under-sampled.
- **Input ergonomics under-covered** — only paste-corruption surfaced; multi-line
  editing / $EDITOR handoff / queued-steer display need a targeted look during S1
  build, not a full pass.
- **LiveView/web parity untouched** — deliberate (TUI-only scope); the container
  design must keep the tree surface-agnostic anyway (L1).
- **Kitty text-sizing (OSC 66) adoption** not re-verified here; F0 stance
  (detect-don't-emit) unchanged.
- **No cost model** — effort pricing happens in the layout-container design doc.

## 10. Reusable diagnostics (extracted to the skill library)

- **Alt-screen asymmetry test**: when a design space splits into two camps, check
  the *regret direction* — who files issues asking to cross over. One-way regret =
  the space is settled, not fragmented; the "debate" is survivorship noise.
- **Fix-caused-regression pairing**: before shipping a renderer/substrate fix for
  the top complaint, enumerate what the current behavior silently provides
  (flicker fix → scrollback destruction). Coupled constraints hide in the substrate.
- **Information-vs-decoration chrome split**: users reliably praise form that
  carries information and resent form that doesn't. Test every visual element with
  "what does this tell me right now?" — decoration must earn pixels; restraint is
  default-trusted.
- **Success-toast lie**: any restore/resume/resurrection surface must show
  evidence-of-state (a diff), not claimed success — the entire resurrection corpus
  fails this one way. (Same shape as FI-6 evidence-gated done, one level up.)
