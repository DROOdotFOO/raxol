# Harness Process — how this gets built without lying to ourselves

Fused from: the quality-loop and PR-gauntlet standing rules (V-confirmed;
memory-ratified), `../proposals/in-flight/harness-ui-PR-GAUNTLET.md` (ADOPTED
2026-07-17), `harness-reviews/DREW-PATTERNS-META.md` (the 24h/70-finding
analysis; raw corpus in `harness-reviews/DREW-FINDINGS-24H.md`),
`harness-ui-methodology.md` (changeset-fusion), `harness-ui-execution-plan.md`
(roles), and the eval-first ruling. Everything here is **adopted practice**,
not proposal.

---

## 1. The quality loop (V: "keep it as it is")

Every unit ships as: build agent → draft PR → **independent adversarial
review** (severity-tagged, failure-arm-focused) → fix agent with **mandatory
regression tests for each red** → merge. Drew (DROOdotFOO) is the
second-pair-of-eyes merger — we never merge. Plan/sequencing decisions get
the grok triad (grok-4.5 + grok-composer-2.5-fast + longcat, independent
runs); longcat is the cheap default second opinion, always async. Spikes
(throwaway, isolated) precede high-risk architecture — the U5 kill spike
overturned all three plan reviewers' topology assumption.

**The wave-2 postmortem (2026-07-17, binding):** wave PRs shipped without the
adversarial stage and Drew caught what the skipped stage should have. Standing
fixes: (a) NEVER ship a PR without the independent adversarial pass (not the
author-lead); (b) claims-audit gate — every moduledoc/PR guarantee maps to a
named test or is reworded as explicitly aspirational; (c) design briefs
include a doc-vs-artifact parity check and a security persona whenever the
unit touches input, files, processes, or queues.

**Red-first variant (V-sanctioned):** for a frozen-contract fan-out, author
all red suites before any impl — enabler commit + red-suite commit per PR;
`:harness_red`-tagged reds excluded in CI; dead-injector negative controls
run UNTAGGED (they test the tests); every contour has both a positive and a
negative side. Impl phase = "make the merged reds green."

**"Renders something TRUE" rule:** on safety surfaces the bar is not "the
fix stops the crash" — ask what the recovery/default RENDERS and whether it
is TRUE. Missing safety data renders as an explicit unsafe-warning, never a
reassuring zero-state.

## 2. The changeset-fusion methodology (rules R1–R11, condensed)

Changeset = the atom; branches and PRs are projections. One commit per unit,
amended in place; unit branches single-owner; the fusion branch is rebuilt by
script, never maintained, never pushed; PRs open only when all deps merged.
The learned rules: R1 one commit always · R2 disjoint write-sets (two units
needing one hunk = a missing interface unit) · R3 conflicts fixed at the
changeset, never in the fusion · R4 `git checkout mix.lock` + conflict-marker
grep before commit · R5 verify every fusion merge with
`merge-base --is-ancestor` · R6 contract-only-grows between units · R7 unit
gates prove the changeset, fusion gates prove the composition · **R8
demonstrated-red everywhere** (a green test never shown to fail is not
evidence; record the red run in the PR body) · **R9 cross-boundary tests
drive REAL producers, never synthetic maps** · R10 scope fence (a discovered
bug becomes a unit iff a mapped acceptance depends on it; else backlog) ·
R11 no wall-clock/timestamp asserts in the default suite — assert structure
and sequence position, never time. Push is orchestrator-owned; builders
commit, never push.

## 3. The PR gauntlet (ADOPTED — run on EVERY PR and EVERY fix commit)

