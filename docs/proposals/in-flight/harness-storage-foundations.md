# Harness Storage Foundations: what must be substrate on day one

Date: 2026-07-16 · Status: **hypothesis for human ruling**: an audit of the
full round-2 storage corpus against the freeze contracts, hunting for every
storage-shaping feature that becomes a structural rewrite if added after the
red suites lock. Same catch-class as thread-branching and YOLO-safe: find it
while JS-FREEZE can still absorb it additively.

Sources: `../archive/harness-research/10-storage-leaders.md`, `11-storage-challengers.md`,
`14-beam-storage.md`, `15-storage-horror-formats.md`, `12-state-frameworks.md`,
`13-command-channels.md`, `harness-storage-research.md` (AD-9..15, FI-7..12),
`harness-freeze-contracts.md` (JS-FREEZE, U11, U12), `harness-invariants.md`
(I1-I10), `harness-roadmap.md`, `harness-spec-{protocol,backend}.md`,
`../archive/harness-research/{05,06,07,16}.md`, UI lane scanned for storage demands only.

---

## 0. Method + the one-line verdict

Test applied to every candidate: **"if this arrives in month 6, does adding it
(a) violate the governing rule (no rename/repurpose/type-narrow), (b) silently
change what already-locked reds assert (tip law, density law, golden fixtures),
or (c) require rewriting on-disk history?"** Any yes ⇒ day-one foundation.
Everything else bolts on under additive-only evolution and is *listed as such*
so its deferral is a decision, not an omission.

**Verdict:** the frozen substrate is genuinely strong: the offset law, in-log
pointer records, tolerant reader, upcast-on-read, single writer, and FI-7..12
cover ~70% of the cohort's failure classes at the contract layer. The audit
found **six day-one gaps**, of which two (payload externalization; durable
rewind/branch semantics vs. the frozen linear tip law) are the same severity
class as the dual-id landmine: syntactically "additive later," semantically a
repurpose that breaks every deployed reader.

---

## 1. The foundational set (ranked) + classification

Rank = retrofit cost × evidence strength. Classification key:
**FROZEN** (already in JS-FREEZE/U11/U12/I1-I10, cite), **GAP** (foundational,
not yet frozen, §3 owns these), **BOLT-ON** (safely additive later: justify).

