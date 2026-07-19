# Adversarial Audit: `harness-freeze-contracts.md`

Scope verified against landed code: `Contract.Event` (contract.ex:48-56), `EmitBridge` (emit_bridge.ex:200-218, 302-309), `Writer` (writer.ex:111-135, 159-162, 244), `Reader` (reader.ex:45-51, 143-152), and `Ledger` (ledger.ex:86-96, 30-35). The freeze lands on code that has **no** `kind`, **no** `scope`/`provenance`, and a kind-agnostic Reader — confirming the claims of "zero Reader changes" and "renames nothing."

## Finding Summary

| # | Severity | Area | Issue |
|---|----------|------|-------|
| F1 | **YELLOW** (load-bearing) | U11 `refs` | Offsets-only is sound *only* with a session-scoping contract; the cardinal-sin boundary |
| F2 | **YELLOW** | U11 `scope` | 2-value closed enum NOT in the §2.4 grow list — a 3rd scope forces repurpose |
| F3 | **YELLOW** | §2 cardinal-sin | `approval_requested ∈ CONVERSATIONAL` vs "every family:meta excluded" |
| F4 | NIT | U12 budget | Reserve/settle two-phase has no frozen settlement primitive or reservation id |
| F5 | **YELLOW** | U12 budget | "Never drop + never fail submit" + no resume + no max ⇒ unbounded parked-run accumulation |
| F6 | **YELLOW** | JS-FREEZE | `Reader.last_offset` semantics shifted last-event → last-record (NIT, but annotate) |
| F7 | **YELLOW** | Dual-id | Offset law holds IF checkpoints route through single Writer; enforcement is faith/tests not types |
| F8 | NIT | JS-FREEZE U10 term | U10 structured compaction term has no reserved field (additive, but un-State) |
| F9 | **YELLOW** | Contour rule | 7 named positives lack a negative contour + dead-injector (violates the doc's own rule) |

---

## 1. THE CARDINAL SIN — forward-compat

I pressure-tested every frozen field against U10 compaction, U14 multi-track, U19 fluid ontology, U20 promote. **Good news first: the freeze is genuinely well-architected to avoid renames.** It uses optional-with-default new fields, grow-only registries, whitelist tip-set, and pointer-only snapshot ownership. I found **no field that is *forced* to rename.** But three fields sit exactly on the cardinal-sin boundary — the governing law holds only if a load-bearing assumption holds. Most load-bearing first.

### F1 · YELLOW — `refs` (offsets-only) is the cardinal-sin boundary §2.1, OQ-U11.1
`refs` is frozen as `[non_neg_integer()]` (offsets-only, session-relative). The fold in §2.1 bullet 5 ("if any event named in `refs` is tainted, the meta event MUST be tainted") and the promote rule (P-U11.4: refs resolve to an existing journal record) are **sound only if every journal event's refs resolve against its own session** — because a journal is session-scoped and an offset is meaningless cross-session.

The pressure: U20 promote "crosses sessions." The freeze itself (OQ-U11.1) flags it. The danger is a unit that needs *in-journal* cross-session refs — that would force `refs` from `[integer]` to `[{session_id, integer}]`, repurposing a frozen field and breaking every decoder.

**Verdict:** No forced rename today, but this is the load-bearing commitment. Ruling (OQ-U11.1 below): offsets-only is defensible **only if** you lock the contract *"refs are resolved against the enclosing record's session_id; cross-session references belong to the consuming store (global store / ADR), never to the journal event."* Cross that line and you recapture the cardinal sin.

### F2 · YELLOW — `scope` not in the §2.4 grow list §2.4 lines 403-409
The forward-compat section lists what grows: meta types, provenance sources, provenance keys, trust lattice points, `probe_run` statuses. **It omits `scope`**, leaving it a closed `{:session, :global}` enum. U20 is "local/global" (two values, fine), but if any future unit needs an intermediate scope (`:workspace`, `:project`, `:team`, `:shared`, …) it must repurpose `scope` — the cardinal sin. Note U8 already uses three *approval* scopes (`:once/:session/:root`, policy.ex:36), proving the product thinks in ≥3	scope bands; the meta *event* scope should not be pointlessly capped at two.

**Fix:** either add `scope` to the §2.4 grow list (readers render unknown scopes opaquely) or explicitly document it as a closed 2-value enum and accept the limitation. The grow-list option is strictly safer.

### F3 · YELLOW — `approval_requested` family is unspecified §1.1 lines 157-167
`approval_requested` is in `CONVERSATIONAL`, but `conversational?` requires `record.family == "loop"`, while the separate exclusion list also says *"every family:meta event"* is excluded. These only cohere if `approval_requested` is **family:loop**. But it's emitted by `BlastRadiusGate` (U8) — code that reads as meta-family. The assert "a pending approval is exactly where a resumed conversation must land" actually *decides* that `approval_requested` must be family:loop and not family:meta. That decision is correct but **currently implicit**, so a U8 author and a U4/U9 author can diverge.

**Fix:** state explicitly under the CONVERSATIONAL definition: *"`approval_requested` is emitted family:loop (a turn-bracket signal), never family:meta, so it passes the tip predicate."*

### (No true RED.) 
The freeze's deliberate choices — additive fields, grow-only registries, the frozen tip *whitelist* (new loop event types default to non-conversational, so they can never accidentally become the tip), and "JS-FREEZE owns only the pointer discipline, MS owns snapshot content" (sidesteps the U10 structured-term-vs-model-slice tension by leaving content opaque) — are exactly the right architecture to avoid forced renames. F1/F2 are the places to watch.

---

## 2. DUAL-ID LANDMINE REINCARNATION §1.1 lines 74-87

**Claim:** "One offset law — every record consumes exactly one offset; Event.id = journal offset stays intact."

**Verified TRUE against landed code, conditional on one routing assumption.**

Landed mechanics (no Freeze changes needed to the Reader at all):
- `Writer.append` (writer.ex:111-135): `offset = state.offset + 1` for **every** append, `{:reply, {:ok, offset}, ...}`. The Writer is kind-agnostic; it never looks at `kind`. So if checkpoints route through `Writer.append` (single counter), they consume exactly one offset. ✓
- `Reader.continuous?` (reader.ex:143-152): checks `id == prev + 1` for all records regardless of kind. A checkpoint at offset N followed by an event at N+1 is continuous. ✓ *No Reader change required.*
- `resume_offset` (writer.ex:244): `max(head_offset, Reader.last_offset)`. Both `HEAD.offset` (writer.ex:263-266, written every flush) and `last_offset` (reader.ex:45-51) advance on every append including a checkpoint, because both derive from the same `id` counter. The `max` exactly absorbs a crash-between-append-and-HEAD. ✓
- `Event.id = offset` (emit_bridge.ex:210-217 sets `id=offset` for durable, `id=last_offset` for ephemeral). With checkpoints, ephemeral id = last *record* offset (possibly a checkpoint) — which the freeze explicitly redefines as correct ("a checkpoint append advances that watermark," §1.1 line 85). The landed `EmitBridge.last_offset/1` (emit_bridge.ex:302-309) already does `FileStore.read |> List.last() |> record_id` and needs no change. ✓

**Is there a read path that now sees a checkpoint where it expects an event?** Two marginal cases, neither fatal:
1. `Journal.read/2` default returns **all** kinds (file_store.ex:113-121, filter only handles `:from_offset`; the new `:kinds` opt is additive). A typed fold that assumes every record has `family/type/payload` will choke on a checkpoint record (fields `tip_offset`/`snapshot_ref`). **Mitigated** by the freeze's tolerance rules (typed folds filter kind) + P-JS6/N-JS4. But it's a foot-gun on the default read — see F9.

2. **F6 · YELLOW:** `Reader.last_offset` (reader.ex:45-51) semantically shifts from "last event offset" to "last record of any kind." Only `EmitBridge.last_offset/1` consumes it, and it's correct there. But the name/documentation is now misleading; any new consumer interpreting it as "last event offset" will misread a trailing checkpoint. **Fix:** add `last_event_offset` (filters kind=="event") alongside, or annotate `last_offset` as last-record.

**F7 · YELLOW — enforcement is by test, not by type.** The offset law holds *only if* U9 routes checkpoints through the single `Writer.append`. The Writer's `stamp` trusts the producer's `kind` (writer.ex:159-162) — it cannot enforce "all kinds go through me." The only guard is the negative contour **N-JS6** (a Writer stamping from a second counter fails P-JS1). That's correct and necessary, but it's a runtime test, not a compile-time guarantee. **Fix (optional hardening):** reject in `Writer.append` any record whose `id` is already set/`kind` passed without a Writer-side provenance, OR document N-JS6 as the load-bearing lockstep test and add a fired-counter (meta-inv 1) so a silent bypass fails CI. The freeze's "one offset law" is settled doctrine; just make the enforcement visible.

---

## 3. FALSE-PARALLEL RESIDUE (U4-R ∥ U9-R) §1.1 lines 152-168

**The freeze dissolves the false parallel** by making `conversational?` a single frozen predicate that both U4 (locate tip) and U9 (validate `tip_offset`) quote. Two independent authors writing U4-R and U9-R can't diverge *as long as they implement the frozen predicate literally* — the contract is the oracle. This is the right design.

**Residual risks:**

**(a) The exclusion set IS complete by construction — but relies on the whitelist being right.** Because `conversational?` is a *positive whitelist* (`type ∈ CONVERSATIONAL`), any future loop event type defaults to **non-conversational** and is never selected as tip unless explicitly added to `CONVERSATIONAL` (grow-only). So a future loop event can't accidentally become a tip. This is robust. The "excluded: state_change/idle/meta/checkpoint" are just the *obvious* negative cases; the real completeness guarantee is the whitelist.

**Genuine divergence vectors:**
- **item_started (OQ-JS3):** listed in `CONVERSATIONAL` but not yet in EmitBridge's mapping (contract.ex). A U9-R author writing a checkpoint after an `item_started` and a U4-R author who hasn't wired it would produce mismatched tip offsets *only if one adds it to CONVERSATIONAL and the other doesn't.* Since `CONVERSATIONAL` is a frozen constant (not per-author), this is safe once OQ-JS3 is ruled. **Ruling (OQ-JS3 below): include it** — it's in protocol §3 and grow-only; leaving it out is the divergence risk.
- **approval_requested (F3):** the family ambiguity is the single real U4/U9/U8 divergence point — fixed as in F3.
- **Future record kinds:** A non-event kind the Reader doesn't know about is excluded from the tip by the `kind == "event"` clause and preserved by tolerance (§1.1 lines 180-186). U4-R's backward scan "skips unknown kinds." ✓ The tip predicate requires literal `"event"`, `family "loop"`, and `type ∈ CONVERSATIONAL` — all three must hold, so a novel kind can never leak into the tip. Robust.

**Dormammu (N-JS5) is correctly wired:** the injected predicate drops the family/type clauses, so a trailing checkpoint/idle/meta gets selected and the red fails — proving the whitelist clauses are load-bearing. ✓

---

## 4. CONTOUR COMPLETENESS

The doc's rule (meta-inv, applied via §1.2): *every red needs a positive contour (must-hold) AND a negative contour (must-fail + named dead-injector).* Violations below are **positives with no matching negative/contour break**, which would make the associated red vacuous:

| Freeze | Positive contour with NO named negative | Should break via |
|--------|----------------------------------------|------------------|
| JS-FREEZE | **P-JS2** tip determinism (line 201, oracle independence) | no injector |
| JS-FREEZE | **P-JS5** replay closure U4 (line 214) | no injector |
| JS-FREEZE | **P-JS7** grandfather (line 222) | no injector |
| U11-CONTRACT | **P-U11.1** codec round-trip (line 371) | no injector |
| U11-CONTRACT | **P-U11.2** grandfather decode (line 373) | no injector |
| U11-CONTRACT | **P-U11.5** fold independence (line 382) | no injector |
| U12-CONTRACT | **P-U12.1** lifecycle completeness (line 561) | no direct injector (N-U12.4 covers max_calls, not the started→terminal count) |
| U12-CONTRACT | **P-U12.6** output atomicity (line 575) | no injector (N-U12.1 is family-violation; no "emitted k of n, then failed" injector) |

The negatives (N-JS1…N-JS6, N-U11.1…N-U11.6, N-U12.1…N-U12.7) **all** have named dead-injectors — that side is done well. The imbalance is on the positive side.

**F9 · YELLOW — contour rule violated on 8 positives.** To satisfy the doc's own standard, either (a) drop these to "properties, not reds" (they're still tested, just not as must-fail reds), or (b) add the missing negative contours:
- **P-JS5:** a negative where emit-ahead-of-journal (I13) is injected — a live id surfaces before its record is readable; replay closure red fails.
- **P-U11.5:** a meta event injected into the journal that perturbs a loop fold; equality red fails.
- **P-U12.6:** a Runner that emits the first `k` drafted events then hits exhaustion; atomicity red asserts zero emitted.

