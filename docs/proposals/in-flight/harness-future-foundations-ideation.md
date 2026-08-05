# Harness Future Foundations: ideation pass over the NEXT reservation tier

Date: 2026-07-16 · Status: **ideation / hypothesis for human ruling**: third
pass of the "reserve before the fixtures lock" method that already caught
thread-branching (`branch_id` + per-branch tip), YOLO-safe (`effect_class` +
`speculation`), and the storage set (`$blob`, GC low-watermark, G1-G6).
Sources: `harness-freeze-contracts.md` (JS-FREEZE §0-4, U11, U12),
`harness-storage-foundations.md` (G1-G6, §4 shape law, item table),
`harness-yolo-safe-research.md` (§3 branch model, §8 C1-C3),
`harness-roadmap.md` (U0-U22, NC guards), corpus sweep of
`../archive/harness-research/{01,03,05,06,07,08,09,12,13}.md`, `harness-design.md`,
`harness-synthesis.md`, `harness-facts-two-perspectives.md`, `tui-steal-list.md`,
plus main-repo capabilities (swarm/CRDT, time-travel, recording, gateway
handoff, ADR-0012 MCP-as-surface).

**This is not a feature roadmap.** Every candidate below is a feature we are
NOT building now; the only question per candidate is whether a brutally cheap
reservation (a list-vs-scalar, an optional field, a reserved kind string, a
predicate arity, a one-sentence law) must land before the red suites and golden
fixtures petrify the contracts.

---

## 0. Method + verdict key

Test per candidate, same as `harness-storage-foundations.md` §0: *if this
feature arrives in month 6, does adding it (a) violate the governing rule
(no rename/repurpose/type-narrow/optional→required), (b) silently change what
locked reds assert (tip law, offset law, golden fixtures), or (c) require
rewriting on-disk history?* Any yes ⇒ reserve now. One softer
test this pass surfaced: **(d) does deferring it lose data that cannot be
backfilled**: a journal that didn't record a fact can never learn it
retroactively; that's not a contract break but it is an irreversible loss.

Verdicts:

- **RESERVE-NOW**: reservation is cheap AND retrofit is a rewrite (or
  unbackfillable data loss). Goes to the consolidated changelist (§5).
- **COMPOSES-FREE**: the feature falls out of the existing freeze; naming the
  composition here IS the deliverable (so the deferral is a decision, not an
  omission, and so nobody "helpfully" adds redundant machinery later).
- **SKIP**: not worth even the reservation; reasons given.

The discipline check applied throughout: if the reservation is more than a
field/kind/arity/sentence, it's not a foundation, it's the feature: it goes to
the roadmap, not the freeze. Several candidates below were demoted on exactly
this test.

**A meta-observation worth recording:** most of the *highest-demand* corpus
features (cross-device attach, permission memory, cost attribution, structured
checkpoints) came back COMPOSES-FREE: the frozen substrate already absorbs
them. That is independent evidence the freeze + today's three catches were
shaped right. The residue below is small and mostly lineage-shaped.

---

## 1. The economics frame (why the payoff class is what it is)

Restating the unifying law from the seed, because it ranks everything:

- **Cache-riding** (U12 byte-identical prefix, P-U12.3) makes *token-side*
  speculation nearly free: N requests over one prefix cost incremental
  completion tokens, not N contexts. Manus: KV-cache stability is "the single
  most important metric" (`05-protocols.md`).
- **Branching** (`branch_id`, per-branch tip, `speculation` meta type) makes
  *journal-side* speculation nearly free: a branch that loses is dropped
  without polluting main's fold.

Features that compose BOTH are the payoff class: **tournament turns** (N
speculative branches ride one prefix; a probe quorum picks the winner),
**counterfactual replay** (fork at offset, re-run under different
model/params), **YOLO speculation** (already caught). The audit below confirms
the payoff class needs **zero further freeze surface** beyond today's catches
plus one wording fix to C2 (§3.6): the two cheap primitives really do span it.

---

## 2. Verdict table (the whole candidate space at a glance)

