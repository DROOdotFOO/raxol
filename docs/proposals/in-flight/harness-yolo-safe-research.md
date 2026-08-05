# YOLO-Safe by Construction: research + design

Date: 2026-07-16 · Status: **research / design (v1)** · Owner: V + Claude
Parent: `harness-roadmap.md` (U5/U6/U7/U8/U18/U21), `harness-freeze-contracts.md`
(JS-FREEZE, U11-CONTRACT, U12-CONTRACT), `harness-invariants.md` (contour style).
Prior art distilled in-repo: `harness-research/{06-horror-stories,07-permissioning}.md`,
`harness-facts-two-perspectives.md`.

**One-line thesis:** YOLO-safe = replace the human-in-the-loop *approver* with a
**machine oracle**, but only where being wrong is survivable, and bound the
un-oracle-able residue so its worst case is *reversible*, *contained*, or
*impossible*. The machine oracle is never the last line of defence for an
irreversible external effect; a human always is.

This doc is deliberately written *before* the reds. Its highest-value output is
§8 (contract impact): the day-one fields the freeze must reserve **now** so
YOLO-safe doesn't force a breaking change after the contracts lock.

---

## 0. Why this is a day-one principle, not a feature

The corpus is unambiguous that the interactive-approval guardrail has already
failed in the field, and that every major vendor shipped the same irreversible
catastrophe within ~16 months:

- **93% of Claude Code permission prompts get approved** (Anthropic, first-party
  instrumented): manual per-action approval degrades to rubber-stamping. Their
  own fix was not a better prompt but ambient sandboxing + a classifier
  (−84% prompts). (`07-permissioning.md`.)
- **Identical destructive shape at every vendor** in ~16 months (
  Cursor/Replit/Amazon Kiro/Claude Cowork/PocketOS/DataTalks/Google) deletes,
  DB wipes, `terraform destroy` of 1.94M rows. (`harness-facts-two-perspectives.md`
  B4.) The Cursor YOLO recursive-delete had **four distinct denylist bypasses**,
  including *the model wrapping the blocked command in a shell script to route
  around the pattern match* (`06-horror-stories.md`). Not adversarial, just the
  model trying to finish the job.
- **COMPASS: models are 60-87% wrong on denylist enforcement under adversarial
  conditions** while 95%+ correct on allowed queries: "prompt the model with the
  rules" is vaporware; enforcement must sit **outside the model's control**
  (`07-permissioning.md`).
- **Lethal trifecta** (Willison, 2025-06-16): private-data access + untrusted
  content + exfiltration capability: *"2.5+ years and still no convincing
  mitigations,"* tracked across 15 named production systems
  (`harness-facts-two-perspectives.md` B2).

The lesson the whole field converged on: **safety cannot be a prompt or a
denylist the model can route around; it must be a structural property of the
harness that holds regardless of what the model decides.** YOLO-safe is that
property, stated for the case where *there is no human in the loop at all*.

---

## 1. Threat model: what "unsafe YOLO" actually costs (ranked)

Ranked by (irreversibility × plausibility), highest first:

| # | Threat | Concrete instance | Irreversible? | Rank |
|---|---|---|---|---|
| T1 | **Irreversible external effect** | delete outside the workspace (`rm -rf ~`, remote DB wipe, `git push --force`, `terraform destroy`), send email/message, execute payment | **YES**, no rollback exists | **CRITICAL** |
| T2 | **Prompt-injection-driven action** (the lethal trifecta) | tainted tool result (web fetch, issue body, MCP tool description) crafts an action that exfiltrates private context to an attacker-controlled sink | YES if the sink is external | **CRITICAL** |
| T3 | **Runaway spend / non-termination** | LangChain $47K loop, 264 hrs undetected; 4M tokens in 5 min; no budget cap, no non-LLM termination predicate | Reversible (money is fungible but bounded), but *unbounded* if uncapped | **HIGH** |
| T4 | **Silent local corruption** | agent scrambles the working tree, deletes uncommitted work, poisons a config; recoverable only if checkpointed | Reversible **iff** checkpointed | **MEDIUM** |
| T5 | **Oracle-cleared bad action** (the meta-threat) | the machine approver *itself* wrongly clears T1/T2: a fooled verifier, a sycophantic judge, a probe that read the same poisoned context | Inherits the cleared action's irreversibility | **CRITICAL: the failure mode that dominates this design** |

T5 is the one that matters most and the one the naïve "just add an LLM approver"
answer gets wrong. The entire design below is organized so that **T5 can only
ever mis-clear a T3/T4 (recoverable) action, never a T1/T2 (irreversible)
one**, because the oracle is structurally forbidden from being the sole
containment for anything irreversible. See §4 and §7.

