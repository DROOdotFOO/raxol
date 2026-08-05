# In-flight harness docs: index and glossary

One page, scannable. If you're a red-suite author (or reviewer) landing in
this directory cold: start with `harness-freeze-contracts.md`, then use the
tables below to find where any tag you hit (`AD-6a`, `FI-8`, `AF-3`, `I3`,
`N-JS6`, `R1`...) actually lives.

## File → purpose

| doc | purpose |
|---|---|
| `harness-freeze-contracts.md` | **The constitution.** Frozen shapes (journal record kinds, meta/taint contract, probe runner interface) that red suites are authored *against*. Everything else in this directory is either an input to it (research) or a consumer of it (protocol/roadmap). |
| `harness-roadmap.md` | The autonomous-units dependency chart (DAG): what U1, U4, U9, U12... are, their ordering, and the false-parallel warnings the freeze resolves. |
| `harness-invariants.md` | I1-I10 (the permanent Tier-1/Tier-2 guards) + the meta-invariants (fired-counters, seed-reproducibility, oracle independence: the rules every red suite itself must obey). |
| `harness-spec-protocol.md` | The shared typed contract (`Event` envelope, §3 meta table) both backend and frontend conform to: the "zod schema" of the split. |
| `harness-spec-backend.md` | The headless core spec (process topology, journal, probe swarm, control/meta layers). §4's Ecto/DETS/Oban sub-decision is superseded by D1/D2: see the banner in that file. |
| `harness-spec-frontend.md` | The detachable-UI spec: pure protocol subscribers, holds nothing durable. |
| `harness-synthesis.md` | Cohort-research synthesis (Phase 5-6): a primary source of `AD-*` (architecture-disposition) tags. |
| `harness-storage-research.md` | Round-2 cohort research (journal/storage/commands): a primary source of `AD-9..15` and `FI-*` (finding-item) tags. |
| `harness-storage-foundations.md` | Research pass hunting for storage-shaping features that become structural rewrites if added post-freeze. Feeds ratified fixes into `harness-freeze-contracts.md`. |
| `harness-future-foundations-ideation.md` | Ideation pass over the *next* reservation tier (R1-R6 = RESERVE-NOW; the `F1`-`F18` candidate table in §3.1 is a **separate** numbering from `harness-freeze-contracts.md`'s `AF-*` audit-finding tags: see the ID-prefix map below). |
| `harness-community-gaps.md` | Gap-pattern synthesis: ~93 community fixes to popular agent harnesses, clustered and mapped against the freeze. Research/input, not itself frozen. |
| `harness-yolo-safe-research.md` | YOLO-safe-by-construction research/design: the auto-approve predicate (`effect_class`/`egress`) frozen in `harness-freeze-contracts.md` §5.2 traces back here. |
| `harness-design.md` | Design record: the seven concepts + architecture narrative. Companion to `harness-synthesis.md` and `harness-baseline-features.md`. |
| `harness-baseline-features.md` | Reference list of "table stakes" features (the floor, not the differentiators). |
| `harness-facts-two-perspectives.md` | Raw fact extraction (operator + systems vantage) over `harness-research/01-09`, zero processing: an input to `harness-design.md` and `harness-synthesis.md`. |

### Retirement policy

When a document's findings are ratified into `harness-freeze-contracts.md`,
delete it and keep the citation. Git is the archive. Research kept "for
provenance" only accumulates: the previous archive reached 24 files and 4,926
lines before it was removed, every one of them already consumed.

`harness-cohort-research.md` (phase 1-2 frame and priors for the first
cohort-research round) and `harness-research/` (the raw per-topic briefs `01`-`09`
from the first cohort, `10`-`16` from the storage round, `spike-u5-kill.md`, and
the `audit-trail/` rulings) went that way. Citations to them below are provenance
labels, not live paths. Retrieve any of it from git:

```bash
git log --diff-filter=D --format='%H %s' -- docs/proposals/archive/
git show <sha>^:docs/proposals/archive/harness-research/06-horror-stories.md
```

Non-`harness-*` files in this directory (`palette-inventory.md`, `t0-runbook.md`,
`t0-verdict-schema.md`) belong to the UI/rendering lane, not this constitution;
out of scope for this index.

## ID-prefix → owning doc

| prefix | meaning | owning doc |
|---|---|---|
| `AD-<n>` (e.g. `AD-6a`) | architecture disposition | `harness-synthesis.md` + `harness-storage-research.md` (sublabels like `AD-3a`/`AD-3b`/`AD-6a` are glossed inline at first use in `harness-freeze-contracts.md`, but the parent `AD-3`/`AD-6` are defined in `harness-synthesis.md`) |
| `FI-<n>` (e.g. `FI-8`) | finding-item | `harness-storage-research.md` |
| `AF-<n>` (e.g. `AF-3`) | adversarial-audit finding (longcat/review) | `harness-freeze-contracts.md`: **do not confuse with `F<n>` below.** The audit trail behind these (5-model / 93-find run) lives in the PR review threads, not in a committed corpus doc. |
| `F<n>` (e.g. `F5`, `F9`) | future-foundations reservation-candidate tag | `harness-future-foundations-ideation.md` §3.1/§3.2 (the verdict table + detail sections). **Distinct namespace from `AF-<n>` above**, `harness-freeze-contracts.md` uses bare `F<n>` for only two things now: (1) two genuine future-foundations citations (the `annotation`/`schedule` kind rows, `F14`/`F9`); (2) references to the separately-named `f2-action-registry.md` doc ("the F2 `Raxol.Action` draft") in §5.2, a third, unrelated `F2`, every other bare `F<n>` that used to appear in `harness-freeze-contracts.md` was an audit-finding collision, now renamed to `AF-<n>`. |
| `NC-<n>` (e.g. `NC-12`) | frozen negative constraint | `harness-freeze-contracts.md` |
| `OQ-<n>` (e.g. `OQ-JS1`) | open question, ruled | `harness-freeze-contracts.md` (§1.5/§2.5/§3.5 "Ruled" sections) |
| `P-<n>` (e.g. `P-JS4`) | positive-contour property | `harness-freeze-contracts.md` |
| `N-<n>` (e.g. `N-JS6`) | negative-contour required failure | `harness-freeze-contracts.md` |
| `meta-inv <n>` | meta-invariant (fired-counter, seed-reproducibility, oracle independence, ...) | `harness-invariants.md` (defined under "Meta-invariants"); cited throughout `harness-freeze-contracts.md`'s red-suite obligations |
| `I<n>` (e.g. `I1`-`I10`) | permanent Tier-1/Tier-2 invariant | `harness-invariants.md` |
| `U<n>` / `U<n>-R` (e.g. `U9`, `U9-R`) | roadmap unit / its red suite | unit definitions in `harness-roadmap.md`; the red suites themselves are test code (not a doc), one git branch per unit (e.g. `red/u9-checkpoint`) |
| `R1`-`R6` / `R-tags` | future-foundations RESERVE-NOW candidates | `harness-future-foundations-ideation.md` (R1 = session-lineage-as-typed-edges, §3.1) |

## Acronyms (expanded once)

- **CAS**: content-addressed store. Snapshots/blobs are written to
  `<session>/snapshots/<sha256>.json` / `<session>/blobs/<sha256>`, named by
  the hash of their own bytes (dedupe + integrity for free).
- **SpendGate**: the reserve-before-call budget gate (`Ledger.try_spend`)
  that every provider call must pass through; `AD-6a` names its frozen
  discipline.
- **TEA**: The Elm Architecture, Raxol's canonical `init/1` + `update/2` +
  `view/1` application model (see root `CLAUDE.md`).

## Provenance note

The PR review that produced the `AF-*` rename (5-model / 93-find adversarial
audit) is real, but the individual findings were never committed to this
corpus as a standalone doc: the audit trail lives in the review threads
themselves, not here. This index intentionally does not fabricate a doc for
it.