| # | Candidate | Verdict | One-line reason |
|---|---|---|---|
| F1 | Session lineage as **list of typed edges** (`parents`) | **RESERVE-NOW (R1)** | scalar `forked_from` petrifies under repurpose-forbidden; fuse/spawn/import all need list |
| F2 | Fuse/merge threads (seed 2) | RESERVE-NOW via R1 + R6 wording | merge = second parent edge; journal-side DAG falls out of `refs` being a list |
| F3 | Sub-agent spawn with provenance | RESERVE-NOW via R1 | strongest-demand lineage consumer; storage-doc item 19 / Q5 already pending |
| F4 | Session transplant / export / import | **RESERVE-NOW (R2)**: one-sentence self-containment law | absolute/external refs, once in fixtures, are forever |
| F5 | Partial-journal sharing / post-hoc redaction | **RESERVE-NOW (R3)**: `$redacted` marker + one-legal-rewrite law | same value-repurpose class as `$blob`; append-only law otherwise forbids the only honest fix |
| F6 | Model-migration / counterfactual replay | **RESERVE-NOW (R4)**, per-turn override journaling law | test (d): unrecorded per-turn params are unbackfillable; contract side composes |
| F7 | Live multi-user sessions | **RESERVE-NOW (R5)**: optional `actor` on G4/G5 shapes | G4/G5 are being shaped this week; a decided-by-whom slot is free now, a fixture re-author later |
| F8 | Tournament turns (seed 4) | COMPOSES-FREE (+ R6 wording on C2) | branch_id + speculation + verdict + charge already span it |
| F9 | Background/trigger-woken worker (seed 1) | COMPOSES-FREE | provenance source registry + writerless reattach + AD-14 TimedOut already cover it |
| F10 | Memory/journal as MCP resources (seed 3) | COMPOSES-FREE (with a direction caution) | read-only derived projection; MCP 2026 is shedding state, never relocate truth into it |
| F11 | Cross-device live session | COMPOSES-FREE | AD-15 `attach{historyPolicy}` + SS registry are the fix for Codex #25676; offline divergence = fork+merge (R1) |
| F12 | Learned tool-policies as durable records | COMPOSES-FREE | G4 `approval_decided{amendment}` + frozen `calibrate` are exactly this |
| F13 | Billing/attribution per record | COMPOSES-FREE (subtree rollup rides R1) | charge shape frozen grow-only; turn_completed carries cost |
| F14 | User annotations on history | COMPOSES-FREE | future meta type; `refs` list already points at annotated offsets |
| F15 | Journal→training-data export | COMPOSES-FREE | pure projection; taint/provenance/effect_class are the labels it needs, all frozen |
| F16 | Semantic search / embedding sidecars | SKIP | derived-and-disposable by NC-6; zero contract surface; no corpus demand |
| F17 | Multi-writer CRDT journal (swarm) | SKIP | would break the single-writer/offset laws; fork+merge (R1) is the same feature without the break |
| F18 | Hash-chain / signed journal | SKIP (crc name already reserved) | additive optional field later; verification-from-a-point needs no day-one shape |

---

## 3. RESERVE-NOW candidates in detail

### 3.1 R1: Session lineage is a LIST of typed edges (never a scalar)

**(a) Feature(s).** Everything that gives a session more than zero or one
parent: fuse/merge two threads (seed 2), sub-agent spawning with provenance,
cross-device offline convergence, counterfactual forks, transplant origin
tracking, per-subtree cost rollup.

**(b) Evidence.**
- Sub-agent provenance is the strongest-attested lineage consumer: Codex ships
  `SubAgentActivity` / `CollabAgentToolCall` as first-class stream items
  (`13-command-channels.md` §1); opencode sessions form a tree with
  `GET /session/:id/children` (§3); OpenAI Agents SDK handoffs "don't hand back
  up" = lost call-tree provenance (`03-framework-libs.md` #1197); Codex built
  `rollout_trace` because multi-agent relationships lived in "transient
  in-memory manager state" (`10-storage-leaders.md` §2, via storage item 19).
  U8's `:root` approval scope already "remembers across an entire spawn tree"
  (`07-permissioning.md`): the spawn tree exists in the authz layer with no
  durable counterpart. #68619's 4M-tokens-in-5-min recursive spawn makes
  per-subtree budget attribution a demand, and rollup needs the edges.
