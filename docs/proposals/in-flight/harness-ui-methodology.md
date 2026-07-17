# Harness UI — Implementation Methodology (changeset-fusion workflow)

Date: 2026-07-15 · Status: working method for executing `harness-ui-roadmap.md`
(and reusable for any DAG-of-units lane). Formalizes what the component wave
(PRs #535–541 + the local `harness-preview` merge branch) did ad-hoc.

---

## 0. The model in one line

**Changeset = the atom; branches and PRs are projections of it.**
One commit per unit makes the commit a portable patch — cherry-pickable onto
any base — which is what lets a non-linear DAG live inside linear-parent git.

## 1. Objects

| object | definition | lifetime |
|---|---|---|
| **changeset C(T)** | exactly ONE commit implementing unit T (roadmap unit = one seam = one PR) | amended in place until merge; never split |
| **unit branch** `feat/harness-ui-<T>` | holder for C(T); force-push allowed (single owner) | until merged |
| **fusion(S)** | `master` + `git merge --no-ff` of changesets in set S, built by script | throwaway; rebuilt on every change |
| **integration branch** `harness-ui-fusion` | fusion(all in-flight units); **never pushed** | rebuilt, never maintained |
| **PR(T)** | projection: `master + cherry-pick C(T)`; opened only when ALL deps of T are merged (hold-until-merge — V's call, no stacked PRs) | regenerable |
| **STATE doc** | the DAG ledger: per unit {planned · building · committed · PR#n · merged} + sha + **the unlock frontier** (units whose deps are all merged) | updated on every transition |

## 2. The loop

Two frontiers move independently — **build frontier** (deps committed or
merged: agents may start) and **PR frontier** (deps merged: PR may open).
Building runs ahead of reviewing; the fusion is where the ahead-of-review
work composes.

```
1. Orchestrator reads the STATE doc, picks every unit on the BUILD frontier
   (all deps committed-or-merged) — as many in parallel as the DAG allows.
2. Per unit: spawn a builder agent in its own worktree checked out at
   fusion(deps-of-T). Agent implements, runs gates, commits ONCE.
3. Orchestrator: rebuild harness-ui-fusion = fusion(all). Run fusion gates.
   Update STATE.
4. PR frontier: every committed unit whose deps are ALL merged gets PR(T) =
   master + cherry-pick C(T), pushed, opened. Multiple PRs open concurrently
   — the frontier is a SET, not a queue. One commit = the review surface.
5. Review round → fixes amend C(T) → force-push → rebuild fusion → STATE.
6. On each merge: drop C(T) from the fusion set, recompute both frontiers
   (a merge typically unlocks several units at once — dispatch them all),
   cut newly-unlocked PRs. Update STATE.
```

## 3. Rules (each one is a learned lesson)

- **R1. One commit, always.** Review fixes via `git commit --amend`. A unit
  needing multiple logical commits = unit was mis-cut; split the unit in the
  roadmap, not the history.
- **R2. Write-set discipline.** Parallel units must have disjoint write-sets
  (unit = one seam guarantees this if the DAG is honest). Two units needing
  the same hunk = missing interface unit (the agent lane's TH/MS lesson):
  extract it, land it first, add DAG edges.
- **R3. Conflicts are fixed at the changeset, never in the fusion.** The
  fusion is deterministic output; if `fusion(all)` conflicts, a changeset (or
  the DAG) is wrong. No manual resolution inside `harness-ui-fusion`, ever.
- **R4. `git checkout mix.lock` before every commit** (resolver drift), and
  `grep -c '<<<<<<<'` == 0 across the tree before commit.
- **R5. Verify every fusion merge:** `git merge-base --is-ancestor <branch>
  HEAD` per merged branch (the false-clean-merge lesson — a silently aborted
  merge once passed tests on old code).
- **R6. Contract-only-grows applies to interfaces between units:** an
  interface changeset (struct, behaviour, event kind) may gain fields after
  landing but never rename/remove while dependents are in flight.
- **R7. Fusion is the only place cross-unit behavior exists.** Unit gates
  prove the changeset; fusion gates prove the composition. Both must be green
  before a PR advances from draft.
- **R8. Demonstrated-red everywhere (generalized from the T2a/T2b/T1 suite-first
  rule — every W1 PR that skipped it took an external HIGH).** Every unit's
  HEADLINE invariant test must record a kill: seed the bug, show the test red,
  cite the red run in the PR body. The anti-stub mutation gate specced for T13a
  applies to *all* units. A green test that was never shown to fail is not
  evidence.
- **R9. Cross-boundary tests drive REAL producers, never synthetic maps.** A
  test that constructs the shape it's testing (hand-built event maps, single-
  golden fuzz, a re-normalized `.raw`) proves internal consistency, not reality.
  If a unit's claim is "agrees with X / round-trips through Y / survives the
  real driver," the test must feed X/Y's actual output. (T27's cross-shape
  property was a fiction until it drove the real EventTranslator.)
- **R10. Scope fence (anti-dilution).** A discovered pre-existing bug becomes an
  owned unit **iff a mapped unit's acceptance criterion depends on it**;
  otherwise it is backlogged, not built.
- **R11. No wall-clock, no timestamp-comparison, in the default suite (recurred
  3×: TP drain-barrier, T26 render-cap, T28a ordering).** Two failure shapes,
  one rule — assert *structure/sequence*, never *time*: (a) a `:timer.tc`/"within
  budget" assertion passes on a fast dev box and reddens on a slow CI runner →
  assert the algorithmic fact (the cap fires the fallback path) deterministically;
  put the number behind `@tag :bench`/`:slow`. (b) an ORDERING assert that
  compares monotonic timestamps (`a_at < b_at`) is false-red when a coarse clock
  (Windows ~15ms) collapses two fast events to the same value → assert **recorded
  sequence position** (index-of-a < index-of-b in the recorder's append-order
  list), which is platform-independent by construction. Same family as the
  positional-byte-order fix (#565): order is a *position* fact, not a *time* fact. (T27/T28a passed — T13a/T2d acceptance
  depended on them; handle_ri/dual-region-stores/MLI-dispatch/CI-flakes were
  correctly backlogged.)

## 4. Gates

| level | command | when |
|---|---|---|
| changeset | `MIX_ENV=test mix compile --warnings-as-errors` + unit tests + `mix format --check-formatted` + credo | before the agent's single commit |
| fusion | full suite (`--exclude slow --exclude integration --exclude docker`) + `mix raxol.playground` smoke (visual check for UI units) | after every fusion rebuild |
| PR | reviewer agent pass (adversarial, one finding per line) on the single commit's diff | before undraft |
| **advisory (flaw-triggered)** | when a review detects flaws, spawn `grok -p` advisors per flaw class — **tests/invariants → grok-4.5 · code quality → grok-composer-2.5-fast · conceptual/ideation → longcat**; multiple classes = multiple advisors. Always async/non-blocking (esp. longcat: slow but ultra-cheap — lean on it liberally); advisories fold into the fix-round re-review or PR body, never gate the amend itself | after any non-clean review verdict |

**Escalation policy (standing):**
- **Hard cases → the whole triad** (grok-4.5 + grok-composer-2.5-fast + longcat, independent runs): architecture-binding decisions, keystone/foundation units, anything a wrong call is expensive to unwind (D-PA-class verdicts, render-substrate seams, security/correctness invariants, cross-unit interface changes). Same discipline as the plan/roadmap triad reviews.
- **Uncertainty → longcat** as the default second opinion, always async. It is slow but ultra-cheap (~$2 / 50M tokens) — reach for it liberally whenever a call is non-obvious, a design tension is unresolved, or a review verdict is close. Never block on it; fold its read into the next re-review or the PR body. Under-using longcat is the failure mode, not over-using it.
- Routine single-flaw reviews stay on the per-class single advisor above; escalate only when hardness or uncertainty is real.

## 5. Mechanics (concrete commands)

Fusion rebuild script (idempotent, the whole thing):

```bash
git -C "$FUSION_WT" checkout -B harness-ui-fusion master
for b in $(cat .fusion-set); do
  git -C "$FUSION_WT" checkout mix.lock 2>/dev/null
  git -C "$FUSION_WT" merge --no-ff --no-edit "$b" \
    || { echo "FUSION CONFLICT: $b — fix the changeset, not the merge"; exit 1; }
  git -C "$FUSION_WT" merge-base --is-ancestor "$b" HEAD \
    || { echo "MERGE DID NOT LAND: $b"; exit 1; }
done
```

PR projection (only when all deps of T are merged):

```bash
git checkout -B "pr/harness-ui-$T" master
git cherry-pick "$(git rev-parse feat/harness-ui-$T)"  # the ONE commit
git push -f origin "pr/harness-ui-$T"
gh pr create --base master ...
# PR body edits via: gh api --method PATCH repos/<owner>/raxol/pulls/N
# (gh pr edit is broken on the projectCards GraphQL deprecation)
```

Dep amended after dependents built → re-cherry-pick dependents' changesets on
next fusion rebuild (cheap because every changeset is one commit; conflicts
here mean R2 was violated).

## 5b. Push is orchestrator-owned

Builders and fixers **commit only, never push** (the permission layer denies
agent-relayed force-push to a public remote — correctly, it isn't direct user
auth). The orchestrator (main thread, where push rights are established this
session) does every `git push -f origin <branch>` + `gh pr create`. Dispatch
prompts say "commit, do NOT push"; the orchestrator collects the sha from the
builder's final message and pushes + opens the PR itself. This also keeps PR
bodies consistent (one author) and the `origin` target correct (a stale `fork`
remote once mis-resolved to a different owner).

## 6. Agent roles

- **Builder** (one per unit, worktree-isolated): implements from the roadmap
  unit spec + specs alone ("autonomous unit" property), runs changeset gates,
  commits once with trailer discipline. Never touches files outside the
  unit's write-set.
- **Finisher** (recovery pattern): if a builder dies mid-flight, work sits
  uncommitted in its worktree — spawn a lightweight finisher to gate+commit
  rather than rebuild (the quota-crash lesson).
- **Reviewer** (per PR): adversarial single-pass on the one-commit diff;
  findings go back to the builder (or orchestrator amends). MUST ask the three
  test-binds-to-reality questions (imported from Drew's external review, which
  caught what internal review missed on 5/5 W1 PRs): (1) does each test drive
  the REAL producer, or a synthetic stand-in? (2) can the assertion actually
  FAIL — is there an input that reddens it, or is it tautological/unsatisfiable?
  (3) is the golden/fuzz set adversarially DIVERSE, or one happy-path fixture
  whose prefixes all pass? A green suite that fails all three is "correct on
  benign input," not correct.
- **Orchestrator** (main session): cuts interface changesets, owns the DAG
  state + fusion rebuilds + PR projections + merge order, runs the visual
  smoke on fusion (screenshots to V when it matters).

## 7. Observability — the STATE doc

`harness-ui-STATE.md` (internal, beside the roadmap) is the DAG ledger:

```markdown
| unit | state     | sha     | PR   | blocked on      |
|------|-----------|---------|------|-----------------|
| T0   | merged    | abc1234 | #548 | —               |
| T2a  | PR-open   | def5678 | #549 | —               |
| T2b  | committed | 9abcdef | —    | T2a merge       |
| T4   | building  | —       | —    | —               |
| T13  | planned   | —       | —    | T2c,T3,T7,T10.. |

BUILD frontier: T2b, T2c (T2a committed)
PR frontier:    T2a
```

- Updated on every transition; the single answer to "what's pushed under
  which PR, what's merged, what's unlocked now."
- **The DAG is a partial order, not a sequence** — both frontiers are sets;
  everything in a set proceeds in parallel. A merge recomputes the frontiers
  and typically unlocks several units at once.
- `harness-ui-fusion` is the *visual* progress view: run the playground there
  — everything in flight, composed, live.
- `master`'s history still reads in dependency order (a PR can only exist
  once its deps merged), but never single-file — independent subtrees
  interleave freely.

## 8. Failure modes this design closes

| failure | closed by |
|---|---|
| non-linear DAG vs linear git | changeset-as-portable-patch (cherry-pick projections) |
| big-bang unreviewable branch | one commit = whole review surface |
| integration drift ("works on my branch") | fusion rebuilt + gated on every change |
| silent merge aborts / stale-code green tests | R5 ancestor verification |
| two agents in one file | R2 write-set discipline + interface units |
| review fixes tangling history | R1 amend-only |
| lost work on agent crash | worktree persistence + finisher pattern |
| fusion becoming load-bearing state | never pushed, rebuilt from script, R3 |