Derived from the 24h Drew corpus (48 review entries, ~70 C/H/M findings,
PRs #587–#629); 7 root-cause classes explain ~86% of findings. All CRITICALs
and BLOCKs live in fail-open ∪ proxy-validation; the count mass lives in
claims ∪ vacuous-tests (the enablers). Ordered by yield:

0. **Persona order:** New Hire first ("which documented sentence has no
   enforcing line?" — the multi-persona convergence attractor); Security only
   on fs/env/process/network seams; Saboteur on hot loops, missing-data
   paths, state machines.
1. **Byte-boundary trace** (class A, 11%): every device/scrollback write
   routed through the sanitization seam (TermText/ContentGuard) *at the write
   seam*; ingress fixed-point test (`sanitize∘sanitize = sanitize` — the only
   mechanism that earned an on-the-spot CLEAN); "no raw ANSI" tested with
   ESC/CSI/OSC/8-bit C1/embedded `\n`/invalid UTF-8, never alphanumerics.
2. **Guarantee → enforcement → falsifier** (class B, 15%, largest): each
   stated guarantee names the enforcing line and the test that fails if it
   breaks; grep new public functions for production callers — zero callers ⇒
   declare **SEAM** ("unwired; inert until X lands") in title+moduledoc; Drew
   accepts honesty as *full resolution* for unwired code. Complexity claims
   measured, never asserted. Maintain the wiring ledger (dormant seams +
   before-live-traffic preconditions), linked from the PR body.
3. **Absence-semantics sweep** (class C, 13%, 1 CRITICAL): every
   `Map.get` default / optional param / rescue / catch-all on approval,
   authz, degradation, or keybind-guard paths — what does *missing* mean?
   The safe default is the restrictive one. What the default renders must be
   TRUE ("no effects declared" ≠ "no effects"). Over-reporting danger is
   fail-safe; under-reporting is not.
4. **Referent-vs-representation** (class G, 14%, the all-CRITICAL class): am
   I checking the thing or a proxy? prefix ≠ host; lexical path ≠ realpath;
   key-exists ≠ gate-accepted; partial id ≠ identity; one flag ≠ the real
   question. Tests use an INDEPENDENT oracle, never the module's own output.
5. **Generator/oracle audit** (class D, 14%, the enabler): (a) generator
   contains the hostile alphabet; (b) oracle independent of the impl; (c) no
   test pins a default instead of challenging it; thresholds detect
   weakening, not just removal; no blanket `:skip_on_ci` on sole coverage.
6. **Growth inventory** (class E, 13%): one table per PR — every new
   collection/queue/accumulator/loop → its bound → the enforcer; per-frame
   code touching session-lifetime data is an automatic flag; caps state
   items-vs-bytes.
7. **Fix-commit re-gauntlet:** fixes get the full pass (two fix-introduced
   defects in 24h); when the reviewer names the owning seam, the first fix
   goes to THAT layer — never a better heuristic at the wrong one.
8. **Visual-doctrine falsifiers** (any rendering diff): unbound pixel ·
   timer-clocked motion · claimed prominence · register bleed · performed
   activity · unearned ceremony · (v2) label-vs-binding divergence.

**Response playbook (deterministic):** behavioral finding → enforcement +
reproduction (red→green, re-breakable tripwire, measured delta); claim
finding on dormant code → honest disclosure; NEVER a doc patch for a
behavior gap. Reachability rebuttals also enforce the invariant with a
tripwire; severity stays worst-case, only verdicts are reachability-weighted
— mirror that split, don't argue severity down. A BLOCK verdict requires a
recorded resolution round before merge. Check `gh pr checks` before
re-requesting review. Negative results are disclosed.

**Red lines (structural, never re-litigate):** no raw ANSI in View DSL
strings; all device writes through the sanitization seam; no `\e[2J`/`\e[3J`
on the inline surface (the byte law is substrate-scoped post-pivot; the
discipline stands wherever the inline path runs); fail-closed on
approval/authz/degradation; explicit-unknown over reassuring-zero; no
wall-clock where a work-metric exists; **no Co-Authored-By trailers** (Drew's
standing requirement); mix.lock gates first, checkout last.

## 4. Cross-lane and checkout discipline

The two-lane split (harness-agent = agentic layer + protocol; harness-ui =
components/rendering) is governed by `../proposals/in-flight/harness-SYNC-ACCORD.md`
(binding): own-lane ledgers only; protocol spec agent-owned with UI required
reviewer (frontend spec reciprocal); worktree namespaces; V-escalation items
never re-litigated lane-to-lane. Hard-learned checkout rules: worktree agents
never `git checkout` a shared branch, never touch the main checkout, never
stash it — fetch + reset in their own worktree, push via refspec
(`git push origin HEAD:<branch>`), rebase-never-force past a collaborator's
commit; verify the main checkout's branch after any agent that disclosed
checkout gymnastics; never `git clean` while lane docs ride untracked.

## 5. The eval-first meta-pattern (governs both lanes)

Every abandoned scaffold in the industry retrospective compensated for a
model weakness that expired; the survivors had falsifiers. Therefore:
anything built atop model behavior (or a platform weakness) ships with a
measured exit criterion — probe sunsets ("delete when provider-native X
matches on eval"), the U23 eval unit gating Wave 4, the U14 control arm vs
provider-native compaction, the tmux_conservative tier's re-measure exit,
interrupt stubs' U5 exit. A scaffold without a falsifier outlives its reason.