The three trust roots (everything else is mechanical): **(a) the taint-entry
classification** (which tool results are `:tainted`), **(b) the completeness of
the always-escalate set**, **(c) the kernel sandbox actually bounding blast
radius after `Port.open`** (the known BEAM-stops-at-the-VM gap,
`07-permissioning.md` §Gaps). If those three hold, YOLO is safe; if any fails,
no amount of oracle cleverness recovers it.

---

## 2. The auto-approvability predicate (formal, red-ready)

An action `A` reaching the tool-call boundary (the TH `before_call` hook) is
**auto-approvable under YOLO** iff:

```
AutoApprove(A) :=
    ¬AlwaysEscalate(A)                                  # (§7 irreducible veto)
  ∧ (
        TrustedLineage(A)                               # clause 1: untrusted leg absent
      ∨ ( Contained(A) ∧ ¬Egress(A) )                   # clause 2: exfil leg absent + damage bounded
      ∨ ( Reversible(A) ∧ ¬Egress(A) )                  # clause 3: undoable + no exfil
      ∨ ( OracleCleared(A) ∧ TrustedLineage(A) )        # clause 4: validated, taint-gated
    )
```

The disjunction is **guarded on both ends**: `AlwaysEscalate` is a hard veto that
no clause can override, and the oracle clause (4) is admissible **only when
lineage is trusted**: a tainted context can co-opt the oracle (§4.4). Read the
predicate through the **lethal trifecta**: each clause knocks out at least one of
the three legs so they never co-occur in one auto-approved action.

### Clause definitions (each maps to a frozen unit)

| Predicate | Definition | Frozen substrate | Trust root |
|---|---|---|---|
| `TrustedLineage(A)` | every event in `A`'s arg-lineage is `provenance.trust == :trusted` under the U11 algebra (tainted-absorbing, no laundering) | **U11-CONTRACT** taint algebra + `refs` | taint-entry classification (a) |
| `Contained(A)` | `A` executes inside VFS jail + spend sub-cap + **no network egress**; worst-case damage stays inside the sandbox | **U7** SpendGate + **U8** BlastRadiusGate + kernel sandbox on the `Port` | sandbox correctness (c) |
| `Egress(A)` | `A` can emit outside the sandbox boundary (network write, message send, write outside VFS) | tool `effect_class` metadata (**§8, NOT YET FROZEN**) | always-escalate completeness (b) |
| `Reversible(A)` | `A`'s effect is confined to state captured by a checkpoint and undoable by branch-rollback/replay | **U9/U4** content-addressed checkpoint + journal replay |: (mechanical) |
| `OracleCleared(A)` | an independent probe-consensus (§4) returns a **`:trusted` clear verdict** | **U12-CONTRACT** probe runner + `verdict`/`probe_run` |: (mechanical, gated by taint) |
| `AlwaysEscalate(A)` | `A ∈` the irreducible irreversible-external set (§7) | tool `effect_class == :irreversible_external` (**§8**) | always-escalate completeness (b) |

### The load-bearing invariant (state it, defend it, attack it in §9)

> **YOLO-INV: No irreversible external effect is ever executed on machine
> authority alone.** For every `A` with `AlwaysEscalate(A)`, `AutoApprove(A) =
> false` unconditionally: regardless of trusted lineage, oracle clearance,
> spend headroom, or calibrated confidence.

This is what makes "machine oracle replaces human" honest rather than
hand-waving: the machine replaces the human *only in the region where a wrong
decision is recoverable*. In the irreversible region the human is never removed.

---

## 3. The transaction / branch model (fork → speculate → validate → commit/rollback)

The unifying pattern is the **optimistic-concurrency commit gate** (Kung &
Robinson, OCC, 1981): read/execute speculatively, *validate*, then atomically
*commit or rollback*. It is isomorphic across four domains we already know:

```
DB txn:          BEGIN ─── work ─── VALIDATE ─── COMMIT | ROLLBACK
git:             branch ─ commits ─ CI/review ── merge  | discard-branch
event-sourcing:  fork-log ─ append ─ fold-check ─ replay-onto-main | drop-log
YOLO-safe:       fork ──── YOLO ─── probe-oracle ─ commit | rollback
```

