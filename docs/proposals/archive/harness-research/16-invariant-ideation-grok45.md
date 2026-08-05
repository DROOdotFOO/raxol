I'll inspect the event/journal/session surfaces so the missing invariants are grounded in what actually exists, then attack the inventory for holes.## 1. Missing invariants

### A. Tier boundary / id authority
1. **Ephemeral never journals.** Generate mixed durable+ephemeral stream; assert `journal.records ∩ ephemeral_ids == ∅` and no journal line has `tier: :ephemeral`.
2. **Ephemeral id = last durable offset (or 0).** Generate D/E interleaved; assert each E.id ∈ {0} ∪ durable_ids_seen_so_far, and E.id == max(durable_ids_seen) when any durable exists.
3. **Durable id never 0.** Generate any durable sequence; assert `∀ d. d.id ≥ 1`.
4. **Append-fail leaves offset untouched.** Inject write error mid-sequence; assert next successful durable id == previous + 1 (no gap fabricated, no skip past the failed slot).
5. **Append-fail: zero live-tail durable, one error event.** Inject append error; assert live tail has no durable with that intended id, and exactly one durable-or-ephemeral `error`/`journal_write_failed` with stable shape.
6. **No fabricated id on any failure mode.** Enumerate {enospc, eio, crash-after-write-before-reply, crash-after-reply-before-publish}; assert live durable ids ⊆ journal ids always.

### B. Ordering / atomicity
7. **Journal-before-publish is observable.** Interleave observer at publish and reader of journal file; assert for every live durable id N, when live first sees N, `Reader` already returns a complete record with that id (no publish-ahead window).
8. **Append-ok / publish-fail: journal has it, reattach recovers.** Kill bus after append; reopen + attach(0); assert recovered set == journal set (at-least-once to disk, not silent live-only loss of truth).
9. **Session-local total order.** Concurrent producers into one session; assert live durable order == journal order == id order (no reorder under contention).
10. **Cross-session isolation.** Two sessions concurrent; assert no event of A appears in B's journal or live tail, and dirs never share writer pid.

### C. HEAD / crash / sync
11. **HEAD.offset ≤ max(journal.offset) always.** Crash-kill at random points (incl. mid-datasync, mid-HEAD-rename); reopen; assert HEAD never points past journal.
12. **Resume = max(HEAD, journal), never HEAD alone.** Force HEAD lag (kill after write, before HEAD rewrite); reopen; append; assert new ids continue from journal max, not HEAD (duplicate-id regression).
13. **HEAD/meta never contain model state.** Fuzz-write arbitrary events; assert HEAD/meta keys ⊆ allowlist (`offset`, config fields only); no `model`, `messages`, `tools`, etc.
14. **Atomic meta/HEAD: no half files.** Kill during atomic_write; assert surviving file is either old-valid JSON or new-valid JSON, never empty/partial/unparseable permanent path (tmp may exist; canonical path must not be torn).
15. **Immediate-sync types survive process kill.** Append `tool_result`/`approval`; kill BEAM without waiting 200ms; reopen; assert those records present (batched types may lag: side-effect types must not).
16. **Batched sync ceiling.** Generate non-immediate durables; assert dirty data is fsynced within ≤200ms of append (timer property / virtual clock).

### D. Segments / recovery beyond byte-cut
17. **Rotation continuity.** Force N rotations; assert ids strictly continuous across segment files; concatenation of segment records == full journal; no orphan segments without covering ids.
18. **Interior corruption: damaged, not truncated, not injected.** Corrupt a non-final line; assert `{:damaged, _}`, complete prefix returned, corrupt record excluded from fold input, no file deleted, alarm raised once.
19. **Missing middle segment.** Delete segment k of n; assert damage/hard error, not silent skip that fabricates continuity.
20. **No auto-delete path.** Fuzz retention APIs with dry-run off/on; assert only explicit GC command deletes; crash/damage/reopen never remove segments.

