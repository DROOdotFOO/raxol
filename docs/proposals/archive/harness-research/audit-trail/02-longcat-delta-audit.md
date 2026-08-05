# DELTA AUDIT: harness-freeze-contracts.md (fold-before-reds revision)

Grounding: landed `EmitBridge` (`append_durable`→`map_event` then emit, journal owns durable id), `Contract.Event` (v0 struct: `v,id,session_id,turn_id,ts,family,type,tier,payload`), `Writer` (`stamp` adds `id`+`schema_version` only; `flush` rewrites HEAD with `max(HEAD,last_offset)` resume), `Reader` (`continuous?` requires dense `prev+1`, anchors on first record, torn-tail = final-line-unterminated). None of the new fields (`kind`,`branch_id`,`actor`,`scope`,`provenance`,`cost_ref`,`fingerprint`) exist in landed code yet: freeze-first, so "renames nothing" holds. The failures below are *within the frozen contract itself*, not landed-code regressions.

The previous audit's F1-F9 + 9 OQ rulings are folded in correctly and I do not relitigate them.

---

## 1. CARDINAL-SIN CHECK (new fields/kinds/types)

**🔴 RED: `approval_decided` carries `actor` in its payload, duplicating the envelope `actor`.**
- §2.1 lines 546-552: "approval_decided additionally names actor in its payload (its G4 shape); when both are present they agree by producer-seam stamping."
- §2.1 lines 539-541 just established the *entire point* of the uniform-actor seam: "individual modules never invent it. This is what keeps a nullable-everywhere field from becoming inconsistent garbage." Having `approval_decided.payload.actor` re-introduces exactly the dual-location footgun that rule was created to eliminate. Approval_decided is a `kind:"event"` record, so `envelope.actor` is already present on it → the payload copy is **100% informationally redundant**, yet an implementer who stamps one but not the other produces a "disagreeing" event that N-U11.8/P-U11.6 must then catch: i.e. the redundancy *creates* the very class of bug the uniform-actor principle forbids.
- **Fix:** Drop `actor` from `approval_decided`'s payload-required keys (line 628). Consumers read `envelope.actor`. If a "decision-scoped mirror" is genuinely wanted, derive it at read time, never store it. This makes `actor` single-sourced on the envelope, consistent with every other type in the registry.

**🟢 `branch_id` as string `"main"` (vs atom):** PASS. String cohabits cleanly with JSONL (the Writer stringifies keys); the yolo-safe C1 option B originally floated atom `:main`, correctly dropped. "main" is reserved-but-defaulted, grandfather-safe. No rename pressure from any plausible unit.

**🟢 Lineage `relation` enum `:fork|:spawn|:merge|:import`:** PASS. Each has frozen offset semantics (line 328-339); `:resume`/`:replay` explicitly forbidden (line 334-335). `:import`'s "session_id = source id at export, not reused id on new host" closes a rename trap. The grow-only `detail` map is the right escape hatch for spawn subtypes (line 347). One minor doc gap: pin the edge shape as `%{session_id, offset, relation, detail \\ nil}` in §1.1-lineage (line 320, and "Each edge MAY carry … detail" at line 347): see §5.

**🟢 Fingerprint struct fields (`provider,name,revision,params_hash,params_inline,prompt_cache_key`):** All future-proof. Splitting `params_hash` (canonical) from `params_inline` (audit slice) and explicitly keeping `prompt_cache_key` OUT of replay identity (line 587) divides concerns correctly. `revision \\ nil` handles APIs that lack it. PASS.

**🟢 `effect_class` taxonomy (`:reversible_local|:bounded_sandboxable|:irreversible_external`) + `egress:boolean`:** PASS as a contract. Three escalation-relevant classes with a grow-only axis. Correct that escalation is keyed to `effect_class`/structural truth, not self-reported `destructiveHint` (yolo-safe N-Y5 lineage, line 1088). Caveat: see §5 (restated-predicate dependency).

**🟢 `consent_class` (`:private|:shareable|:train`) on annotations:** PASS, grow-only. The `:train` value correctly marks the sharing axis without polluting the enum with policy.

---

## 2. INTERACTION BUGS (new × previously-frozen / landed)