- Merge/fuse itself has **no direct corpus demand** (both sweep passes agree:
  absent, neither requested nor rejected; forks everywhere, Amp ships
  "git-branch-style threads" (`harness-facts-two-perspectives.md` §Addendum): 
  merges nowhere). It is a project-owner hypothesis. But it costs nothing
  extra once the field is a list, which is the point.
- The retrofit horror for lineage-shape mistakes is already documented:
  OpenHands #4057, flat-log→parent-pointer migration silently orphaned 5,566 of
  5,731 events (`11-storage-challengers.md` §1).

**(c) Minimal reservation.** Whichever home wins storage-doc Q5 (meta.json
field vs. spawn meta event vs. both), the SHAPE is frozen now as:

```
parents: [ %{session_id, offset, relation} ]     # list, possibly empty
relation ∈ :fork | :spawn | :merge | :import      # grow-only enum
```

One list, typed edges, grow-only relation vocabulary. `:fork` is G2 Option A's
`forked_from` (copy-on-fork); `:spawn` is Agent.Team sub-agent linkage;
`:merge` is fuse (two+ edges); `:import` is transplant provenance (F4). The
reservation is deliberately home-agnostic: it constrains Q5's answer, it does
not preempt it.

**(d) Retrofit cost if scalar.** `forked_from: %{session_id, offset}` (the
literal shape currently written in storage-foundations G2 Option A) freezes as
a scalar the day fork fixtures land. Scalar→list is a type change = forbidden
repurpose (JS-FREEZE §0). The workaround forever after is a *second* parallel
field (`merged_from`, `spawned_by`, …) per relation, every reader
special-casing N fields that mean one thing: the dual-id landmine's
genealogy-shaped cousin.