### E. Schema / contract beyond field names
21. **Payload schema only grows (deep).** Snapshot nested payload shapes per `type`; assert no required-field removal, no type-narrowing, no enum value removal (not just top-level Event keys).
22. **Upcast-on-read.** Fixture journals from schema v(n−k); open with current reader; assert all complete records upcast to current shape; fold succeeds; no silent drop.
23. **Writer-injected fields stable.** Assert writer always stamps `id`, `schema_version` deterministically; re-read equals stamped form (no re-key reorder that UI parsers treat as semantic).

### F. Session / process boundary
24. **session_id path safety.** Generate adversarial ids (`../`, `/abs`, unicode, empty, spaces); assert reject OR safe encode, never escape session root; concurrent open of alias paths maps to same writer or both fail closed.
25. **Writer death → single successor.** Kill writer under load; supervisor restart; assert exactly one writer; no dual-append interleave; bridge reattach does not spawn second writer.
26. **Bridge orphan adopt: no double-emit.** Crash bridge mid-tail; restart; assert journal not re-appended for already-journaled events (live may resend ephemerals; durables not duplicated in journal).

### G. Coming units (write now as failing/pending properties)
27. **Reattach gap/dup free.** Generate stream; attach at every offset o ∈ 0..max; assert `replay(0..o−1) ++ live_from(o) == full durable stream` as multisets and as sequences (no gap, no dup).
28. **Late subscriber monotonic catch-up.** Subscribe mid-stream; assert first live id ≥ requested from_offset; no earlier durable delivered as "live".
29. **Checkpoint pointer validity.** Generate checkpoint records; assert pointer offset exists in journal, payload file present iff required, and `fold(0..ptr) ⊕ snapshot == fold(0..now)` for model projection keys.
30. **Checkpoint not mid-reserve.** Interleave spend-gate reserve/commit with checkpoint; assert no checkpoint between reserve and terminal (commit/release); on restore, ledger reserved == journal reserved.
31. **Steer CAS.** Concurrent steer with `expected_turn_id ∈ {current, stale, nil}`; assert only current applied; stale produces reject event, zero model effect.
32. **Interrupt staged kill order.** Generate long-running shell turn + interrupt; assert event order ⊆ `signal → wait_expired? → os_group_kill → turn_completed|error` with no tool_result after kill-complete for that turn's port.
33. **Compaction reconstructibility.** Run until compact; assert post-compact session can answer from `{checkpoint, resume, events_after}` alone: raw pre-compact tail not required; projection classes ⊆ checkpoint payload.
34. **Approval gate fail-closed.** Write-tool call without approval; assert no Port/side-effect, durable `approval_required` present; after deny, no later success for that call_id.
35. **Spend-gate reserve-before-call.** Generate paid calls; assert journal order `reserve → call_started → (success|fail) → release/commit`; never call without prior reserve for same call_id.

### H. Causal / time
36. **Tool causality.** In a turn: every `tool_result.call_id` has prior `tool_call` with same id in same turn (or documented cross-turn only if explicit); no orphan results.
37. **ts non-decreasing per session for durable.** Generate; assert `ts_i ≤ ts_{i+1}` (or documented clock skew bound); never future > skew.
38. **Error events reference failed id/op, not invent success.** After any fail-closed path, no subsequent durable claims success for the failed op_id.

---

## 2. Underspecified holes in the 9