| # | Feature | Class | Where frozen / why gap / why safe |
|---|---|---|---|
| 1 | **Append-only framed JSONL, single-writer, torn-tail truncate / interior alarm** | FROZEN | AD-9, I5/I6/I7, N-JS6. Cohort ×4 convergent + Gemini's 9,000× JSON-rewrite natural experiment (10 §3); Ra/RabbitMQ from the BEAM side (14 §5). |
| 2 | **One offset space, journal owns id, dense record ids** | FROZEN | JS-FREEZE offset law, I1. Kills the dual-id class (roadmap §3.1). |
| 3 | **In-log pointer records (checkpoint=compaction), sidecar never holds state** | FROZEN | AD-10, JS-FREEZE §1.1, I8. All four leaders independently reinvented it (10 §E.3); OpenHands PR #5946 proves log-authority (11 §1). |
| 4 | **Schema SemVer + upcast-on-read + grandfather corpus** | FROZEN | AD-11, I9, P-JS7/P-U11.2. The cohort's universally-demanded, never-shipped item (#53516; Codex #23001 one-new-required-field crash). |
| 5 | **Secret redaction at write boundary; no content telemetry** | FROZEN | FI-10, JS-FREEZE §1.1-FI-10. grok GCS exfiltration + Lovable BOLA (10 §4, 15 §1.4). One implementation caveat carried to reds: redaction must be field-scoped, never substring-global: OpenHands PR #9793 corrupted timestamps redacting naively (11 §1). |
| 6 | **Taint/provenance in the record, absorbing lattice, `refs` audit chain** | FROZEN | U11-CONTRACT §2 whole. FI-5. |
| 7 | **Retention/GC = explicit consent, no silent delete, `gc` kind reserved** | FROZEN (semantics) / **GAP** (representability: see G3) | FI-7, I6, OQ-JS2. The #1 horror class (#62041 ~2,300 transcripts) is covered; what's NOT covered is whether a GC'd journal is *readable as healthy* afterward. |
| 8 | **Disk-full / size behavior defined, no cascade** | FROZEN | FI-11. Claude Code #24207 ENOSPC→auth-wipe cascade (15 §1.5). |
| 9 | **Checkpoint snapshots content-addressed + out-of-line** | FROZEN | JS-FREEZE §1.1 checkpoint record. |
| 10 | **Tip = derived predicate, Dormammu-proof** | FROZEN, but see G2 | FI-12, P-JS2/3, N-JS5. Frozen **linear**: "highest conversational offset." |
| 11 | **Large-payload externalization (claim-check / blob CAS) for event payloads** | **GAP: G1** | Nothing in the freeze bounds a record or externalizes a payload. Top-severity evidence (§3.G1). |
| 12 | **Durable rewind / branch / fork semantics** | **GAP: G2** | `seek` is in the frozen command vocabulary (protocol §4) but no record kind makes a rewind durable; tip law is definitionally linear. |
| 13 | **GC low-watermark (prefix truncation representable as healthy)** | **GAP: G3** | The reserved `gc` kind without a watermark rule leaves every I5/I6 red asserting "segments start at 1 or damaged." |
| 14 | **Approval decisions + policy amendments as durable records** | **GAP: G4** | AD-14 decisions carry policy amendments; no journaled event type exists for the decision or the amended rule. |
| 15 | **Command idempotency key (`client_msg_id`)** | **GAP: G5** | Codex `client_user_message_id`; idempotent-consumer rule "key at write time, never offset-derived" (12 §3.4). Mobile reattach (S2) retries prompts over a flaky wire. |
| 16 | **File modes / on-disk permissions (0600/0700)** | **GAP: G6** (tiny) | Codex #21660: world-readable rollouts, correct 0600 pattern existed elsewhere and was never applied. One line in the Writer, but must precede fixtures. |
| 17 | **Per-record integrity field (crc/hash)** | BOLT-ON (reserve name) | JSON-parse-failure is the frozen torn-write detector (14 §B); interior *silent* corruption (valid-JSON bit flip: the LangGraph poisoning class, FI-9) is real but an optional Writer-stamped `"crc"` field is purely additive: readers tolerate unknown fields, old records grandfather. Reserve the field name now; ship later. |
| 18 | **Cross-session refs / global promote store** | BOLT-ON (by ruling) | OQ-U11.1 permanently forbids in-journal cross-session refs; the global store derives from durable `promote` events, so its schema can be designed at U20 with zero journal change. |
| 19 | **Sub-agent session linkage (parent session pointer)** | BOLT-ON (name it now, cheap) | Codex built `rollout_trace` because multi-agent relationships lived in "transient in-memory manager state" (10 §2). An `attach`-class meta event / `meta.json` field `parent_session` is additive; the `refs`-scoping ruling doesn't block it (it's a session-level pointer, not an event ref). Decide the field name before S2/Team wiring; no schema break either way. |
| 20 | **Workspace/file-state checkpointing (shadow store)** | BOLT-ON (named non-commitment) | Cohort verdict: keep conversation replay and workspace-undo decoupled (11 §C: Cline's coupled shadow-git = the biggest bloat + blast-radius source; OpenHands' separation is the clean pole). A future store is a sibling content-addressed dir referenced by events: additive field. Name the non-commitment so U8's "backups before destructive action" (06 §B.9) doesn't sneak it in coupled. |
| 21 | **Derived index (SQLite or other)** | BOLT-ON (by NC-6) | Derived + disposable, rebuildable by scan (14 §D). Never primary. |
| 22 | **Encryption-at-rest** | BOLT-ON (with a named trigger) | Format-level encryption contradicts the frozen grep-ability value (14 §B); FS-level is outside the format. Prior synthesis already flags: security pass **before any cloud-sync/multi-machine feature** (harness-storage-research.md meta-review). G6's 0600 is the day-one floor. |
| 23 | **Multi-writer / swarm / cross-machine sync** | BOLT-ON (by scoping) | Single-writer is per-session; swarm = more sessions, not more writers per log. Deliberately out of round 2; revisit with mobile (harness-storage-research.md meta-review). The offset law needs no change. |
| 24 | **Time/clock model** | BOLT-ON | Ordering authority is the offset, never `ts` (offset law); `ts` is advisory. A monotonic-clock companion field is additive. Reds asserting ts-monotonicity must allow a documented skew bound (grok-45 #37) or they'll lock wall-clock behavior. |
| 25 | **Human-readable export** | BOLT-ON | Aider's lesson: machine format primary, human export a separate derived artifact (11 §D.5). Pure projection. |

---

## 2. Where the research contradicts something already frozen (say it loudly)

1. **`seek`/rewind exists in the frozen command vocabulary with no durable
   counterpart: and the frozen tip law forbids retrofitting one.**
   Protocol §4 freezes `seek{to_offset}` ("time-travel a read-model…
   checkpoint/rewind"). Every leader makes rewind *durable* (Claude `/rewind`
   copy-on-fork; Gemini `$rewindTo` supersede records; grok truncate-in-lockstep;
   Codex `thread/rollback`; goose `--resume --fork`: 10 §1-4, 13 §A). JS-FREEZE
   §1.4 says a change that "would silently move historical tips" is in the
   *never* column, which is exactly what any later rewind/branch kind does to
   the frozen "highest conversational offset" predicate. If rewind is intended
   to be read-model-only forever, freeze THAT; if not, G2 must land now.
2. **`harness-spec-backend.md` §4 still says "foldable Ecto event table (or
   DETS)" and "Oban = probe scheduler."** Both were overturned by round 2
   (D1 → files, NC-6/NC-7; D2 → in-BEAM pool, roadmap §3.2). Stale doc, not a
   real conflict, but a red author reading the spec first would build against
   dead decisions. Patch or banner the spec.