**(e) Verdict: RESERVE-NOW.** Highest rank: retrofit = forbidden repurpose;
probability ≈ certain, because `:spawn` alone is near-term (Agent.Team exists
in the main repo today and storage Q5 explicitly says "decide before
Agent.Team sessions write journals").

**Seed-2 hypothesis, verified:** *"parents must be a list (DAG) not scalar"*: 
**confirmed at the session level** (above), and **dissolved at the journal
level**: in-journal, the frozen `refs` payload key is already
`[non_neg_integer()]`, so a branch-genesis record naming two parent tips is
representable today with zero new shape (see R6). Critically, **the tip law
survives merge untouched**: `tip(journal, branch)` selects the highest
conversational offset *per branch*: parents affect **folds** (history
reconstruction), never **tips** (resume points). A merge creates a new
branch/session whose genesis names two parents; no tip predicate ever needs
multi-parent awareness. The Dormammu fixtures stay valid verbatim.

### 3.2 R2: The self-containment (portability) law

**(a) Feature(s).** Session transplant: `tar` a session directory, import on
another machine/instance, and it reads healthy, enabling export/import,
backup/restore, audit hand-off, and the "audit-trail interchange" empty
category.

**(b) Evidence.** `05-protocols.md`: session/transcript format is
CATEGORY-EMPTY across the cohort ("No interchange") and checkpoint format
likewise; the empty seam is explicitly named a moat. `07-permissioning.md`
category-empty #2: no OTel-equivalent for "what did the agent do": a portable
session IS that artifact. U4 already requires reattach to work against "a
`tar`'d directory" (JS-FREEZE §1.1, attach rejection rationale): the freeze
*assumes* portability in one sentence without stating the law that makes it
true. `12-state-frameworks.md` §5.4: JSONL-per-session converged across the
cohort precisely because it's portable; §2.3 claim-check externalization is
what keeps exports from dragging a database along.

**(c) Minimal reservation.** One frozen sentence in JS-FREEZE §0 (a corollary
of the storage §4 shape law, if that is adopted):

> **The session directory is the unit of portability.** Every reference a
> record carries resolves inside its own session directory (journal offsets,
> relative CAS paths `snapshots/<sha>`, `blobs/<sha>`) (never an absolute
> path, never another session's interior) except lineage edges (R1), which
> are the sole cross-session pointers and are resolvable-or-absent: a reader
> with a missing parent still reads THIS journal healthy (fold-complete under
> G2 Option A copy-on-fork; lineage is provenance, not replay input).

**(d) Retrofit cost if missed.** Not a schema rewrite: worse in a quieter
way: nothing today *stops* a producer journaling an absolute path or a
cross-session interior pointer, and the moment one ships inside a golden
fixture it is grandfathered forever (fixtures are byte-locked; the I9 corpus
never shrinks). Post-hoc portability then means a rewriting exporter, exactly
the derived-artifact-drift class the storage doc's horror list is made of.
Cost now: one sentence + one lint-grade red (scan fixtures for absolute
paths).

**(e) Verdict: RESERVE-NOW.** Rank 2: probability high (export/import is the
cohort's named empty category and our own U4 already assumes tar-ability),
reservation is one sentence.

### 3.3 R3: `$redacted` marker + the one-legal-rewrite law

**(a) Feature.** Post-hoc redaction: scrub a secret/PII value from an existing
journal (compliance deletion, incident response, sharing a session with a
value removed) while the journal stays readable-as-healthy.

**(b) Evidence.** FI-10 redaction is **write-boundary only**, and write-time
redaction demonstrably misses: OpenHands PR #9793 shipped a redactor that
corrupted timestamps (`11-storage-challengers.md` §1); Codex #21660
world-readable transcripts and grok GCS exfiltration establish that journals
DO end up holding what they shouldn't. Claude #62041 ("these transcripts ARE
the work product") cuts the other way: you cannot fix a leak by deleting the
session. Sharing demand is real if unnamed: users already do forensic
log-sharing "on logs Anthropic didn't design for it" (`01-leaders.md` #2073);
ACP PR #533's `historyPolicy: full|pending_only|none` is redaction-adjacent
filtering at the attach seam (`13-command-channels.md` §2). Corpus demand for
*redacted sharing specifically* is weak (both sweeps: absent): this
reservation is carried by the compliance/incident case, not the collaboration
case.

**(c) Minimal reservation.** Two clauses, same style as G1's `$blob`:
1. Registered value marker, grow-only, never repurposed:
   `%{"$redacted" => true, "reason" => "...", "hash" => sha256-of-removed-bytes | nil}`:
a payload value MAY be this marker; readers render it as an opaque
   redaction tombstone; folds treat it as an ordinary value. One clause in the
   JS-FREEZE §1.1 reader-tolerance list, alongside `$blob`.
2. The **one-legal-rewrite law**: append-only admits exactly one in-place
   mutation class, replacing a payload *value* with the `$redacted` marker
   (record framing, `id`, `kind`, envelope fields untouched), attested by an
   appended `kind:"event"`, `family:"meta"` redaction event naming the
   offsets. For the CAS side it is already free: deleting a blob/snapshot file
   leaves a dangling ref, and N-JS3's semantics (checkpoint-level damage ≠
   journal damage, nothing deleted implicitly) generalize verbatim to
   `$blob`: deref-fails ⇒ tombstone, journal stays `:ok`.

**(d) Retrofit cost if missed.** Two independent rewrites: (i) an inline value
changing meaning later is the exact `$blob` repurpose class, a v1 reader
renders a v2 tombstone as literal content, folds diverge; (ii) without the
one-legal-rewrite carve-out, the append-only law + I5/I6 byte-discipline reds
make ANY scrub read as interior corruption, the only compliant "redaction"
would be deleting the session (#62041, the horror we're avoiding) or a
full-journal rewriting export that breaks every offset-based reference to it.

**(e) Verdict: RESERVE-NOW.** Rank 3: probability medium-high (secrets landing
in journals is an evidenced certainty; a deletion demand eventually following
is close to one), reservation is a marker + a sentence. The *sharing UX* built
on top is a feature and stays unbuilt.

### 3.4 R4: Per-turn parameter overrides are journaled (the replay-fidelity law)

**(a) Feature(s).** Model-migration replay (replay old journal on new model,
diff behavior) and counterfactual replay (fork at offset, re-run with
different model/effort/policy), both need to know, per turn, what actually
produced the history.

**(b) Evidence.** Codex `turn/start` re-negotiates `model`, `effort`,
`sandbox_policy`, `approval_policy` **per turn**, not per session
(`13-command-channels.md` §1), per-turn override is cohort-normal, and our
FI-2 version tag lives on the **log head** only, which is truthful precisely
until the first per-turn override ships. `01-leaders.md` rec #5: version-tag
every transcript with harness+model+config hash and diff behavior across
ranges: driven by #2073 (model regressions misattributed to the harness,
users doing forensics). `09-eval-science.md` steal-list #3: deterministic
replay / golden-trace fixtures; law #11's cross-harness replays are exactly
this workflow. The frozen `gate_decision.seed` (replayable dice) shows the
freeze already believes in replay-fidelity: this extends the same principle
from dice to provider params.

**(c) Minimal reservation.** One sentence, not a field:

> **Any per-turn override of a head-tagged parameter (model, effort,
> sandbox/approval policy, provider) MUST be journaled in that turn's
> `turn_started.payload`** (optional keys, absent = head values apply). The
> head tag (FI-2) states session defaults; the journal states deviations.

No key names frozen yet: payload keys are additive by rule; what's reserved
is the *obligation*, so the first override implementation can't ship it as
process-local state.

**(d) Retrofit cost if missed.** Test (d), the quiet one: contracts would
absorb the keys later just fine, but every journal written between "overrides
exist" and "overrides are journaled" is **permanently unattributable**: 
behavior-diff and counterfactual-fork tooling silently lies about that era's
history. Unbackfillable data loss, the same reason `gate_decision.seed` was
frozen day one rather than added when replay shipped.

**(e) Verdict: RESERVE-NOW.** Rank 4 (a law, zero schema surface). Note this
also strengthens storage-foundations OQ4 (provider-wire fidelity): rule OQ4
and R4 together. They are two halves of "the journal is sufficient to
reproduce the request."

**Scope boundary, stated so nobody over-promises:** counterfactual replay is
always a *fresh fork re-run*: it never undoes and never re-executes the
original run's external effects. `tui-steal-list.md` §4's cut table already
names this precisely ("the inverse of 'paid $0.40 via Xochi' is not a model
rewind: different subsystem"); the frozen `effect_class` + always-escalate
set is what keeps a re-run from silently re-firing an irreversible effect,
and effect-undo/compensation stays out of scope for this reservation tier
entirely (the saga literature's answer, per yolo-safe §7: some effects have
no compensator).

### 3.5 R5: `actor` slot on the shapes being ratified this week (G4/G5)

**(a) Feature(s).** Live multi-user sessions (two humans, one session);
housekeeping/harness-initiated action audit; any future "who decided/asked"
attribution.

**(b) Evidence.** Multi-client is shipping cohort-wide (opencode "terminal
tab, phone, desktop, browser, fully synced"; ACP PR #533 broadcast-all
attach; `13-command-channels.md` §3/§D names multi-client "raxol's cheapest
differentiator"), and the moment two clients attach, `approval_decided`
without an actor is ambiguous audit. `08-user-voice.md` #75275: an 800GB
deletion "appears in no session transcript, no permission prompt": the
harness itself is an actor whose decisions need attribution (rec #5:
housekeeping needs the same audit gating). OQ-U11.2 already ruled per-surface
provenance atoms for exactly this fidelity reason: commands deserve the
symmetric treatment.

**(c) Minimal reservation.** Two optional-with-default keys, added while G4/G5
are still wet clay (they are being shaped in `harness-storage-foundations.md`
right now, pre-red):
- G4 `approval_decided` payload grows optional `actor` (default: the session
  owner): an opaque string/atom; the identity *model* behind it is a later
  feature.
- G5 `client_msg_id` semantics gain the sibling optional `actor` on
  `prompt`/`steer` commands, mirrored onto `turn_started.payload` beside
  `client_msg_id`.

**(d) Retrofit cost if missed.** Lowest of the five: optional payload keys
are additive later (rank-5 "suite re-authoring only" class: U8 approval
fixtures and the S2 command-seam reds would be re-cut). It makes this list
anyway because the marginal cost is zero *this week specifically*: G4/G5 are
being ratified now, and a shape ratified without the slot invites the
"decided-by is implicit = the one attached user" assumption to harden into
gate logic, which is a behavior change to unwind, not just a fixture re-cut.

**(e) Verdict: RESERVE-NOW** (timing-bound; demote to COMPOSES-FREE if G4/G5
ratification has already passed by the time this is ruled).

### 3.6 R6: One wording fix to C2: branch genesis uses plural `refs`

Not a new reservation: a sentence to include in the C2 (`speculation` meta
type) ratification that yolo-safe Q2 already queues:

> At `phase: :begin`, `refs` names the parent tip offset(s) the branch roots
> from: **plural-capable by construction** (`refs` is a frozen list).

That single sentence is what makes in-journal merge (`:merge` phase value
later: enum is grow-only) and in-journal tournament brackets representable
with zero future shape change. If C2 is instead ratified with prose saying
"refs names THE fork point" (singular), a semantic singular-plural constraint
gets baked into red assertions and the DAG dies in the fixtures despite the
type being a list. Cost: one word. This is the journal-level half of the
seed-2 verification (§3.1).

---

## 4. COMPOSES-FREE: the deferrals that are decisions

Each entry: the feature, and the exact frozen machinery that absorbs it. These
paragraphs exist so no one bolts on redundant machinery later.

**F8: Tournament turns (the payoff class).** N speculative branches at one
tip: all N ride the primary's byte-identical prefix (P-U12.3, near-free
tokens); each is a `speculation{branch: bᵢ, phase: :begin}` (near-free
journal); probes emit `verdict` events per branch; the quorum fold picks a
winner; winner commits (`phase: :commit`), losers roll back; per-branch cost
is visible in the frozen `charge` split (cached vs uncached, the dividend is
*observable*, not just real). Sibling correlation (which branches were one
tournament) = an optional `group` key on `speculation` payload: additive
whenever tournaments ship. **Zero new freeze surface.** This is the
composition test passing on today's three catches: the two cheap primitives
(prefix-riding, branch isolation) really do span the ambitious feature.

**F9: Background/trigger-woken worker (seed 1).** The corpus warns the
demand is inverted: parallel/background agents are builder-supply-driven; the
*unmet* user need is death/liveness honesty (Claude bg agents "34+hr
uncancellable, misreport own status", `01-leaders.md`; "no signal the agents
died" #63023, `08-user-voice.md`). The freeze already holds every piece:
sessions are writerless-readable and reattachable (U4, a session with no
BEAM is *normal*, not a special state); a trigger-woken turn is a `prompt`
whose provenance source is a new grow-only atom (`:surface_cron`,
`:surface_webhook`, OQ-U11.2's per-surface ruling anticipated this);
liveness truth is `Process.alive?` + turn brackets, never model self-report
(U5's whole thesis); an approval raised with no human attached resolves by
AD-14 `TimedOut`-is-first-class + YOLO-safe's predicate for everything
recoverable. A durable "wake me at X" intent, if ever wanted, is a new meta
type: registry is grow-only. The scheduler itself is derived state (reads
journals/meta for due wakes): NC-6 disposable-index discipline. **Nothing to
reserve.**

**F10: Memory/journal as MCP resources (seed 3).** Composes as a *read-only
derived projection*: journal offsets and session ids are stable addresses;
ADR-0012's context-tree resource streaming is the shipping pattern; the
reader-seam tolerance rules mean a resource server at version skew stays
correct. Two cautions, both directional not contractual: (i) MCP 2026 RC is
deleting session/state from the protocol (SEP-2567/2575, sampling deprecated (
`05-protocols.md`)) expose a projection, never relocate truth into the MCP
layer ("you've handed them the durable seat"); (ii) an MCP consumer is an
egress path: the frozen taint/provenance fields ship IN the projection so
consumers can honor the C3 boundary, and serving another agent's journal to a
tainted consumer is a YOLO `Egress` question already answerable by the frozen
predicate. **Nothing to reserve.**

**F11: Cross-device live session.** The exact cohort gap (Codex #25676:
second device spawns a parallel continuation instead of attaching; #14722;
ACP PR #533 exists because native attach doesn't) is already dissolved by
frozen machinery: AD-15 `attach{from_offset, historyPolicy}` IS PR #533's
shape; SS's session→pid registry is what makes "attach, don't re-spawn" the
only possible behavior; broadcast-to-late-joiner replay is P-JS5 replay
closure. Single-writer is preserved: devices are subscribers + command
senders, the one Writer lives with the session. True *offline* divergence
(two devices, no server) is not sync at all. It is fork on each device +
fuse on reconnect, i.e., R1's `:merge` edge; a CRDT journal is explicitly not
the answer (F17). **Nothing to reserve beyond R1.**

**F12: Learned tool-policies as durable records.** G4 already reserves
`approval_decided{amendment}` + amendment-before-enforcement; U18's servo
output is the frozen `calibrate` type; YOLO-safe §6 wires revocation as data
events surviving restart. Policy state = fold. The cohort's whole demand
(Codex `ApprovedExecpolicyAmendment`, ACP `allow_always`, opencode
`remember?`, the 93% rubber-stamp finding) lands inside already-reserved
shapes. **Nothing to reserve.**

**F13: Billing/cost attribution.** Frozen `charge` shape is grow-only
(forward-compat note explicitly names cost-in-currency as an additive key);
U7 puts cost on `turn_completed`; per-record attribution = payload keys
(additive); per-subtree rollup (the #68619 demand) = walk R1 lineage edges.
The corpus's sharpest insight ("cost anxiety and loss-of-control are the
same bug" (`08-user-voice.md`)) is already structural: SpendGate is a
control-plane gate, not post-hoc billing. **Nothing to reserve beyond R1.**

**F14: Human annotations on journal history.** Zero corpus demand (both
sweeps). If wanted: a new meta type `annotation{body, refs}`: registry
grow-only, `refs` already points at arbitrary offsets, meta events are
tip-excluded so a trailing annotation can never become a resume point
(Dormammu holds), and appending to a cold journal just means reopening the
single Writer. The design is *fully determined* by frozen rules, which is
exactly why it needs no reservation.

**F15: Journal→training-data export.** Science-implied (`09-eval-science.md`
law #7: harness shape must be baked in at training time), zero user demand.
It is a pure projection, and every label it would need (taint (don't train
on injected content), provenance source, `effect_class`, verdict/evidence
records) is already frozen or reserved. Consent/licensing is session-level
config, not journal contract. **Nothing to reserve.**

---

## 5. SKIP: not even a reservation

**F16: Semantic search / embedding sidecars.** No corpus demand for search;
strong corpus warning against embeddings near the log (LangGraph duplicating
embedding arrays per node bloated checkpoints: `12-state-frameworks.md`
§1.3). If it ever comes, it is a derived, disposable, rebuildable index: 
NC-6 already *is* the reservation. Adding one would only invite putting
vectors somewhere authoritative.

**F17: Multi-writer / CRDT-merged journal (swarm composition).** The one
"crazy" feature that genuinely CANNOT be reserved cheaply, so the honest move
is to close the door in writing: convergent multi-master editing of one
journal breaks the single-writer name, the dense-offset law, and I5/I6
corruption detection simultaneously. That is not a reservation, that is a
different storage engine. The same user value (work on two devices/nodes,
converge later) is delivered by fork + fuse over R1 edges with a human/oracle
at the merge: Git's answer, not Figma's. Swarm stays "more sessions, not
more writers per log" (storage item 23), NC-2 stays binding. Propose recording
this as **NC-12: no multi-writer journal, ever; divergence converges by
lineage merge**.

**F18: Hash-chain / signed journal (tamper evidence).** Storage item 17
already reserves the `crc` field name. A chain (`prev_hash`) or signature is
an additive optional field whose verification naturally starts mid-log
(verify-from-first-stamped-record); no fixture will ever forbid an unknown
optional field (reader tolerance). Compliance-grade sealing, if demanded, is
an exporter feature. Nothing further to reserve.

---

## 6. Consolidated additive changelist (to `harness-freeze-contracts.md` et al.)

Everything below is optional-with-default / grow-only / one-sentence law: 
verified additive under JS-FREEZE §0.

1. **[R1 → storage-doc Q5, upgrade the question]** Whichever lineage home is
   ruled, the shape is `parents: [%{session_id, offset, relation}]`, `relation`
   grow-only (`:fork | :spawn | :merge | :import`). G2 Option A's prose
   changes `forked_from: %{session_id, offset}` → one `:fork` edge in
   `parents`. Never a scalar lineage field anywhere.
2. **[R2 → JS-FREEZE §0]** The self-containment law (one sentence, §3.2c):
   session dir = unit of portability; intra-session refs only, lineage edges
   the sole cross-session pointers, resolvable-or-absent.
3. **[R3 → JS-FREEZE §1.1 reader tolerance + §0]** Register the `$redacted`
   marker beside `$blob`; add the one-legal-rewrite law (value→tombstone in
   place, attested by an appended redaction meta event); note blob-file
   deletion already degrades safely under N-JS3 semantics extended to `$blob`
   derefs.
4. **[R4 → FI-2 / U1.5 notes]** The replay-fidelity law: any per-turn override
   of a head-tagged parameter is journaled in `turn_started.payload`. Rule
   jointly with storage OQ4 (wire fidelity).
5. **[R5 → G4/G5 shaping, this week]** Optional `actor` on `approval_decided`
   and on `prompt`/`steer` + `turn_started.payload`, default = session owner.
6. **[R6 → C2 ratification (yolo Q2)]** `speculation` at `phase: :begin`:
   "refs names the parent tip offset(s)": plural wording, `:merge` noted as a
   future grow-only phase value.
7. **[NC list]** Add NC-12: no multi-writer journal; divergence converges by
   lineage merge (R1), never CRDT-in-the-log.
8. **[doc hygiene]** Storage-foundations item 19 and its Q5 are superseded by
   R1's shape constraint (the question narrows from "field vs event" to
   "which home for the frozen list-of-edges shape").

Total contract weight: one list-shaped field spec, one marker, four sentences,
two optional keys, one NC entry. Nothing renamed, nothing required, no
existing fixture invalidated.

---

## 7. Open questions for human ruling

1. **R1 relation vocabulary**: is `:fork | :spawn | :merge | :import` the
   right seed set, and does `:spawn` carry an extra key (e.g. `role:
   :subagent | :team_worker`) or stay minimal? (Grow-only either way; this is
   about day-one fixture content.)
2. **R3 scope**: is the one-legal-rewrite law acceptable to the append-only
   purists, or should post-hoc redaction instead be ruled
   "export-a-new-session with `:import` lineage + `$redacted` values, original
   deleted by FI-7 consent"? Both are representable under this changelist: 
   the ruling picks which the tooling blesses. (The second keeps journals
   immutable at the cost of breaking offset-references into the original.)
3. **R5 timing**: have G4/G5 shapes already been ratified/red-authored? If
   yes, R5 demotes to COMPOSES-FREE (additive keys later) and drops from the
   changelist.
4. **F8 tournament `group` key**: reserve the optional `group` key on
   `speculation` now for fixture aesthetics, or leave it additive-later
   (recommended: later. It is genuinely additive, the discipline says don't
   reserve what composes)?
5. **NC-12**: ratify as a named non-commitment, or is anyone still holding a
   candle for CRDT journals in the swarm story? (The fork+fuse answer should
   be argued against the strongest CRDT case before the door closes in a doc
   others will cite.)
6. **Seed-3 direction**: bless "memory-as-MCP = read-only projection, never
   authoritative" as a one-line principle somewhere citable (harness-design?),
   so the MCP 2026 direction caution survives this doc?