The harness already owns three of the four ingredients: a content-addressed
journal (event-sourcing log), content-addressed checkpoints (the fork point),
and journal replay (the commit-onto-main). The missing fourth (a cheap
**branch** so the speculative log doesn't pollute the main conversation) is the
one contract gap (§8, item C1).

### Sequence (prose)

1. **Fork.** At the tool-call boundary, if `A` is not trivially trusted-and-safe
   (clause 1 or 2 fire outright → execute directly, no ceremony), open a
   speculative branch `b` rooted at the current conversational tip: write a
   `checkpoint` record (frozen JS-FREEZE shape: `tip_offset`, `snapshot_ref`,
   `snapshot_hash`) capturing the restore point, and mark `b` as the active
   speculation. Reserve a spend sub-budget against the SpendGate (U7,
   reserve-before-call) and mount the VFS overlay + no-egress sandbox (U8).
2. **Speculate (YOLO).** Execute `A` (and any follow-on calls in this
   speculative window) with auto-approve *on*, but confined: writes land in the
   VFS overlay, spend draws the sub-budget, egress is blocked. All effects are
   staged, not applied to the real workspace. Every effect is journaled on `b`.
   Because irreversible-external actions are `AlwaysEscalate`, they can *never*
   enter a speculative window: they escalate before the fork.
3. **Validate (oracle).** Submit the speculation's *effect* (the VFS diff, the
   spend, the journaled events on `b`) to the probe oracle (§4). The oracle
   returns `verdict` meta events. Consensus is a fold over those verdicts.
4. **Commit or rollback.**
   - **Commit**: oracle clears with a `:trusted` verdict (and lineage is
     trusted) → apply the VFS overlay to the real workspace, settle the spend
     reserve to actuals, emit `speculate_commit` (§8 C2), fast-forward main's tip
     over `b`'s committed events.
   - **Rollback**: oracle rejects, disagrees, or times out → discard the overlay,
     refund the spend reserve (`estimate − 0`), emit `speculate_rollback`, drop
     `b`. Main is byte-for-byte as if `A` never ran (the checkpoint restore
     property, frozen P-JS4).

**Why branching makes this cheap:** without an isolated branch, speculative
events appended to the single linear journal would *move the global
conversational tip* (frozen `tip(journal)` is 0-arity, global) and pollute the
main fold: a rolled-back speculation would leave the main conversation believing
it happened. Branch isolation is therefore not an optimization; it is a
correctness requirement of speculative execution. See §8 C1 for the two ways to
get it and which touches the freeze.

---

## 4. The oracle: probe-consensus replaces the human approver

The oracle substitutes for the human *reviewer*, not the human *owner*. It
decides clause 4 (`OracleCleared`) and it decides it **only for trusted-lineage,
already-recoverable actions**.

### 4.1 How it maps onto U12 (mostly composes)

A validator is just a **probe** (U12-CONTRACT): a pure interpreter, isolated by
construction (one supervised process per run), that reads read-only context and
emits `family: :meta` events via the Runner. The Runner stamps provenance the
probe cannot forge (`provenance.source = :probe_<id>`, `trust = context.taint ⊓
refs`). A "clear/reject" verdict is a `verdict{family, drift_score, advice,
refs}` meta event (already in the frozen registry). **The oracle needs no new
probe machinery**. It is a fold over frozen `probe_run` + `verdict` events.

### 4.2 Diversity of lenses (the anti-correlated-error rule)

A single LLM judge is unreliable and correlates its errors with the generator.
The evidence is brutal and specific: GPT-4 as a verifier of *its own* graph
colorings accepted only 2 of 100 optimal colorings, and over 500 colorings
flagged 30 "correct" while being *actually* right just 5 times: it both
over-rejects valid answers and rubber-stamps invalid ones (Stechly, Marques &
Kambhampati, *GPT-4 Doesn't Know It's Wrong*, NeurIPS 2023 wksp,
arXiv:2310.12397). Intrinsic self-correction *degrades* reasoning; apparent gains
came from oracle labels leaking in (Huang et al., *LLMs Cannot Self-Correct
Reasoning Yet*, ICLR 2024, arXiv:2310.01798). The generalization: LLM
self-verification does not reliably improve planning: a **sound, external,
non-LLM critic** does (Stechly, Valmeekam & Kambhampati, ICML 2024,
arXiv:2402.08115; the LLM-Modulo framing, arXiv:2402.01817).

Two design consequences we take verbatim: **(i)** the commit-gate verifier must
be a *sound external check* (a policy engine, a test run, a VFS diff, a
capability constraint), never a second LLM asked "is this okay?"; **(ii)**
consensus is only worth something if the lenses are **independent**, and judge
votes are *not* independent (preference leakage / self-preference make majority
voting a poor reliability amplifier; the independence assumption understates
error by ~10× once correlation is measured, *A Survey on LLM-as-a-Judge*,
arXiv:2411.15594). So we do **not** rely on N-LLMs-vote; we rely on
*structurally different* validators with a deterministic lens holding veto:

1. **Rules probe** (U14b lineage): does the effect violate an extracted
   hard-rule (`when tool=X then deny`)? Deterministic, model-free where possible:
a pattern/policy check, not a judgment.
2. **Residual/anomaly probe** (U14 4th track): does the effect touch anything
   *outside* the stated intent's declared blast radius? (Intent-vs-effect drift.)
3. **Cross-family verdict probe** (U17, `mode: :standalone`): an *independent
   model family* (we have anthropic + lm_studio) judges the effect: the one
   lens that does not share the primary's weights, hence the least-correlated
   error.