3. **U15 freezes "raw output journaled" while nothing bounds a record.**
   Intent-gated tools journal the *raw* (multi-KB..MB, tainted) tool result
   inline (roadmap U15, spec-backend §5-C3). That mandate plus no size
   discipline is precisely Codex #24948 (700MB-2GB session files) and #22004
   (V8 string-ceiling permanent unloadability). The freeze and the horror
   catalog are on a collision course → G1.

---

## 3. The day-one gaps (the deliverable's core)

Each gap: evidence → why retrofit = rewrite → **the minimal additive
reservation**, shown to be additive under the governing rule.

### G1: Payload externalization: a frozen blob-ref convention + `blobs/` CAS

**Evidence.** Codex #29510 (30-40GB RAM loading an 11.88GiB rollout, single
lines to 60.9MB, "no byte/record cap"); #24948 (inline `replacement_history`
337.8MB + untruncated tool output 230.8MB); #22004 (inline base64 > V8 string
ceiling ⇒ session permanently unloadable); Claude Code #22365 (3.8GB session,
12.8GB RAM per prompt): all 10 §2, 15 §1.5. Theory: SQLite fasterthanfs
crossover ~250KB-1MB, "large attachments belong on the filesystem, referenced
by path/hash, not inlined" (15 §2.3); Temporal's claim-check as the *named*
fix, with the sharp counter-lesson that even the compaction carryover has a
2MB ceiling (12 §2.3-2.4); OpenHands' own benchmark: ObservationEvents = 47.8%
of events but **78.0% of bytes** (11 §1). Steal-list item 6 of brief 15 is
verbatim this.

**Why retrofit is a rewrite, not an add.** Today `item_completed.payload.content`
is an inline value and U15 mandates journaling raw tool output. The moment red
suites and the UI fork lock byte-identity and fold semantics on inline content,
switching a payload value from `"...string..."` to `{"$blob": ...}` is a
**semantic repurpose of an existing field**, exactly what the governing rule
forbids (I9: no type-narrowing/repurpose). A v1 reader receiving a v2 blob-ref
renders garbage or breaks folds; "readers tolerate unknown *fields*" does not
cover a known field changing meaning. This is the dual-id landmine's sibling.