**🔴 RED: `params_hash` canonicalization is untestable as written; P-U11.7 cannot be satisfied.**
- §2.1 lines 576-582 specify the hash as "sha256 over the JSON of the params object with sorted keys and a documented excluded-ephemeral list (request ids, timestamps, **and other per-call noise** are excluded); one serialization."
- The document IS the normative contract (no other doc is named), but the exclusion list is incomplete ("and other per-call noise"). Two **independent** encoders writing golden fixtures (required by P-U11.3/P-U11.7's oracle-independence) WILL diverge: one excludes `seed`, another keeps it; the hashes disagree and the "same params across turns" positive contour fails unpredictably. This is a frozen *positive* contour property with a missing normative input.
- **Fix:** Inline the exhaustive exclusion list here (e.g. `{:"$request_id", :request_id, :timestamp, :ts, :trace_id, :idempotency_key}`), or name one normative serializer function by module/arity that BOTH encoders call ("one serialization") and require golden fixtures to go through it. Drop "and other per-call noise": ambiguous exclusions are not a contract.

**🟡 YELLOW: `$blob` FI-10 secret-scrub coverage is ambiguous vs checkpoint snapshots.**
- §1.1 lines 286-287 (the `$blob` marker) say only "redaction runs before hashing" for externalized payloads. §1.1 lines 300-309 (FI-10) say checkpoint *snapshot files* pass "the same write-boundary discipline as event payloads (`Contract.sanitize_payload`-class sanitization **+ MS secret exclusion**) before hashing/writing."
- The `$blob` path is NOT explicitly given the MS secret-exclusion treatment. Consequence: a payload value containing a *large* secret (exceeds the Writer's per-record byte ceiling) gets externalized to `blobs/<sha>` at raw byte level with only value-level `$redaction` (which replaces the *whole* value with a marker, not byte-scrubbing). So a big secret evades FI-10 scrubbing by being big.
- **Fix:** Add to line 286-287 that `$blob` bytes pass `Contract.sanitize_payload`-class sanitization + MS secret exclusion before `sha256`/write, exactly mirroring the snapshot discipline (line 302). And tie the byte-ceiling threshold ordering: sanitize BEFORE externalize (so a sanitized-shorter value may never cross the ceiling).

**🟡 YELLOW: `P-JS11` / `N-JS11` are vacuous at `low_watermark = 1` and cannot be generated until GC lands.**
- §1.2 line 409 / §1.3 line 437. P-JS11 claims "record ids dense across `[low_watermark, n]`; a prefix missing below an attesting `gc`/HEAD watermark reads healthy." At `low_watermark = 1` (frozen default, line 130), there is NO "below-watermark" range to truncate, so the only legal missing-prefix (id-1..N-1 gone) is precisely the scenario the test treats as legal, but it's ungeneratable because `gc` is reserved-not-frozen (line 159) and HEAD has no watermark while `low_watermark=1`. So neither a generator nor an injector can exercise P-JS11/N-JS11 in v1; the requirement only becomes real once GC sets `low_watermark > 1`.
- This doesn't contradict the freeze, but the doc *implies* the tests are authorable now (U4-R/U9-R/U10-R are listed as immediately unblocked). A test author hitting "I can't build a journal with `low_watermark>1`" has no guidance.
- **Fix:** Mark P-JS11/N-JS11 `@tag :gc` / "deferred until a gc record or HEAD `low_watermark>1` exists," mirroring the gc reservation (line 159). Or require the test harness to inject a synthetic `gc` record + HEAD watermark (with a clear note that this simulates a future state).

**🟡 YELLOW: speculation plural-refs vs the FOREVER session-scoping contract: cross-session merge parents are unaddressed.**
- §2.1 line 614: "at `:begin`, refs names the parent tip offset(s)… a merge-commit speculation names N parents." §2.1 lines 626-634 (OQ-U11.1, "permanent, load-bearing"): in-journal refs resolve *only within the enclosing session*; cross-session refs are "forbidden" in-journal.
- For **Option B (in-journal branches, line 105-108)** the N parents all sit in one journal → refs in-session, fine. For **Option A (copy-on-fork separate sessions, also allowed at line 103-104)** a speculation has one fork-source parent whose tip offset is copied into the child's journal → the number resolves in-session, fine. The contradiction appears for a **merge-commit speculation whose N parents live in different sessions** (the case line 614 explicitly raises): in-journal refs cannot name them (forbidden), but the type's shape says they go in `refs`.
- **Fix:** Restrict speculation `:begin` `refs` to in-session parents (consistent with Option-B semantics), and direct cross-session merge relationships into lineage (`meta.json` `:merge` edges, §1.1) rather than `refs`. State this limitation explicitly so a multi-parent-implementing author doesn't build against an impossible shape.

**🟡 YELLOW: `client_msg_id` idempotency has no defined dedup window and no durability model.**
- §5.1 lines 1064-1067: "Duplicate delivery (same `(session_id, client_msg_id)` within the dedup window)" and "an idempotent accept referencing the original turn."
- "within the dedup window" is undefined (process lifetime? session lifetime? wall-clock TTL?), and the doc does not say where dedup state lives (in-memory ingest server?). If it's in-memory only and the ingest process restarts / the session replays after a BEAM death, a re-delivered `client_msg_id` creates a second durable turn → idempotency silently broken. The "offset-derived keys are forbidden (break under replay/compaction)" note (line 1068) shows awareness of replay but doesn't resolve the durability question.
- **Fix:** (a) Define the dedup window (recommend: session lifetime or explicit TTL, documented). (b) Require dedup state to be durable/across-restart (e.g. persisted in a checked-in write-discipline location, or folded from `turn_started.payload.client_msg_id` already in the journal) so replay/compaction preserves idempotency. Otherwise this is an honor system.

**🟢 (pass) low_watermark × resume `max(HEAD, last_offset)` × grandfathered journals (2c):** The landed Writer already resumes from `max(HEAD_offset, Reader.last_offset)` (writer.ex `resume_offset`, line 243); `low_watermark=1` leaves that path byte-identical. Grandfather records decode `branch_id:"main"`, `kind:"event"`, `scope:session`, `provenance:trusted` via the default clauses. No interaction break. PASS.

**🟢 (pass) `schedule`/`woken` × tip closure × Dormammu (2d):** `woken` is deliberately family:`loop` but excluded from CONVERSATIONAL by the explicit list (line 224) and the closure rule defaults all non-listed types to excluded (line 228-232) → predicate `kind=="event" ∧ family=="loop" ∧ type∈CONVERSATIONAL` omits it (the positive note at line 236 records this is intentional). `schedule` is a non-`event` kind → omitted. Clean; Dormammu (P-JS3) now covers `woken` too. PASS, with NIT: `woken` still needs a loop-vocabulary registration / EmitBridge mapping before it can be emitted (not yet in landed code): add `woken` to the loop-type owner (`contract.ex` vocabulary) so it isn't rejected at the producer seam.

**🟢 (pass) actor producer-seam stamping × EmitBridge append-before-publish ordering (2e):** EmitBridge appends-first-then-emits (line 140-167, non-blocking on the ordering). Stamping `actor` (and `scope/provenance/cost_ref`, envelope fields) into the *neutral map* before `append_durable` puts them on both the durable record and the live event in the correct order. No ordering hazard with `append-before-publish`. **BUT**: genuine touchpoint: both `durable_record/1` (line 276-292) and `map_event/3` (line 199-215) currently build their maps from a *hardcoded key list* that does NOT include `actor`/`scope`/`provenance`/`cost_ref`. So carrying the envelope fields end-to-end requires extending **both** functions (journal path + live path) and the Reader to decode them. This is freeze-first (expected), but a red author implementing P-U11.6 ("actor equals write-generation context actor … recomputed from raw producer context") and P-U11.P must know they're extending two parallel code paths to carry the same field: flag it.

---

## 3. CONTOUR QUALITY OF NEW P/N ROWS

Most new negatives carry **real** dead-injectors (would actually break the red if present): good scrutiny:

- **N-JS8** (§1.3 line 435): dropping the `branch_id==b` clause on the tip predicate → tip(journal,"X") returns a record from branch "Y". Real. Admitting any family:`loop` type regardless of CONVERSATIONAL → a trailing `woken` (or `idle`) gets selected; P-JS3 + P-JS8 both catch it. **Real.**
- **N-JS9** (line 436): a reader that damages-on-missing/dangling-or-cyclic parent → breaks P-JS9. Real.
- **N-JS10** (line 437): reader damaging-on-missing-blob **OR** Writer appending the record *before* the blob file → referenced-but-absent blob (torn-tail × blob). Real.
- **N-JS12** (line 439): redactor re-serializing the record (landed-class timestamp corruption) or substring-scrubbing across framing → neighboring hash/offset changes. **Real and important**: single strongest new negative.
- **N-U11.8** (§2.3 line 737): module-local actor stamping / reader inferring human/agent from absent actor → breaks P-U11.6. Real (and is the primary guard for the uniform-actor decision).
- **N-U11.9** (line 738): fold reading head-model as "what produced this" instead of the `item_completed` fingerprint → breaks the precedence law P-U11.7. Real.
- **N-U11.10** (line 738): validator hardcoding `length(refs)==1` at `:begin` → breaks P-U11.8 plural round-trip. Real.

**Exception:** **N-JS11** (line 437, density hardcoded to `1..n` ignoring `low_watermark`, OR "treating any missing segment as attested"), at `low_watermark=1` both injectors are neutralized (there is no below-watermark range and no `gc` to attest), so the dead-injector is **decorative until GC lands**; see §2 P-JS11 above.

**Orphan-positive check:** every new positive has a real negative counterpart: P-JS8↔N-JS8, P-JS9↔N-JS9, P-JS10↔N-JS10, P-JS12↔N-JS12, P-U11.6↔N-U11.8, P-U11.7↔N-U11.9, P-U11.8↔N-U11.10. The F9-relabeled oracle-agreement / corpus tests (P-JS2, P-JS7, P-JS8, P-U11.1, P-U11.2, P-U11.3, P-U11.P) are correctly flagged as properties/decode-checks that don't take single-mutation dead injectors by design (oracle independence). No orphan positives.

---

## 4. THE 4 CONFLICTS THE FOLD AGENT FLAGGED (ratify/reject)

1. **Tip arity change** `tip(journal)` → `tip(journal, branch \\ "main")`. **RATIFY.** 0-arity preserved and grandfather-safe (every pre-`branch_id` journal reads as `"main"`); no red rewritten. Clean.

2. **`approval_decided` family supersession** (journaled decision record supersedes in-memory "after deny, no later success" as a fold). **RATIFY-with-note.** The journal becoming authority is right; the taint/fold audit wins. *Note:* U8's **live** enforcement still reads in-memory `approvals` MapSet (`engine.ex` lines 20-28, 155): the contract says "fold, not an honor system" but does not state that live state must rebuild from `approval_decided` events on replay/resume. Not a freeze *defect* (reds don't enforce live rebuild), but an implementer rebuilding U8 will discover a described-authority / live-state seam the freeze is silent on: worth one sentence.

3. **Actor envelope/payload redundancy** (the fold flag: `approval_decided` naming `actor` in both envelope and payload). **REJECT.** See §1 RED above: it directly contradicts the uniform-actor principle this same revision establishes (§2.1 539-541) and re-introduces the dual-location bug class. Drop `payload.actor`; read `envelope.actor`. This is the one flagged resolution I'd block.

4. **Kind-set expansion** (adding `annotation` + `schedule`). **RATIFY.** `compaction` correctly folded into `checkpoint{reason:"compaction"}` (line 151-155); `attach`/`reattach` correctly rejected as kinds (read-side ops mustn't depend on them, line 156-160); `gc` correctly reserved-not-frozen (line 159-165). Both new kinds are additive, tip-excluded by the closure rule, and produce-justified. `annotation`'s only loose end: any-writer-append (line 142 "any writer (reopen the single Writer)"): acceptable (annotations are non-authoritative), but note it in §5 as an authorization NIT.

---

## 5. AMBIGUITIES A RED AUTHOR WOULD TRIP ON (concrete, fix each)

A. **SPEC/SIN**: §2.1 line 628 pins `approval_decided` payload keys as `%{request_ref, decision, actor, refs}` but `decision`'s allowed values are never enumerated (`:approved|:denied|:overridden|:delegated`?). *Pin `decision` enum and (after fix #3) drop `actor`.* (Same applies to `policy_amended.source`, line 629: listed `:human|:calibrate|:oracle`, good, leave.)

B. **RESTRUCTURE**: §1.1-lineage edge shape (line 320 `session_id,offset,relation` + line 347 optional `detail`) vs. the typed list-across slot isn't a concrete map. *Pin `parents: [%{session_id, offset, relation, detail \\ null}]` here so meta.json fixtures/goldens match across authors.*

C. **TAXONOMY**: §5.2 references yolo-safe §2/§7 for the *auto-approve predicate* but does not restate the predicate structure (which classes are non-escalating, how `egress` participates). §5 claims to be "**the** contract source of truth" for the taxonomy, then the predicate decided on that taxonomy must be here too, not behind a cross-read. *Inline the predicate: escalate iff (`effect_class == :irreversible_external`) ∨ (`egress == true`); otherwise YOLO-applicable over trusted lineage.* Also §5.2 admits the field lives in the unfrozen `F2 Raxol.Action` draft, so the taxonomy is frozen but the *existence/location* of `effect_class`/`egress` is not; a red author writing effect_class reds needs the F2 draft landed first, or a `@tag :action_surface` freeze note.

D. **WITNESS**: §1.1 `$blob` optional keys `"bytes"/"media"` (line 279): is `"bytes"` *required* to equal the deref'd file size (mismatch ⇒ `:snapshot_corrupt`-style error) or advisory? For P-U11.10 (deref-then-fold equals inlined fold), the size relationship matters. *Pin semantics.*

E. **STRUCTURE (annex)**: §5.1 `client_msg_id`: beside the dedup-window/durability fixes (§2), clarify whether the idempotent *accept* is itself a durable event or only a live ack (affects replay: a re-sent msg that was only live-acked doesn't re-emit a durable `turn_started`, but must the ack be reconstructable?). *Pin the idempotent-accept observability contract.*

F. **NIT: `woken` loop registration.** `woken` is listed only as a `family:loop` tip-exclusion exemplar (line 233-239); it is not in the loop vocabulary owner (`contract.ex`) nor the EmitBridge neutral→contract mapping (line 312-315). Before any woken is emitted, `woken` must be added to that vocab + mapping, or the producer seam rejects it. *Pin `woken` into the loop vocabulary registry.*

G. **NIT: Producer/seam dual stamping (§1.1 vs §2.1):** `kind` and `branch_id` are **Writer**-stamped (§1.1); `actor`,`scope`,`provenance`,`cost_ref` are **EmitBridge**-stamped (§2.1); `id`,`schema_version` are **Writer**-stamped. No single diagram shows the full record lifecycle, and the envelope fields must pass through BOTH `durable_record/1` and `map_event/3` (§2 touchpoint). Add one record-lifecycle diagram (neutral→EmitBridge-stamp→Writer-stamp{id,branch_id,kind,schema_version}→disk; live path mirror) so a red author doesn't strand a field on one path.

H. **NIT: `annotation` write authorization:** "any writer (reopen the single Writer)" (line 142) can append annotations. Since annotations are tip-excluded and non-authoritative this is low-risk, but a malicious/corrupt process could bloat a session's journal with unbounded annotations. *Pin whether annotation append requires any authorization or is open-any-writer, and whether annotations count toward segment rotation / GC (they do, by being records).*

I. **NIT: bounded-parking predicates past `max_parked` (§3.3 N-U12.3 vs N-U12.10):** clarify which signal wins when submit hits BOTH `budget-exhausted` (→ `:parked`) AND `max_parked` exceeded (→ excess shed to `:exhausted`). *Pin: if the run cannot be parked, it's `:exhausted` (not `:parked`) and still emits exactly one terminal `probe_run` event: `max_parked` dominates the parking state.*

---

## VERDICT

**NOT safe to author reds against as-is** at the precision level this freeze demands, but the fix list is short and the doc is otherwise in strong shape. Two of the items are genuine frozen-contract defects that will otherwise produce diverging test suites:

**Fix-first (block the reds that depend on them):**
1. **`approval_decided` actor-in-payload redundancy → DROP the payload `actor`** (conflict #3, §1 RED). Breaks the uniform-actor principle this revision just established; real divergence surface.
2. **`params_hash` canonicalization → inline the exhaustive exclusion **exclusion list** or name the single normative serializer** (§2 RED). Currently P-U11.7 is untestable across independent encoders.
3. **`client_msg_id` dedup → pin window + durability model** (§2 YELLOW: persistence across restart/replay). Otherwise idempotency is an honor system.

**Fix-before-GC-but-blocks-their-respective-reds-now (can ship as `@tag `:gc`/deferred, but must be explicit):**
4. **`P-JS11`/`N-JS11` → mark deferred until `low_watermark > 1` / a `gc` record** exists (§2 YELLOW). Otherwise v1 authors can't generate the scenario.
5. **`$blob` FI-10 → explicitly apply `sanitize_payload`-class + MS secret-exclusion before write/sha256** (§2 YELLOW), and order sanitize-before-externalize.

**Fix-before-any-speculation-red (or pin the restriction):**
6. **speculation plural-`refs` → restrict to in-session parents; cross-metadata→lineage `:merge`; state the limitation** (§2 YELLOW).

**Recommended clarifications (YELLOW/NIT, non-blocking but currently under-specified):** A-I in §5 (decision enum, lineage edge shape, inline auto-approve predicate (+ F2 draft dependency), `bytes`/media semantics, idempotent-accept observability, `woken` vocab registration, record-lifecycle diagram, annotation authorization, parking-signal precedence).

Everything else, `branch_id`, the lineage relation enum, the fingerprint struct, `effect_class` taxonomy, `consent_class`, the `schedule`/`woken` tip-closure interaction, the low-watermark/resume/grandfather path, the append-before-publish × actor ordering, and the bulk of the new negative contours (N-JS8/9/10/12, N-U11.8/9/10), I'd **ratify**. The load-bearing decisions are sound and the dead injectors are real.

My read is the remaining load is concentrated in the envelope-field carry (writer × emitbridge × reader × live, multi-path) and the FI-10 secret-scrub coverage for `$blob`. Everything else is tight.