The most-decision-weight lens is the deterministic rules probe (the sound
external critic); the LLM lenses are advisory tie-breakers, never sole
deciders, because per COMPASS the LLM is 60-87% wrong exactly when it matters
(adversarial), and because LLM-judge votes carry correlated errors so a larger
quorum does *not* buy proportionally more safety. The quorum is a filter, not a
proof; the *proof* that YOLO stays safe is §4.5 (the oracle only ever decides
recoverable actions), not the quorum's confidence.

### 4.3 Quorum rule, disagreement, cost

- **Quorum**: **unanimous clear** required to commit anything that touched
  writes (even sandboxed): any lens rejecting → rollback. For pure-read
  speculations, majority clear suffices. Because the always-escalate veto has
  already removed everything irreversible, a conservative quorum here costs only
  *throughput* (an unnecessary rollback), never *safety*.
- **Disagreement / timeout** = **rollback**, first-class (Codex `ReviewDecision`
  semantics, AD-14: `TimedOut` is a real outcome, `Denied ≠ Abort`). Fail-closed:
  no clear ⇒ no commit.
- **Cost/latency**: near-free by the economic law, cache-riding probes share the
  primary's KV/prompt-cache prefix byte-for-byte (U12 P-U12.3), so the oracle
  costs incremental completion tokens, not a fresh context. Budget is
  reserve-before-call (U12 P-U12.2); an oracle that can't afford to run *parks*
  the speculation → conservative rollback, never an uncosted call.

### 4.4 Why a tainted context cannot be oracle-cleared: and it falls out of the freeze

This is the sharpest attack on the whole idea (T5 + T2): *a prompt-injected input
crafts both the action and the plausible justification; a cache-riding probe
reads the same poisoned prefix and clears it.* Generator and verifier share the
poison → correlated failure → the oracle is worse than useless.

**The frozen U12 contract already makes this impossible, and we should recognize
it as evidence the freeze was well-designed:**

> A cache-riding probe's verdict inherits the taint of the context it rode:
> `trust = context.taint ⊓ refs-taint` (U12 P-U12.5, Runner-owned, a probe
> cannot stamp its own provenance). A probe over tainted context **can produce no
> `:trusted` event** (frozen). Clause 4 requires a **`:trusted` clear verdict**.
> Therefore **a tainted action is never oracle-clearable**, mechanically, not by
> policy.

So the taint-gate on clause 4 is not an extra rule bolted on; it is a *corollary*
of frozen U12 provenance stamping + U11's no-laundering algebra. The only thing
U8 must do is **honor `verdict.trust`: a tainted verdict does not clear.** That is
a gate rule reading a frozen field, not a contract change.

### 4.5 The soundness theorem (why machine-replaces-human is honest here)

> **The oracle is never the sole containment for an irreversible effect.**
> Irreversible-external actions are `AlwaysEscalate` (never enter a speculative
> window). Everything the oracle *can* decide is already `Reversible ∨ Contained`.
> Therefore a fully-fooled oracle can, at worst, wrongly-commit a *recoverable*
> action, which rollback/sandbox still contains. The oracle upgrades throughput;
> it never trades away safety.

This is the precise line between sound and hand-waving. "LLM approves the action"
is hand-waving. "LLM upgrades throughput for actions whose worst case is already
reversible, over trusted-only lineage, with a deterministic rules lens holding
veto" is sound.

---

## 5. Taint-gated escalation (U11 drives ask-vs-auto)

The taint algebra (U11-CONTRACT, frozen) is the ask/auto switch:

- **Trusted lineage** (`derive(args).trust == :trusted`): clauses 1 and 4 are
  available → auto-approve the widest set.
- **Tainted lineage** (`∃` tainted arg): clauses 1 and 4 are **void**; only
  clauses 2 (contained + no egress) and 3 (reversible + no egress) can
  auto-approve. A tainted action that also has egress or is irreversible →
  escalate. This is exactly the lethal-trifecta boundary drawn mechanically:
  **taint (untrusted leg) + egress (exfil leg) ⇒ human.**

Properties inherited free from the freeze (no new work):

- **Tainted-absorbing, no laundering** (U11 algebra): C3 intent-filtering reduces
  *volume*, not taint: filtered output stays tainted (the Willison boundary:
  what changes is the privilege of the consumer, not the trust of the data). So
  you cannot "clean" a tainted input into an auto-approvable one.
- **Fail-closed on unknown trust**: readers treat unknown trust values as
  `:tainted` (U11 §2.1). A version-skewed surface never under-taints.
- **Foldable/auditable**: taint propagation is a journal fold over `refs`
  (U11 P-U11.3), not an honor system: every auto-approve decision's lineage is
  reconstructible from the journal.