**Minimal additive reservation (freeze now):**
1. Layout grows one sibling dir: `<session>/blobs/<sha256>.bin`: same
   content-addressed discipline the frozen `snapshots/` dir already uses
   (write-before-append, FI-8 atomic, orphans never implicitly deleted per
   FI-7). One CAS mechanism, two consumers.
2. Freeze the **marker**: anywhere a payload carries bulk bytes, the value MAY
   be `%{"$blob" => "blobs/<sha256>", "bytes" => n, "media" => "..."}` .
   Registered like a kind: grow-only, never repurposed. Readers built against
   v1 MUST render/deref-or-opaque a `$blob` value. This is a *reader-seam
   tolerance rule*, one clause added to JS-FREEZE §1.1 reader tolerance.
3. Freeze the **write-side law** (threshold is policy, the law isn't):
   a Writer-enforced per-record byte ceiling exists; payloads over it are
   externalized to `blobs/` before append. Redaction (FI-10) runs before
   hashing: same order as the checkpoint snapshot discipline.
4. Fold/tip/offset semantics unchanged: a blob ref is payload data.

Additive proof: new dir + new registered value shape + a Writer knob; no field
renamed, nothing required, grandfathered journals unaffected, `schema_version`
minor bump. Cost now ≈ one marker definition and one reader-tolerance red.

### G2: Rewind/branch/fork: rule the durable-history model before the tip law petrifies

**Evidence.** Universal in the cohort: Claude Code `parentUuid` DAG + `/branch`
`/rewind` `--fork-session` (copy-on-fork, "resume is DAG reconstruction, not
flat replay", 10 §1); OpenHands `parent_id` event *tree* with `fork()` (11 §1);
pi-agent's JSONL-tree ("per-line parent pointers give a DAG without a database",
12 §5.4); Gemini `$rewindTo` supersede records; grok `/fork` + snapshot-backed
`/rewind`; Codex `thread/rollback`; LangGraph fork bug #4987 (reused checkpoint
id on fork ⇒ "all the history after time travel is broken": 12 §1.4).
**The retrofit horror is already documented**: OpenHands #4057: the flat-log →
parent-pointer-tree migration silently orphaned 5,566 of 5,731 events; nothing
deleted, history permanently unreachable (11 §1). That is precisely a
"retrofit branching after the format locked" incident.

**Why retrofit is a rewrite.** The frozen tip predicate is *definitionally
linear* (highest conversational offset). Any later durable rewind/fork
either (a) changes tip computation: §1.4's forbidden "silently move historical
tips," breaking every version-skewed UI-fork reader on any journal containing
the new record, or (b) forces an OpenHands-#4057-style history migration.
Neither is additive. Meanwhile P-JS2/P-JS3 reds and golden fixtures are about
to hard-lock linear tip selection.

**Minimal additive reservation: pick one, now (this is a human ruling):**

- **Option A (recommended: matches the frozen grain): fork = copy-on-fork,
  journals stay linear forever.** Freeze one sentence: *"a journal is linear;
  branch/rewind/fork materialize as a NEW session whose `meta.json` carries
  `forked_from: %{session_id, offset}`; no record kind will ever alter tip
  selection."* Claude Code ships exactly this shape at leader scale; it keeps
  the tip law, the offset law, the Dormammu reds, and I5/I6 untouched: cost
  is duplicated prefix bytes (mitigated by G1 blob sharing: forks re-reference
  the same CAS blobs for free; segment hard-linking is a later optimization
  invisible to the contract).
- **Option B: reserve an in-journal `supersede` record kind** (Gemini's
  `$rewindTo` shape: `%{kind: "supersede", upto_offset}`) and amend the tip
  predicate NOW to be supersede-aware before any red locks. Cheaper disk,
  costlier contract: tip determinism reds get a second dimension immediately.

Either ruling is additive **today**; in six months neither is. The trap is not
choosing.

### G3: GC low-watermark: a truncated prefix must be representable as *healthy*