| # | Hole a green test can hide |
|---|----------------------------|
| **1** | "Byte-identical" after what stamping? Writer injects `id`/`schema_version`: equality must be post-stamp. JSON key order / float encoding / atom→string can drift while "equal" maps pass. Ephemeral accidentally journaled with same payload still "exists". |
| **2** | Only checks live durable ⊈ journal. Allows: append OK + silent no-publish; publish of durable-shaped ephemeral; error event missing; offset advanced on failed write if test only checks ids present not continuity. |
| **3** | Monotonic ≠ dense. Gaps OK? Reuse across *sessions* on same disk via path alias? HEAD-only resume can pass monotonic-on-live if journal re-read skipped. "Never reused" needs crash between write and HEAD. |
| **4** | Equality of *what*? Multiset vs sequence; drops ephemerals correctly but reorders durables; subscriber buffer coalescing; live includes bridge-only events filtered differently than journal filter. Generator without concurrent producers never stresses order. |
| **5** | "Caused by" undefined under async. If generator is single-threaded sequential turns, the known emit-time stamp bug never fires. Meta-family during turn T, and post-`turn_completed` trailers, undefined. Nil vs missing field. |
| **6** | "Modulo v0 deferral" is an unbounded exception. Without allowlisted deferred types + deadline (e.g. must close before next `turn_started`), property is vacuous. |
| **7** | Byte-cut of *one* healthy segment ≠: multi-segment; corrupt interior; corrupt HEAD; cut mid-UTF-8; empty file; zero-length segment after rotation; partial last segment after kill mid-write. "Never crashes" can pass while returning `[]` and dropping flushed prefix. |
| **8** | "Concurrent opens" ≠ crash-restart race, `:global` vs local name, two dirs hardlinked, bridge adopt + open race, or write interleaving under shared FD. Error shape (`:already_started`) vs silent second writer both need assertion. |
| **9** | Top-level field snapshot misses: payload keys, enum values, `family`/`tier`/`type` renames, required→optional flips that break UI, event type removal while field set grows. No fixture of *old* journals. |

**Shared generator hole:** without overlapping async turns, multi-segment rotation, disk-full, and crash-between-append-and-HEAD, properties 1-6 stay green on a hollow system.

---

## 3. Meta-invariants (trust the injector)

1. **Faults must fire.** Generate N runs with injector armed; assert fault-counter > 0 per scheduled site; **fail the suite if a named site never hit** (dead injector = green lies).
2. **Fault schedule is seed-reproducible.** Same seed ⇒ same fault sites/times; failure dumps seed + schedule.
3. **Each fail-closed path has a probe.** For sites {write, datasync, HEAD-rename, publish, bridge-cast}: assert post-fault observations match the branch (e.g. enospc ⇒ `{:error,:enospc}` reply + no offset bump), not just "system still runs".
4. **Negative control.** Mutate production to violate invariant I; assert property test for I fails within budget (one mutation per invariant, CI periodic).
5. **Coverage of deferred bugs.** Generator must include: delayed async results crossing `turn_completed`/`turn_started`; attach mid-stream; kill mid-immediate-sync type; dual open. Declare these as required trace patterns; fail if a 10k-run sample lacks them.
6. **Oracle independence.** Journal truth via raw file read + independent decoder, not the Writer's in-memory offset; live via subscriber process, not the publisher's return value.
7. **No shared clock cheats.** Virtual time for 200ms ceiling; real kill/SIGKILL for durability (timer advance ≠ fsync).
8. **Schema corpus.** Check in golden journals per schema version; upcast property runs on corpus every CI, not only generated current-version events.

---

## 4. Top 3 payoff

1. **#6 + #7 + #12 combined: id authority under failure/crash**  
   `append-fail / crash-between-write-and-HEAD / resume max(HEAD,journal)`: catches fabricated ids, duplicate ids, HEAD lag: the class that corrupts reattach forever.  
   *Property:* inject {write fail, kill after write before HEAD, kill after HEAD before publish}; reopen; assert live_durable_ids == journal_ids == 1..n dense, HEAD ≤ n.

2. **#27 reattach gap/dup-free at every offset**  
   Locks the contract the UI fork depends on; forces journal-before-publish and stable offsets before U4 lands. Retroactive cost if deferred.  
   *Property:* generate sequence; ∀ o: `read(0..o-1) ++ attach_live(o..) == full durable sequence`.

3. **#2 ephemeral/durable wall + ephemeral id = last durable**  
   Stops the silent poison: ephemerals in journal, durables with live-only ids, UI folding deltas as truth. Cheap, permanent, underpins checkpoints/compaction.  
   *Property:* mixed stream; journal all durable-only; every ephemeral id == last durable offset (or 0); tier field never lies.

**Honorable 4th when gates land:** #35 reserve-before-call + #30 checkpoint≠mid-reserve: money/safety bugs that tests 1-9 never see.