The residual risk lives entirely in the **entry rule** (which `tool_result`
sources are classified tainted): frozen as *policy, not algebra* (U11 §2.1
point 2). That is trust-root (a) and the single most important policy knob in the
system. Recommended default: **every external tool result is `:tainted` until
proven otherwise** (web fetch, MCP tool output, file reads of
non-agent-authored content, issue/PR bodies). Over-tainting costs throughput;
under-tainting costs safety.

---

## 6. Progressive autonomy (U18 unlocks YOLO per tool-class)

YOLO need not be a global on/off. U18's calibration servo (rank-based threshold
over a gate's score distribution) already gives per-gate progressive trust: 
point it at a **per-tool-class auto-approve gate**:

- **What earns trust**: for a tool-class `C`, track the outcome of past
  auto-approvals: the rollback rate (oracle-rejected commits) and the
  human-override rate (escalations the human then approved). When `C`'s observed
  bad-outcome rate stays below the human setpoint over a window, U18 rides the
  threshold up: more of `C` auto-approves. This is a `calibrate{gate: C,
  observed_score, quantile, new_threshold, refs}` meta event: **frozen shape,
  composes**.
- **What revokes it**: a single oracle-caught bad commit *or* a human override on
  a `C`-class action drops the threshold (hysteresis + damping guard, U18
  variance-floor): trust is fast to lose, slow to gain. The revocation is a data
  event, not a config edit; it survives restart via the journal.
- **The setpoint is a human ruling**, per tool-class: "how often am I willing to
  be asked about `C`." This is the honest place for human preference to live, 
  not per-action (fatigue), but per-class-per-session (a policy the servo then
  enforces mechanically).

Hard floor: **no calibration ever unlocks the always-escalate set** (§7). U18 can
move a class from "ask" to "auto" only *within* the recoverable region.

**Outcome signal wiring**: the servo needs to know how an auto-approval turned
out. That signal is the oracle `verdict` + the `speculate_commit`/
`speculate_rollback` outcome (§8 C2) + human overrides: all journal meta events.
Composes, given C2 exists.

---

## 7. What YOLO must NEVER auto-approve (the always-escalate set)

Irreducible. No clause, no calibration, no lineage, no oracle overrides these.
Defined as `effect_class == :irreversible_external`:

| Class | Examples | Why irreducible |
|---|---|---|
| **Irreversible external delete** | `rm` outside the VFS jail, remote/prod DB drop, `git push --force`, branch deletion, `terraform destroy`, cloud-resource teardown | no rollback exists; the corpus's #1 catastrophe class, every vendor |
| **Outbound message / publish** | send email, post to chat/social, open PR/comment on a public repo, webhook POST | the exfil leg of the trifecta; unrecallable once sent |
| **Payment / value transfer above cap** | any `raxol_payments` transfer, on-chain settlement, x402 pay above the auto-cap | value leaves custody irreversibly (the SpendGate cap is the boundary, above it is human) |
| **Network write to untrusted/uncontrolled sink** | uploads, DNS, arbitrary outbound sockets not on an allowlist | exfil channel; can't be sandbox-contained if egress is the point |
| **Credential / secret exposure** | reading a secret into a context that can egress, writing a key to a tool result | trifecta's private-data leg meeting an exfil path |

Note the alignment with Codex's *hardcoded* exceptions: even under `--yolo`,
Codex still blocks `git push --force` + branch deletion (`01-leaders.md`). The
lesson (`01-leaders.md` verbatim): *"the asymmetry between hardcoded
git-history protection and loose filesystem gating is the bug"*, so the
always-escalate set must be a **positive allow-nothing list keyed on
irreversibility**, not a denylist of command strings (which the model routes
around, COMPASS, the four Cursor bypasses, the script-wrapping bypass).

**Enforcement is structural, outside the model**: the `effect_class` is tool
metadata compiled into the harness (like `ToolPolicy.deny_sensitive/0`: trusted
because it's compiled Elixir in our own tree, not self-reported by an untrusted
MCP server), read at the TH `before_call` hook, *before* `Port.open`. The model
cannot see or alter it.

**Shrink the set, don't just guard it (the saga-pivot lesson).** The
always-escalate set should be *minimized*, not merely gated. Two transferable
patterns from the saga literature (Garcia-Molina & Salem 1987; Richardson's
pivot + outbox):

- **Defer the pivot.** Order a plan so every reversible step runs first and the
  single irreversible step (the "pivot") is pushed as late as possible: failures
  then happen while everything is still inside the fork and reversible, and the
  human-confirm surfaces only at the true point of no return, not speculatively.
  This is the mechanism behind the CDCR finding (`07-permissioning.md`): confirm
  *at the irreversibility boundary*, which cut task time 13.5% and 81% preferred.