Note P-JS7 (grandfather) and P-U11.2 are pure decode properties — testing "old journals still decode" doesn't have a natural must-fail; mark them decode corpus tests rather than reds.

---

## 5. THE 9 OPEN QUESTIONS — RULINGS

**OQ-JS1 — tip-only checkpoint (`snapshot_ref: nil`) legal in v1?** → **YES, legal.** `snapshot_ref` is optional-with-default (nil) and the governing law forbids optional→required, so tip-only is *permanently* legal regardless. U9 can prefer full snapshots; U10 will never need to flip this field. The restore-from-tip-only red simply `(0..tip_offset)` full fold — validate that path instead of nil-reject. ✓

**OQ-JS2 — defer GC or spec the `gc` record now?** → **Defer entirely.** GC policy (retention N, explicit consent per FI-7) is a product decision not derivable from invariants; baking it now risks the "only grows" rule locking in a wrong retention semantics. The `gc` kind is already reserved (line 109-111), so a future unit adds it with zero changes to this freeze. ✓

**OQ-JS3 — `item_started` in CONVERSATIONAL day one?** → **YES, include.** It's in protocol §3; grow-only set; removing it later would *silently move historical tips* (the §1.4 warning). Leaving it out is exactly the U4/U9 divergence vector flagged in §3. Include it; EmitBridge wires the emit-or. ✓

