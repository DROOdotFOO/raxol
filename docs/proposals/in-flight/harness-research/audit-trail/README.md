# Harness Freeze — Audit Trail

Date archived: 2026-07-16 · Status: historical record, do not edit in place.

The `harness-freeze-contracts.md` PR body cites a "5-model quorum / longcat
audits / 93-find survey" as the provenance for the frozen contract. That
provenance was not reconstructable from the committed corpus — the audits and
rulings existed only as session-local scratchpad output, which vanishes when
the session ends. This directory commits that trail so the freeze's history
is auditable from the repo alone, not from a transcript nobody can re-open.

Each file below is a (lightly cleaned — tool-narration preamble lines
stripped, content otherwise verbatim) copy of one scratchpad artifact that
fed into `harness-freeze-contracts.md`.

## Index

### 01-longcat-freeze-audit.md — first adversarial audit

The first full adversarial pass over `harness-freeze-contracts.md`, run
against landed code (`Contract.Event`, `EmitBridge`, `Writer`, `Reader`,
`Ledger`). Produced findings **AF-1..AF-9** (severity-tagged: cardinal-sin
forward-compat risks, the dual-id landmine re-verification, the U4∥U9
false-parallel dissolution, contour completeness gaps, the taint lattice, and
U12 cache-riding/budget soundness) plus rulings on the **9 open questions**
(OQ-JS1..JS3, OQ-U11.1..U11.3, OQ-U12.1..U12.3). Verdict at the time: **not
safe to author reds against as-is** — three fix-before-red items identified
(ratify `approval_requested` as family:loop + the `refs` session-scoping
contract; bound parked probe runs; include `item_started` in CONVERSATIONAL
and close contour gaps).

### 02-longcat-delta-audit.md — delta audit of the fold-before-reds revision

A second pass, scoped to only the *delta* introduced by the revision that
folded the first audit's fixes plus the ruling-round's new fields (`kind`,
`branch_id`, `actor`, `scope`, `provenance`, `cost_ref`, `fingerprint`) into
the contract. Explicitly does not relitigate AF-1..AF-9 (folded in
correctly). Found two genuine new **RED** defects (`approval_decided`
duplicating `actor` in both envelope and payload — contradicts the
uniform-actor principle the same revision established; `params_hash`
canonicalization under-specified, making it untestable across independent
encoders) plus several **YELLOW** items (`$blob` FI-10 secret-scrub coverage,
`P-JS11`/`N-JS11` ungeneratable before GC, speculation plural-refs vs the
session-scoping contract, `client_msg_id` dedup window/durability). Verdict:
**not safe to author reds against as-is**, but the fix list was short and the
doc otherwise in strong shape. This audit is what the "delta" in
"fold-before-reds" refers to in the roadmap's Wave 1.5/Wave 2 review-round
history.

### 03-ruling-composer.md and 04-ruling-longcat.md — the 3-ruling quorum

Two independent model rulings (grok-composer-2.5 and longcat) on the three
open design questions the freeze needed settled before any red could be
authored against them:

- **Q1 — session lineage shape:** both independently ratified the typed-edge
  list (`parents: [%{session_id, offset, relation}]`, grow-only `relation`
  enum) over a scalar `forked_from`, and named the **NC-12** no-CRDT-journal
  constraint as the load-bearing negative that makes the positive rule hold.
- **Q2 — actor attribution breadth:** the two rulings **disagreed** here —
  composer picked a middle/broad shape (optional `actor` on every `kind:
  "event"` record, `bill_to`/`cost_ref` only on spend-bearing records);
  longcat picked a narrow shape (`actor` only on approval-decision and
  command records, deferring `bill_to`/`cost_ref` entirely). This is the one
  question where the two rulings genuinely diverge — see both files for the
  reasoning; the frozen contract's actual resolution should be checked
  against `harness-freeze-contracts.md` directly.
- **Q3 — model/params fingerprint breadth:** composer picked "every LLM-bound
  completion" (`item_completed` and `probe_run`); longcat picked "probe_run
  only," with per-turn overrides handled by `turn_started.payload` instead.
  Also a genuine disagreement.

Read together, these are the third leg of the quorum (the first two being
the two longcat audits above); the "5-model quorum" cited in the PR body
draws on this pair plus the earlier audit passes.

### 05-grok45-future-ideation.md — future-feature reservations

A forward-looking pass asking which "one-way-door" fields need to be
reserved *now* (even if unimplemented) so that future features — session
fusion, tournament/branching, wake-on-schedule agents, annotation/label
layers, redacted export — don't force a breaking rename of the frozen
contract later. Ranks a "Top 8" reservation list by
`(rewrite severity if missed) × (who will actually want it)`, a
"composes-free" table of features that need zero new reservation, and four
named conflicts (record-level DAG vs. linear-journal-forever;
cross-session provenance vs. the `refs` session-scoping law; annotations/
schedules leaking into the conversational tip; in-journal branch tournament
vs. copy-on-fork) with their resolutions. This is the source of the
`branch_id`, lineage-edge, and `effect_class`/`egress` reservations that
later rulings (03/04 above) and the frozen contract build on.

## Sources

All five files originated as session-local scratchpad output during the
harness-agent freeze work and were copied here from:

```
/private/tmp/claude-501/-Users-jabher-IdeaProjects-raxol/cd188a1b-a6bf-4953-955f-e63c22d0865c/scratchpad/
  longcat-freeze-audit.out       -> 01-longcat-freeze-audit.md
  longcat-delta-audit.out        -> 02-longcat-delta-audit.md
  ruling-composer.out            -> 03-ruling-composer.md
  ruling-longcat.out             -> 04-ruling-longcat.md
  grok45-future-ideation.out     -> 05-grok45-future-ideation.md
```

All five sources were present and copied — none were missing. Only leading
tool-narration preamble lines (the agent's own "I'll start by reading..."
process narration, which carries no audit content) were stripped; the
audit/ruling content itself is verbatim.