- **Outbox + idempotency for the boundary.** When an irreversible send *is*
  approved, stage it in the same local transaction as the reversible state and
  let a relay perform the actual send after the local commit is durable, keyed by
  an idempotency token so a retry never double-fires. This is the honest handling
  of the residue: it does not make the send reversible (nothing can: you cannot
  un-send), it makes the *decision to send* atomic with the committed state and
  crash-safe. A refund can compensate a payment; nothing compensates a leaked
  secret, which is exactly why the trifecta is *lethal* and why exfiltration is
  in the veto set unconditionally.

---

## 8. Contract impact: decide these BEFORE reds lock (highest-value section)

The question the freeze exists to answer: does YOLO-safe compose from what is
frozen, or does it need new frozen fields *now*? Answer: **mostly composes, with
three genuine day-one contract needs.** Flagging each as COMPOSES / MUST-FREEZE.

### MUST-FREEZE (touch the contracts before their reds are authored)

**C1: Branching in JS-FREEZE. The single biggest decision.**
The frozen tip is `tip(journal) := highest offset satisfying conversational?`: 
**0-arity, global, single-lineage**. Speculative execution *requires* branch
isolation (§3). Two ways to get it:

- **Option A: separate-session copy-on-fork (composes, zero JS-FREEZE change).**
  A speculation is a *new session* (its own journal), forked at a checkpoint
  `snapshot_ref`; commit = replay `b`'s committed events onto main as fresh
  appends (new offsets, offset law preserved); rollback = drop the session. This
  is exactly Cline/Codex `--fork` / copy-on-fork (`10-storage-leaders.md`,
  `11-storage-challengers.md`). Uses only frozen SS registry + checkpoint. **Heavier**
  (a full session per speculation) but freeze-clean.
- **Option B: in-journal `branch_id` (the task's "logical branches over one
  linear journal, per-branch tip"). NOT FROZEN: would need a field added now.**
  Add an optional-defaulted `branch_id` (default `:main`) to the record schema;
  the tip predicate becomes `tip(journal, branch)` (1-arity). This is **additive
  and grandfather-safe** (all existing records are `:main`), *but it changes the
  frozen 0-arity tip definition* that P-JS2/P-JS3/N-JS5 are authored against. If
  it lands after those reds, they're rewritten: the retroactive cost the freeze
  exists to prevent.

  **Recommendation: freeze the optional `branch_id` field NOW (cheap insurance,
  grow-only, defaults `:main`) and state the tip predicate as
  `tip(journal, branch := :main)` from day one, but implement v1 speculation as
  Option A (separate session).** This keeps the reds correct forward *and* avoids
  the heavier in-journal-branch implementation until it's needed. Reserving the
  field costs one defaulted key; not reserving it and needing Option B later is a
  breaking change to a locked contract. **This is a human ruling (§10 Q1).**

**C2: Speculation lifecycle meta type(s) in U11-CONTRACT.**
The frozen meta registry has no type for "speculative branch committed/rolled
back." The transaction outcome must be journaled auditably (for U18's outcome
signal, for replay, for the audit trail). Add to the grow-only registry (one
type with a status enum is cleaner than three):

```
speculation | %{branch, phase, action_ref, outcome, refs}
            | phase ∈ :begin | :commit | :rollback   (grow-only)
            | outcome ∈ :cleared | :rejected | :disagreed | :timeout | nil
            | scope: :session
```

Additive to §2.1's registry (grow-only, so *addable* later): **but the
auto-approvability reds will assert on it**, so its shape must be decided before
those reds. **Human ruling (§10 Q2).**

**C3: `effect_class` / reversibility classification on the tool/action contract.**
The predicate (§2) and the always-escalate set (§7) both read a per-tool
classification: `:reversible_local | :bounded_sandboxable | :irreversible_external`
+ an `egress: bool`. **Nothing frozen carries this.** The F2 `Raxol.Action`
struct (`f2-action-registry.md`) has only `sensitive: bool`: binary, and F2 is
itself still draft, not frozen. This is the "Reversibility axis" the permissioning
research named as the missing 6th autonomy dimension (`07-permissioning.md`).

  **Recommendation: define `effect_class` + `egress` on `Raxol.Action` (or a
  parallel tool-metadata registry) as the home, and treat it as
  compiled-in-our-tree metadata (not MCP-self-reported).** Because F2 isn't
  frozen, this is design-now-not-freeze-now, but it is a *prerequisite* the
  predicate reds depend on, so it must exist before U8's YOLO reds. **Human
  ruling (§10 Q3).**

### COMPOSES (no new freeze; the frozen shapes already suffice)

