# Harness Docs — the corpus map

Assembled 2026-07-18 (docs-librarian pass). This directory is the **fused,
subject-organized statement** of everything the two harness lanes have
decided, built, proposed, and measured. The journal-style originals are
preserved verbatim under `../proposals/` (nothing was deleted; provenance
below) — the explainers here de-duplicate them, state the *settled* position
where a doc was superseded mid-session, and surface real contradictions for
V instead of silently resolving them.

**Two rules of this corpus:** (1) explainers assemble, they never invent —
every claim traces to a source doc, a V ruling, or a measured result;
(2) where an explainer and an original disagree, the explainer records the
supersession explicitly ("superseded: X because Y"); if it doesn't, that's a
bug in the corpus — file it.

## Reading order

| # | Doc | What it is | Status |
|---|---|---|---|
| 1 | [`doctrine.md`](doctrine.md) | The why + the visual/honesty laws: soul, two pillars, zone ontology, clocking law, channel grammar, V-ratified rendering rulings, falsifier classes | settled law (OPEN items marked) |
| 2 | [`architecture.md`](architecture.md) | The event-sourced core: L1–L7, the contract, journal + one-way doors, safety substrate, probe swarm, render-substrate history incl. the 2026-07-18 full-viewport pivot, ACP wiring | settled + measured (pivot fallout flagged) |
| 3 | [`interaction.md`](interaction.md) | Speakers (chevrons), the single-truth input zone, keymap, composer commands, confirmation UI + SelectorWithComposer | built parts settled; §4–5 PROPOSED |
| 4 | [`widgets.md`](widgets.md) | Block model, tool-line render ruling, the binding contract, tool-widget router, gundam widgets, diff rendering, the three-registry convergence rule | laws settled; routers/widgets PROPOSED |
| 5 | [`process.md`](process.md) | Quality loop, changeset-fusion, the PR gauntlet, Drew meta-analysis, cross-lane discipline, eval-first meta-pattern | adopted practice |
| 6 | [`roadmap.md`](roadmap.md) | Both lanes' DAGs, gates, milestone state (with staleness warning), proposed-unbuilt clusters, open decisions, research index | living; statuses dated |

Status vocabulary used throughout: **settled law** (V-ratified or
measured — never re-litigate without new evidence) · **resolved** (decided
by measurement/quorum, ratification tracked) · **adopted** (standing
practice) · **PROPOSED** (design-ready, not built — never present as
shipped) · **superseded** (kept for the record inside its successor) ·
**OPEN** (needs a V ruling).

## Binding contracts kept standalone (linked, not fused)

These are contracts/evidence, not explainers — fusing them would change
their standing:

- [`../proposals/in-flight/harness-SYNC-ACCORD.md`](../proposals/in-flight/harness-SYNC-ACCORD.md)
  — the 2026-07-17 cross-lane accord, **binding on both lane sessions**.
  NOTE: this file is a *reconstruction from the ratified memory summary*;
  the fully-negotiated text was in the mediation job's tmp dir and was not
  recovered. Terms are verbatim from the summary both lanes ratified.