**OQ-U11.1 — `refs` offsets-only vs `{session_id, offset}`?** → **offsets-only, WITH a frozen session-scoping contract.** Every journal event (loop or meta) lives in a session-scoped journal, so its refs resolve within that session — this holds for U11-U18 AND U20, because the *promote journal event* is written in the **source** session and its refs name source-session records; cross-session qualification is the **global store/ADR's** job, not the journal's. (F1 is the proof that the assumption is load-bearing — forbid in-journal cross-session refs *forever* or you repurpose `refs`.) Document: "refs are interpreted relative to the enclosing record.id's session_id; cross-session references are a consuming-store concern." ✓

**OQ-U11.2 — one `:surface` or per-surface atoms?** → **per-surface atoms** (`:surface_tui`, `:surface_cli`, …), grow-only registry. One atom collapses distinct trust/audit origins (an interactive TUI keystroke vs an automated CLI pipe) into one label, forcing a later split (rename pressure) and weakening blast-radius/audit fidelity. Grow-only absorbs new surfaces. Affects one red (U4 attach-audit, best-effort). ✓

**OQ-U11.3 — taint fold = hard validate-on-replay reject (FI-9) or alarm?** → **Alarm (+ in-marker), NOT a hard reject.** A hard validate-on-replay would retroactively corrupt historical journals on any taint miscount (violates the Reader's "never mark damaged on semantic grounds" contract, reader.ex:182-190) and makes taint a decode-time gate — but taint is a *policy opinion* that tool metadata can rejudge. Keep replay tolerance intact; emit telemetry + fold a `:taint_violation` marker so the fold property (P-U11.3) is observable. "No laundering stays a pure journal fold. ✓

**OQ-U12.1 — per-run only, or per-run ⊂ per-session probe budget?** → **Two-level: per-run nested inside a per-session probe budget.** Per-run-only lets a single session spawn unbounded probes (no session cap) — contradicts "runaway impossible" (U16) and leaves the per-session economy undefined. The Runner reserves against a `budget_scope` that is itself scoped by a session budget; exhaustion of *either* parks. Discipline: **always reserve session-then-run in that fixed order** to avoid ordering hazards (Ledger.try_spend is non-blocking/returns over_limit, so no classic deadlock, but ordering keeps it deadlock-free under the two-level wrap). ✓

**OQ-U12.2 — `:standalone` in first red wave or @tag-pending until U17?** → **Interface frozen (additive, zero risk); reds @tag-pending until U17.** C6 cross-family is the only `:standalone` consumer and it's Wave 4. A standalone red now would have no implementation surface to validate against and would drag in a CROSS_FAMILY test harness. Freeze the shape, defer the reds. ✓

**OQ-U12.3 — `probe_run.refs` = tip-at-submit only, or full read-set?** → **Full read-set (every offset the context actually included).** Taint-meet (P-U12.5) precision depends on knowing exactly which records fed the derived events; tip-only `refs` would let a derived event *read tainted content but claim a clean tip-only lineage*, breaking the algebra. Auditable > cheap. The read-set is a pure output of `build/1`, easy to capture. ✓

---

## 6. TAINT LATTICE (U11) §2.1 lines 339-359

**Is two-point (clean/tainted) sufficient?** → **Yes, for all planned units (U11-U20, S3).**
- Absorption (`tainted iff ∃ tainted-input`) + no-upgrade makes taint a monotonic one-way stain. C3 (U15) "reduces volume not taint" — two-point handles it: filtered output stays tainted, volume drops, marker persists (Willison boundary). ✓
- U20 store promotion: promote carries refs and inherits taint via the algebra; a tainted source stays tainted in the global store. ✓
- **What breaks two-point:** only a hypothetical "partially trustworthy" grade (e.g., "sanity-sanitized but not fully trusted") would need a 3rd label. No such unit exists. The freeze's escape hatch (§2.4: new trust lattice points are additive, readers fail-closed to `:tainted` on unknown) is exactly right. **Cost acknowledged:** monotone-over-absorption can *over*-taint aggressively (any tainted mention in lineage taints the whole subtree), hurting usability, but that's a product/calibration concern (U18) — not a contract or correctness blocker. NIT worth flagging: the steep taint accumulation should be on the U18 servo's radar.

**Is "no laundering checkable as a pure journal fold" sound?** → **Yes, in the upgrade-prohibition direction.** The checkable property (§2.1 bullet 5): for every meta event `m` with `trust == :tainted`, assert NOT (all refs clean AND producer input clean); equivalently, the *forward* invariant "a `:trusted` event has all-clean refs and clean producer input" is a pure fold over `refs`. That exactly catches a laundering (upgrade) step. The reverse (detecting *spurious* taint) needs producer-side audit, which is U8's job, not the journal's. Sound as claimed. ✓

---

## 7. U12 CACHE-RIDING + BUDGET §3.1 lines 537-534

**Is "byte-identical prefix, provider-free testable" sound?** → **Sound as a frozen *Runner-correctness* observable, but it does NOT guarantee an actual provider cache hit.** Byte-identity of the messages array is *necessary* for a KV/prompt cache hit and is fully testable with no provider: capture the primary's built request and the probe's built request, assert the prefix slice is byte-equal (including whitespace, key order, reasoning/continuity tokens — all fixed by the byte-compare). This freezes the Runner's contract correctly. What it does **not** bound is the *provider's* cache key — the provider may key on model id, cache_control breakpoint position, message-count parity, etc., none of which the Runner controls. So byte-identical-prefix is a valid, provider-free RED, but "we got a cache hit" is a runtime/economic signal, **not** a contract.

**NIT F4 (terminology):** split the freeze's "cache-riding" into (a) the frozen testable invariant (byte-identical prefix) and (b) the runtime economic signal (`charge.cached_prompt_tokens > 0`). Otherwise a red can be green while real cache-hitting silently underperforms. Also AD-5 (never filter content blocks) must apply to the prefix builder — whitespace/reordering/filtering = P-U12.3 divergence. N-U12.5 (1-byte divergence) covers this. ✓

**Budget "reserve-before-call / exhaustion parks (never drops, never fails submit)":**

**F4 · YELLOW — the reserve/settle two-phase has no frozen settlement primitive.** The charge shape (§3.1 lines 517-522) reports consumed tokens (`prompt_tokens`, `cached_prompt_tokens`, `completion_tokens`, `calls`) but has **no reservation id**, and the runner interface (`submit/kill/status`, §3.1 lines 473-494) exposes **no settle/release primitive.** Yet the budget story requires "reserve `estimate` before call, *settle actuals after*" — which means a refund of `estimate − actual`. That refund must exist, but it's invisible in the frozen interface. There may also be a hint of a real ledger merge needed with `release_by_intent`-style reservation tags; the freeze is silent. **Fix:** clarify that settlement/refund is an internal Runner↔Ledger step (not part of the probe interface), and that `charge` is the post-settlement authoritative report — OR add a `reservation_id`/`settle` primitive. Without this, "reserve-before-call / settle-after" can't be unit-tested against the frozen shapes.

**F5 · YELLOW — unbounded parked-run accumulation ("never drop, never fail submit").** If submit-time reserve is refused, the run is parked (`:parked`) and `submit` returns `{:ok, run_id}` with no provider call (N-U12.3, N-U12.2 guards). Correct so far. **But:** (a) there is **no frozen resume signal** from `:parked` — a parked run waits on a budget state change the contract never surfaces; (b) there is **no max-parked cap** and parked runs are **never dropped**, so sustained exhaustion → unbounded parked-run accumulation (pid/state growth, no bound). Combined, "never drop + never block submit" silently turns the probe pool into a boundless queue under budget pressure — a real failure mode.

**Fix (choose one, document it):**
1. **Cap parked runs** + a `park_timeout_ms` spec key (parked beyond TTL → `:exhausted` terminal), OR
2. Make the caller (loop) own a bounded submit and translate submit-overflow locally, OR
3. Freeze a `resume(run_id)` primitive so freed budget can wake parked runs.

I recommend **(1)** — add `park_timeout_ms` to `spec()` and a `max_parked` pool param, and add a negative contour: pump submit past the cap and assert the cap holds (the parked set stops growing) and a parked run past TTL terminates `:exhausted`. N-U12.3's "never drops silently" red should still pass (it asserts submit returns ok + parked + zero provider call), but it must be *additive* to a cap, not a denial of one.

---

## VERDICT

**Not safe to author reds against as-is.** The freeze's forward-compat architecture is sound and no field is *forced* to rename, but **three fix-before-red** items are load-bearing:

1. **F3/F1** — ratify the two implicit decisions: `approval_requested` is family:loop, and `refs` carry a *session-scoping contract* (offsets-only, cross-session refs live in the consuming store, never the journal). Without U4/U9/U8 and U20 will silently break.
2. **F5** — bound parked runs (cap + `park_timeout_ms`) or the "never drop" rule becomes an unbounded-queue failure mode under exhaustion.
3. **F9 / OQ-JS3** — include `item_started` in CONVERSATIONAL and close the 8 positive-without-negative contour gaps (at least P-JS5, P-U11.5, P-U12.6) so no red is authored vacuous.

The other findings (F2 scope-grow list, F4 settlement primitive, F6 `last_offset` annotation, continuous? single-Writer assumption) are **ratify-before-impl** (U8/U9/U11) not blockers for red — but fix them now or U9/U11/U12 will inherit them as bugs. The dual-id and offset-law claims (§2) landed true; the false parallel (§3) is genuinely dissolved at the contract layer; the taint lattice (§6) is sound.