**Evidence.** OQ-JS2 ruled GC deferred with a reserved `gc` kind: correct on
retention *policy*. But I5/I6 and P-JS1 are about to lock "record ids dense
`1..n`," "missing middle segment ⇒ damaged," and golden fixtures whose first
segment starts at offset 1. Codex #6015/#20230 (retention demanded), Claude
#62041 (why it must be consent-gated) establish GC *will* come; checkpoints
(frozen) exist precisely so the prefix can eventually be dropped (12 §A:
Temporal's hard history ceiling as the "what happens if you can't" anchor).

**Why retrofit is a rewrite.** When `gc` lands, a post-GC journal *is* a
journal with missing leading segments. Under today's frozen reader semantics
that is indistinguishable from the damage class I6 exists to catch, so either
GC'd journals read as damaged (breaking FI-9's "damaged is never injected"),
or the damage detector is weakened (breaking I6's guarantees). Every fixture
and dead-injector for I5/I6 would need re-authoring: red-suite rewrite.

**Minimal additive reservation (freeze now, ~4 sentences):**
1. The journal's valid range is `[low_watermark, n]`; `low_watermark = 1`
   today and forever-until-GC.
2. A future `gc` record (kind already reserved) is **appended at the tail**
   (consumes an offset, per the offset law) and names the truncated range +
   the checkpoint that covers it; HEAD may mirror `low_watermark` (allowlist
   grows one key: additive under I8).
3. Reader rule, frozen now: leading segments missing **iff** a surviving `gc`
   record (or HEAD watermark) attests them ⇒ healthy; missing without
   attestation ⇒ damaged, exactly as today. Density law restated: dense on
   `[low_watermark, n]`.
4. `fold(0..x)` reads as `fold(low_watermark..x)` ⊕ covering checkpoint, 
   which is P-JS4's restore formula already.

Additive proof: no behavior change while `low_watermark = 1`; reds authored
against the parameterized law are correct on day one AND on GC day.

### G4: Approval decisions and policy amendments are journal records, not just commands

**Evidence.** AD-14 (frozen disposition): decisions distinguish `Denied` ≠
`Abort`, `TimedOut` first-class, and "a decision may carry a policy amendment
(approval that also edits the rule)": Codex's `ApprovedExecpolicyAmendment`
steal (13 §1). U8's Tier-2 invariant asserts "after deny, no later success for
that call_id": an assertion only foldable if the deny is *in the journal*.
The OpenClaw incident class (06 §1.8): constraints that live outside durable,
structured state die at compaction/resume; U14b's accept criterion ("rule
blocks the matching call *after compaction*") requires amendments to survive a
resume. The loop-family table (protocol §3) has `approval_requested` and **no
decision event**.

**Why this is day-one.** The registry is grow-only, so the *type* is additive, 
but U8-R reds are unblocked by the current freeze (§4 table) and will lock the
approval ordering contract without the decision record. Reds authored against
"deny ⇒ no Port" with no durable deny observable will either use a side-channel
oracle (violating oracle-independence, meta-inv 6) or under-specify the exact
audit property AD-14 exists for. Retrofit = re-author the U8 suite + fixtures.

**Minimal additive reservation:** freeze two loop types now (grow-only table
append): `approval_decided %{ref, decision, scope, amendment | nil}` (durable,
CONVERSATIONAL-membership decided now: recommend **no**, it's a gate signal
like `state_change`, but `approval_requested` stays in per OQ ruling) and the
rule that any amendment applied to live policy MUST have its durable record
appended before enforcement (mirror of reserve-before-call). Zero change to
existing types.

### G5: Command idempotency key

**Evidence.** Codex `client_user_message_id` ("client-side idempotency/
correlation", 13 §1); CloudEvents dedup = id+source *pair* (15 §2.5);
idempotent-consumer discipline: "a stable idempotency key generated at write
time: offset-based keys break under replay/compaction" (12 §3.4). S2 (mobile
reattach) is a frozen roadmap goal; retried `prompt` POSTs over a flaky wire
without a dedup key = duplicate turns, and the duplicate is *durable forever*
in an append-only journal.

**Why day-one (cheap tier).** Additive field on `%Command{}`, but U3's
command-seam validation and S2's reds will freeze ingestion semantics; dedup
added later changes observable behavior (second submit: new turn vs. no-op
`{:ok, duplicate}`) that surfaces will have coded against. Journal-side it also
gives `turn_started` a durable provenance link to the client message.

**Minimal additive reservation:** optional `client_msg_id` on `prompt`/`steer`
commands + frozen semantics: same `(session_id, client_msg_id)` within the
dedup window ⇒ idempotent accept referencing the original turn, never a second
turn. `turn_started.payload` grows optional `client_msg_id`.

### G6: On-disk permissions in the write discipline

**Evidence.** Codex #21660: rollouts 0644/dirs 0755, world-readable full
transcripts; the 0600 pattern existed in the same codebase and was never
applied to the recorder; vendor closed it "Not Applicable" (10 §2). Cursor
creds in world-readable SQLite (15 §1.4).

**Reservation:** one frozen sentence in the Writer/FI-8 discipline: session
dirs 0700, all files 0600, asserted by an I-suite property (fixture-level,
trivial). Retrofit is a chmod, but the *guarantee* has to exist before anyone
builds "share this dir" tooling on top, and it costs one line now.

---

## 4. Cross-cutting hypothesis: the ONE storage shape

**Hypothesis: the composing shape is "a single offset-addressed log that holds
only pointers and small facts, plus a content-addressed immutable store that
holds all bytes, with every other artifact derived-and-disposable." Git's
refs-plus-objects, applied to a session.**

The argument from the corpus, both directions:

- **Every leader converged on the log half** (JSONL append + in-log pointer
  records + reverse-scan resume: 10 §D), and the two that also grew a CAS half
  did so for exactly the bytes that don't belong in a log: Claude Code's
  `file-history/` is literally `{contentHash}@v{n}` (10 §1); our frozen
  checkpoint snapshots are `snapshots/<sha256>.json`. G1 just finishes the
  pattern for the third bulk class (tool output / wire bytes).
- **Every horror story that isn't "vendor deleted it" is a second source of
  truth drifting from the first.** Index vs. files (Codex #21196: 91 DB rows,
  1 file; Claude #39667/#41591/#66499); UI list vs. DB (Cline #6183, opencode
  ×4); compression state vs. on-disk log (Gemini #20803); session-id rebind
  vs. artifact namespaces (Gemini #24639); three opencode migrations each
  orphaning data *between two stores of the same fact* (11 §2). The taxonomy
  in 15 §3.A classes 5 and 6 are both this. The frozen substrate already
  encodes the cure twice (tip is derived, never stored; index derived, never
  authoritative): the hypothesis says: apply that law *universally*.
- **The predictive rule** (this is the isomorphism): *any fact that can change
  replay behavior must be either a record in the log or immutable bytes the
  log points at, and anything else must be deletable without loss.* Every gap
  in §3 is a place where a fact was about to be born outside the shape:
  bulk bytes inline in the log (G1, wrong side of the split), branch/rewind
  living in reader heuristics or a mutable sidecar (G2, Claude's Dormammu was
  precisely tip-truth living outside the record), a truncation living only in
  the filesystem's shape (G3), a policy amendment living only in a GenServer
  (G4: the OpenClaw class), turn identity living only in a wire retry (G5).
- **Counter-evidence honestly weighed:** the ES-practitioner literature warns
  the log-as-database is not settled wisdom (Kleppmann's own caveats, 12 §3.5)
  and ES-everywhere burned teams (12 §4.2). The hypothesis survives because
  the frozen design already took the survivable subset: log + forward-folded
  materialized views, *never* pure re-fold (harness-design L4), snapshots
  reactive not day-one (12 §A), single writer, short-lived per-session streams
  (Dudycz's load-bearing tactic, 12 §4.3). The CAS half inherits none of the
  ES pain: content-addressing is immutable by construction, dedupes fork
  prefixes (G2-A), gives integrity checks for free (frozen `snapshot_hash`),
  and makes FI-7's "orphans are harmless" true (an unreferenced blob is
  garbage-collectable *by consent* with zero correctness risk).

If the ruling adopts the shape as a stated law ("log points, CAS holds,
everything else derives"), G1-G4 stop being four separate patches and become
one sentence's corollaries: that's the test that it's the right shape.

---

## 5. Contract-impact call-outs: decide X before reds lock

Ranked by retrofit cost if missed (1 = rewrite of history/readers, 5 = suite
re-authoring only).

| Rank | Decide before | Decision | Blocks / petrifies |
|---|---|---|---|
| 1 | U4-R/U9-R authored | **G2: fork model: copy-on-fork (A) or supersede kind (B).** The tip-law reds and golden fixtures petrify linearity the day they land. | P-JS2/3 fixtures, §1.4 never-column, UI-fork tip logic |
| 2 | U15-R (and any fixture containing a tool result) | **G1: blob-ref marker + `blobs/` CAS + record ceiling.** Once inline-content byte-identity is in the I9 corpus, externalization is a repurpose. | I2 byte-identity, I9 golden corpus, UI-fork renderers |
| 3 | I5/I6 golden fixtures checked in | **G3: low-watermark law.** Parameterize density/damage semantics now while it's a no-op. | I5/I6 fixtures + dead injectors, FI-9 damage rule |
| 4 | U8-R authored | **G4: `approval_decided` (+ amendment-before-enforcement rule).** | U8/U14b reds, AD-14 audit property, oracle independence |
| 5 | U3 seam reds + S2 | **G5: `client_msg_id` dedup semantics.** | command-seam contract, mobile retry behavior |
| 5 | first shared fixture dir | **G6: 0600/0700 in FI-8 discipline.** | trivial, but free only now |
|  -  | (doc hygiene, this week) | Patch `harness-spec-backend.md` §4 (Ecto/DETS/Oban) to the D1/D2 rulings; add G1/G3 clauses to JS-FREEZE §1.1; record §1's BOLT-ON deferrals as named non-commitments (NC-9 workspace store, NC-10 encryption-until-sync, NC-11 no multi-writer). | red authors reading stale specs |

---

## 6. Open questions for human ruling

1. **G2 fork model: Option A (copy-on-fork, linear journals forever) or
   Option B (supersede records)?** A is recommended (matches Claude Code at
   scale, zero contract disturbance, CAS makes it cheap); B is smaller on disk.
   This is the single decision the rest of the doc can't make for you.
2. **G1 threshold**: the *law* (ceiling exists, marker frozen) vs. the *number*
   (16KB? 64KB? the 250KB-1MB crossover from 15 §2.3?): recommend freezing
   the law and leaving the number policy, mirroring the frozen charge-shape /
   cost-function split in U12.
3. **G4 placement**: is `approval_decided` `family: :loop` (audit-adjacent to
   `approval_requested`) or `family: :meta`? Loop recommended (it brackets a
   turn-blocking gate) but it must NOT enter CONVERSATIONAL (a trailing deny
   is not a resume point; same Dormammu logic that ratified `approval_requested`
   *in*).
4. **Provider-wire fidelity**: is `item_completed.content` frozen as
   *verbatim provider content blocks* (AD-5's never-filter rule made a storage
   guarantee), or is a separate `wire_ref` blob (via G1) required so post-crash
   resume can rebuild the byte-identical prefix N-U12.5 demands? Today
   `prefix_ref` is in-memory only; after a BEAM death, cache-riding byte-identity
   and continuity-token replay (#63147's poisoning class) both depend on the
   answer. Recommend: rule that the journal's loop events are sufficient to
   reconstruct the provider request byte-for-byte, and add one U4/U12 bridging
   red asserting it.
5. **Sub-agent linkage (item 19)**: `meta.json.parent_session` vs. a spawn
   meta event vs. both? Cheap either way; decide before `Agent.Team` sessions
   write journals.
6. **Does the §4 shape get stated as a governing law** ("log points, CAS holds,
   everything else derives") in JS-FREEZE §0, so future kinds/dirs are tested
   against it the way the offset law is tested today?