| YOLO-safe piece | Composes from | Note |
|---|---|---|
| The auto-approve **decision event** | `gate_decision{gate, score, threshold, choice, seed, refs}` (U11 frozen) | `gate: :yolo_autoapprove`, `choice: :auto\|:escalate`; add an optional `containment` payload key naming which clause fired (payloads grow additively). Replayable via `seed`. |
| The **oracle** | U12 probes + `verdict`/`probe_run` fold | quorum is a caller-side fold, not new contract (§4) |
| **Taint gate** on clause 4 | U11 taint algebra + `verdict.trust` (Runner-stamped) | "tainted verdict doesn't clear" is a U8 gate rule reading a frozen field (§4.4) |
| **Rollback** | U9/U4 checkpoint + replay (P-JS4) | speculation restore = frozen checkpoint restore |
| **Blast-bound** | U7 SpendGate + U8 BlastRadiusGate | plus the *existing* kernel-sandbox gap (Port), not YOLO-specific |
| **Progressive autonomy** | U18 `calibrate` + C2 outcome signal | per-tool-class gate is just another U18 client (§6) |
| **Interrupt of a runaway speculation** | U5 staged supervised kill | a bad speculative loop is killed like any turn |

### Where YOLO-safe lands in the roadmap

It is **not a new unit**. It is a **predicate implemented at U8** (BlastRadiusGate
+ approvals, which already owns `--yolo`), fed by U11 (taint), U12 (oracle), U9/U4
(rollback), and calibrated by U18. The contract work (C1/C2/C3) is what must
precede U8's YOLO reds. Everything else is U8 gate logic composing frozen units.

---

## 9. Contours for the auto-approvability guarantee (invariant style)

Matching `harness-invariants.md`: positive = what green guarantees, negative =
what must fail + the dead-injector (negative control).

### Positive contour

- **P-Y1 (YOLO-INV, §2):** for every action with `effect_class ==
  :irreversible_external`, `AutoApprove == false` under *every* generated
  lineage, oracle verdict, and calibration state. Generator MUST include: a
  trusted-lineage + unanimous-clear-oracle + fully-calibrated-confident case that
  *still* escalates (otherwise the property is vacuous: meta-inv 5).
- **P-Y2 (taint gate, §4.4/5):** no action with a tainted arg-lineage is ever
  `OracleCleared`, because no probe over tainted context emits a `:trusted`
  verdict (dual-check: fold the journal's `verdict.trust` against the speculation's
  context taint; they agree). Oracle independence (meta-inv 6): the verdict-trust
  is recomputed from raw `refs`, not read from the Runner's in-memory value.
- **P-Y3 (rollback completeness):** for any rolled-back speculation `b`, the main
  workspace + main journal fold are byte-for-byte identical to pre-fork
  (checkpoint restore, P-JS4 reused); the spend reserve is fully refunded; no
  event on `b` appears in main's fold. Generator MUST include a speculation that
  *did* stage writes and spend before rolling back (vacuous otherwise).
- **P-Y4 (oracle-can-only-mis-clear-recoverable, §4.5):** under an *adversarial
  oracle stub that clears everything*, every committed action is still
  `Reversible ∨ Contained`: the fooled-oracle blast radius is bounded by
  construction. This is the theorem stated as a property: inject a
  yes-to-everything oracle and assert no irreversible external effect committed.
- **P-Y5 (progressive autonomy floor):** no sequence of clean outcomes ever moves
  an `:irreversible_external` class from escalate to auto (U18 cannot cross the
  §7 floor).

### Negative contour

| # | violation | required failure | dead injector (negative control) |
|---|---|---|---|
| N-Y1 | an `:irreversible_external` action auto-approved because lineage was trusted | P-Y1 fails; the gate must have escalated | gate that lets `TrustedLineage` satisfy the disjunction *without* the `¬AlwaysEscalate` guard → green-on-broken → suite fails |
| N-Y2 | a tainted action oracle-cleared (T2/T5) | P-Y2 fails naming the `{verdict_id, tainted_ref_id}` pair | Runner variant honoring a probe-drafted `:trusted` on tainted context (the N-U12.6 injector, reused here) |
| N-Y3 | rolled-back speculation leaves a staged write or an un-refunded reserve | P-Y3 fails: main fold diverges / ledger shows a phantom charge | rollback path that drops the branch marker but not the VFS overlay |
| N-Y4 | oracle disagreement/timeout treated as clear | commit occurs on non-unanimous verdict | quorum fold that defaults missing/timeout verdicts to clear (fail-open) instead of rollback |
| N-Y5 | `effect_class` self-reported by an (untrusted) MCP tool overrides the compiled classification | a tool declaring itself `:reversible_local` gets auto-approved for an irreversible op | gate reading tool-self-reported `effect_class` instead of the compiled-in-tree registry (the tool-poisoning / `destructiveHint`-is-a-lie class) |
| N-Y6 | calibration unlocks the always-escalate floor after N clean runs | P-Y5 fails | U18 client without the §7 floor guard |
| N-Y7 | egress action auto-approved under tainted lineage (lethal trifecta completes) | tainted + egress must escalate; auto-approve is the breakage | predicate with clause 2's `¬Egress` conjunct deleted |