- The **freeze constitution** (`harness-freeze-contracts.md`,
  `harness-invariants.md`, `harness-parked.md`) lives on branch
  `docs/harness-freeze-constitution` (PR #569), agent-lane owned. Its
  one-way doors are restated in `architecture.md` §4; the constitution text
  is authoritative.
- The `harness-session-split` / `harness-freeze-decisions` /
  `harness-eval-first-ruling` / `harness-pr-gauntlet` / `harness-quality-loop`
  memory notes (session memory, not repo files) are summarized into the
  explainers; where a memory and a repo doc disagreed, the newer V ruling won
  and the supersession is recorded.
- [`../proposals/bonded-harness/`](../proposals/bonded-harness/) — the fused
  persona+harness system-prompt **entity package** (rev 4). It has its own
  README and internal structure (core/subagent prompts, slots, gates, evals,
  design, journey, failure-patterns, red-team); it is a loadable artifact,
  not a journal — kept intact.
- [`../proposals/research/tui-aesthetics/`](../proposals/research/tui-aesthetics/)
  — the 39-dossier vibes corpus + `LANDSCAPE.md`. The doctrine cites it;
  it stays the evidence base, indexed in `roadmap.md` §6.

## Fusion map (old doc → new home)

| Original (preserved verbatim) | Provenance | Fused into |
|---|---|---|
| `in-flight/harness-visual-doctrine.md` | repo (was untracked) | `doctrine.md` |
| `in-flight/harness-ui-north-star.md` | **scratchpad canonical** (adds the BEAM-substrate section over the repo copy) | `doctrine.md` |
| `in-flight/harness-speaker-separation.md` | repo (staged) | `interaction.md` §1 |
| `in-flight/harness-composer-commands.md` | repo (was untracked) | `interaction.md` §4 |
| `in-flight/harness-confirmation-ui.md` | repo (was untracked) | `interaction.md` §5, `widgets.md` §3 |
| `in-flight/harness-gundam-widgets.md` | repo (was untracked) | `widgets.md` §4 |
| `in-flight/harness-design.md` | repo (was untracked) | `architecture.md` §1–2, §8 |
| `in-flight/harness-spec-protocol.md` / `-backend.md` / `-frontend.md` | repo (was untracked) | `architecture.md` §3–5, §7 |
| `in-flight/harness-synthesis.md`, `harness-ui-cohort-research.md` | repo (was untracked) | dispositions cited in `architecture.md` §2 / `doctrine.md`; full texts remain the letter of AD/FI/NC |
| `in-flight/harness-storage-research.md`, `harness-cohort-research.md`, `harness-facts-two-perspectives.md`, `harness-baseline-features.md`, `tui-steal-list.md` | repo (was untracked) | evidence layer; indexed in `roadmap.md` §6 |
| `in-flight/harness-roadmap.md` (agent v3) | repo (was untracked) | `roadmap.md` §2 |
| `in-flight/harness-ui-roadmap.md` (v2 + D-PA) | **scratchpad canonical** | `roadmap.md` §3, `architecture.md` §6 |
| `in-flight/harness-ui-methodology.md` | **scratchpad canonical** | `process.md` §2 |
| `in-flight/harness-ui-STATE.md` | **scratchpad canonical** (full ledger; repo copy was the stale W0 stub) | `roadmap.md` §3 (with staleness warning) |
| `in-flight/harness-ui-execution-plan.md` | repo (was untracked) | `process.md` §1 (roles) |
| `in-flight/harness-ui-PR-GAUNTLET.md` | scratchpad-only, imported | `process.md` §3 |
| `in-flight/harness-ui-SHG-spec.md` | scratchpad-only, imported | `architecture.md` §6 |
| `in-flight/harness-ui-grok-reshaped-dag.md` | scratchpad-only, imported | `architecture.md` §6, `roadmap.md` §3 |
| `in-flight/harness-ui-agent-lane-intersection.md` + `agent-lane-response-to-ui-intersection.md` + `agent-lane-response-PR-GAUNTLET.md` | scratchpad-only, imported | `roadmap.md` §3/§5 |
| `in-flight/harness-reviews/DREW-PATTERNS-META.md` + `DREW-FINDINGS-24H.md` | scratchpad-only, imported | `process.md` §3 |
| `in-flight/f0-capability-detection.md`, `f2-action-registry.md` | repo (was untracked) | `roadmap.md` §4; F2 spine cited in `interaction.md`/`widgets.md` |
| `in-flight/pierre-diffs-analysis.md`, `shiki-elixir-analysis.md` | repo (was untracked) | `widgets.md` §5 |
| `in-flight/harness-research/`, `harness-ui-research/`, `harness-ui-testing/` | repo (was untracked) | indexed in `roadmap.md` §6 |
| V rendering/substrate/session rulings (2026-07-17/18) | session memory (`harness-pr-gauntlet` note) | `doctrine.md` §7, `architecture.md` §6, `interaction.md` §1/§3 |
| grok-build harvest | `harness-ui-grok-reshaped-dag.md` + `harness-ui-SHG-spec.md` + `grok-build-substrate-parallel` memory | `architecture.md` §6 |

**Not recovered:** `grok-build-design-parallels.md` (the original findings
doc the reshaped-DAG cites) — its content survives via the reshaped DAG, the
SHG spec, and the `grok-build-substrate-parallel` memory. The full
SYNC-ACCORD negotiated text (see above).

**Deliberately left out of this corpus** (other lanes' in-flight docs, still
untracked in the main checkout): `r1-incremental-render.md`,
`terminal-font-sizing-research.md` (terminal-rendering lane),
`docs/PHILOSOPHY.md`. They are not harness docs; their lanes own committing
them.

**Dual-copy caution:** four lane docs (north-star, ui-roadmap,
ui-methodology, ui-STATE) are committed here from the harness-ui session's
scratchpad canonical copies, which are strictly newer than the untracked
working copies that may still sit in the primary checkout. If a checkout
later collides on those paths, the committed versions win — diff before
discarding, per the accord's no-git-clean rule.

## Unresolved — contradictions surfaced for V

Real divergences found during fusion (not re-litigations — each needs a
ruling or an explicit "leave it"):

1. **Substrate pivot vs ratified inline-first dispositions.** AD-U1
   ("inline-first, never alt-screen-first") and NC-U1 ("no alt-screen
   application shape") were ratified from measured cohort pain; the
   2026-07-18 pivot makes full-viewport (alt-screen) the live default. The
   pivot is V-ruled and governs, but the dispositions' text was never
   amended: are AD-U1/NC-U1 *suspended with the substrate* (return
   intended) or *amended* (full-viewport is the shape, alt-screen affordance
   loss accepted and mitigated by owned virtual scrollback)? North-star §3.1
   ("inline, scrollback-native") carries the same tension.
2. **Salience scope after the pivot** — the seal-time-grade constraint
   (sealed bytes must not depend on reveal cadence) was byte-parity-driven;
   with repaintable logical history, does prominence grading extend across
   full history (the original moat thesis), and is G6 seal-display-mode
   still per-seal-frozen? (`roadmap.md` §5.)
3. **Prominence-follows-focus vs "Yes stays white"** in the confirmation UI
   — two claimants on the single anchor if both hold; the proposal
   recommends prominence-follows-focus (`interaction.md` §5).
4. **Discuss semantics** — v1 deny-with-feedback (unblocks the parked gate)
   vs the heavier keep-pending re-prompt loop; v1 recommended, v2 flagged.
5. **Composer→surface trigger flow** — poll `completion_context/1` per edit
   vs composer-emitted `{:trigger, ctx}` event; poll recommended.
6. **PA-2..PA-5** constitution amendments remain PROPOSED, awaiting separate
   V ratification (per the freeze memory + accord escalation list).
7. **D-PA retroactive ratification** — the (A)+(B) ruling was issued by [F]
   under the provisional-default protocol and measured by RB; formal V
   ratification is still on the escalation list (moot-ish under the pivot,
   but the record should say which).
8. **Ledger staleness as a standing hazard** — the corpus's status tables
   went stale twice in 48h during the fastest build period; the accord's
   "PR-verified reality is baseline" rule is the fix, but nothing enforces
   it structurally yet. (Candidate: a generated STATE from `gh pr list`.)

## Why this structure

The proposals accreted chronologically (research → synthesis → specs →
roadmaps → per-feature scouts → rulings), so the *current* position on any
subject was smeared across 4–6 files and two storage locations (repo
untracked + session scratchpad), several superseded mid-session. The
explainers cut by **subject** (why/laws · core · interaction · widgets ·
process · plan) because that is how the docs get consulted during build and
review; the originals cut by **time**, which is how decisions get audited.
Both views are kept; the map above is the join.