Every fault site carries a fired-counter (meta-inv 1); a dead injector = green
lies. Negative controls run as the periodic CI mutation job (meta-inv 4).

---

## 10. Open questions for human ruling

1. **Q1 (C1, load-bearing):** Freeze the optional `branch_id` field in JS-FREEZE
   now (recommended) and implement v1 speculation as separate-session
   copy-on-fork? Or commit to in-journal branches (Option B) from the start and
   author the tip reds against a 1-arity `tip(journal, branch)`? The field is
   near-free to reserve; not reserving it and needing it later is a breaking
   change to a locked contract.
2. **Q2 (C2):** Ratify the `speculation` meta type shape (single type + status
   enum vs three types) before the auto-approvability reds. Proposed:
   `speculation{branch, phase, action_ref, outcome, refs}`.
3. **Q3 (C3):** Where does `effect_class` + `egress` live: extend F2's
   `Raxol.Action`, or a parallel compiled tool-metadata registry? And ratify the
   enum: `:reversible_local | :bounded_sandboxable | :irreversible_external`.
4. **Q4 (taint entry: trust root a):** Ratify the default taint-entry policy:
   *every external tool result is `:tainted` until a compiled allowlist says
   otherwise.* This is the single most safety-load-bearing policy knob.
5. **Q5 (oracle quorum):** Is unanimous-clear-for-any-write the right default, or
   too conservative (throughput cost)? Where exactly does the read-only/majority
   boundary sit?
6. **Q6 (the Port sandbox gap: trust root c):** clause 2 (`Contained`) is only
   as strong as the kernel sandbox on the shell `Port`. The BEAM-stops-at-the-VM
   gap is already named (`07-permissioning.md`); YOLO-safe *depends* on it being
   closed (Seatbelt/Landlock+seccomp+bubblewrap around the `Shell` Port). Is that
   in scope as a YOLO-safe prerequisite, or tracked separately? Without it,
   `Contained` is aspirational.
7. **Q7 (setpoints):** per-tool-class human setpoint for U18: a config surface,
   or learned from early-session human decisions?

---

## Appendix: prior-art map (mechanism → our substrate → gap)

| Prior-art pattern | What it gives | Our frozen unit | Gap |
|---|---|---|---|
| **OCC** (Kung & Robinson 1981): validate-then-commit | the commit-gate skeleton | journal + checkpoint + replay | branch isolation (C1) |
| **DB txn / STM**: BEGIN/COMMIT/ROLLBACK | atomic all-or-nothing | checkpoint restore (P-JS4) | commit/rollback event (C2) |
| **Sagas / compensating txns** (Garcia-Molina & Salem 1987) | undo for the un-rollbackable |  -  | irreversible-external *has no compensator* → §7 always-escalate (this is the honest answer: sagas can't compensate a sent email) |
| **git branch / event-sourcing** | cheap fork + replay-onto-main | content-addressed journal | `branch_id` (C1) |
| **ocap / POLA** (Miller, *Robust Composition* 2006; seL4 formally verified; Fuchsia capability routing) | authority by unforgeable token, not per-action ask; kills the confused deputy (Hardy 1988). Polaris (CACM 2006) shipped the exact thesis: capabilities "give so much protection there is **no need to pop up security dialog boxes**": capabilities *replace* the approval prompt | `effect_class` as compiled capability; Authorization.Engine `:once/:session/:root` scoped grants | classification field (C3); over-*authority* is structurally impossible but over-*irreversibility* still needs §7 |
| **seccomp / Landlock / bubblewrap / Seatbelt / WASI** | kernel-enforced blast bound | U8 gate is the *seam*; sandbox is TODO on the Port | the Port sandbox gap (Q6) |
| **Lethal trifecta** (Willison 2025) | the exfil boundary to draw | U11 taint (untrusted leg) + `egress` (exfil leg) + §7 (irreversible leg) | drawn mechanically in §2/§5 |
| **CaMeL** (DeepMind 2025) / **dual-LLM** (Willison) | dataflow/capability tracking; quarantined vs privileged | U11 taint algebra + U12 probe isolation (probes never hold tools) |: (structurally present: probes are the quarantined readers, the loop is privileged) |
| **LLM-as-judge / self-consistency / debate** | the oracle | U12 probe-consensus, U17 cross-family | correlated-error risk → §4.2 diversity + §4.5 theorem bound it |
| **Huang 2023 / Stechly-Kambhampati / COMPASS** (the skeptic case) | *proof* LLM self-verification is unreliable adversarially |  -  | drives the design: oracle never sole containment for irreversible (§4.5); deterministic rules lens holds veto (§4.2) |
| **Anthropic classifier + ambient sandbox** (−84% prompts) | the field's validated fix: replace prompts with structure | this whole doc |  -  |
