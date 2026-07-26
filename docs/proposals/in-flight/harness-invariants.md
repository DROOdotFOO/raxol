# Harness Invariant Suite — the permanent guards

Purpose: not "is today's behavior correct" but "these properties can never be
accidentally broken by a future refactor." Born from the review-round
convergence (three independent reviewers, same defects, all in untested
failure arms) + grok-4.5 ideation (`harness-research/16-invariant-ideation-grok45.md`,
full 38-item list + holes analysis there).

Suite home: `packages/raxol_agent/test/invariants/` (property-based, StreamData),
with a **fault-injection journal harness**. Every property runs under healthy
AND failing storage. Future units append their invariants here as they land —
the suite is the contract's immune system.

## Tier 1 — build now (with U1.5 in the tree)

**I1. Id authority under failure/crash** (grok top-1; the dual-id class)
Inject {append-fail, kill-after-write-before-HEAD, kill-after-HEAD-before-publish};
reopen; assert `live_durable_ids == journal_ids == 1..n` dense, `HEAD ≤ n`.
Catches fabricated ids, duplicate ids, HEAD lag — the class that corrupts
reattach forever.

**I2. Ephemeral/durable wall** (grok top-3)
Mixed stream: journal contains durable-only (no line with `tier: :ephemeral`);
every ephemeral id ∈ {0} ∪ {last durable offset}; durable ids ≥ 1; tier field
never lies. Byte-identity of journal record vs live event compared **post-stamp**
(writer injects id/schema_version) — not loose map equality.

**I3. Journal-before-publish observability**
For every live durable id N: at the moment live first sees N, an independent
raw-file read already returns a complete record with that id. No publish-ahead
window.

**I4. Turn attribution under async overlap** (Drew's finding, generalized)
Generate overlapping async turns (delayed command results crossing
`turn_started`/`turn_completed`): every event carries nil or its ORIGINATING
turn's id, never a neighbor's. Generator MUST include the async-crossing
pattern — single-threaded sequential turns make this property vacuous.
(@tag-skipped against the contamination issue until the snapshot fix lands;
visible, not hidden.)

**I5. Recovery beyond byte-cut**
Truncation fuzz at every byte position PLUS: multi-segment, corrupt interior,
corrupt HEAD, cut mid-UTF-8, empty file, zero-length segment after rotation.
Assert: never crashes, never loses a complete record, never fabricates one,
torn-vs-flushed-corrupt distinction preserved, `[]`-with-silent-prefix-drop is
a FAILURE (the "never crashes but returns nothing" hole).

**I6. Rotation continuity + no-delete**
Force N rotations: ids strictly continuous across segments; concat(segments) ==
journal. Missing middle segment → damaged, not silent skip. No code path except
explicit GC deletes a file — crash/damage/reopen never remove segments.

**I7. Single-writer + successor**
Concurrent opens → one writer (joiner semantics). Kill writer under load →
exactly one successor, no dual-append interleave, no duplicate journal appends
after bridge orphan-adopt.

**I8. HEAD/meta discipline**
`HEAD.offset ≤ max(journal)` always (crash-kill at random points incl.
mid-rename). Resume = `max(HEAD, journal)`, never HEAD alone. HEAD/meta keys ⊆
allowlist — no model state, ever. Kill during atomic_write → canonical path is
old-valid or new-valid JSON, never torn.

**I9. Contract only grows — deep**
Snapshot per-`type` nested payload shapes, enum values, field requiredness —
not just top-level Event keys. Fail on: removal, rename, type-narrowing,
required→optional flip, event-type removal. Golden journal fixtures per schema
version checked in; upcast property runs on the corpus every CI.

**I10. Immediate-sync durability**
`tool_result`/`approval` appended → BEAM killed without waiting 200ms → present
after reopen. Real kill, not timer advance (fsync can't be virtual-clocked).

## Tier 2 — write now as @tag-pending, activate with their units

- **U4 reattach:** ∀ offset o: `read(0..o−1) ++ attach_live(o..) == full durable
  stream` — as sequence, not multiset. Late subscriber never gets an earlier
  durable delivered as "live". (grok top-2 — locks the UI-fork contract; write
  before U4 lands, retroactive cost otherwise.)
- **U5 interrupt:** event order ⊆ signal → wait → os_group_kill →
  turn_completed|error; no tool_result after kill-complete for that turn's port.
- **U6 steer CAS:** stale `expected_turn_id` → reject event, zero model effect.
- **U9 checkpoint:** pointer offset exists; `fold(0..ptr) ⊕ snapshot ==
  fold(0..now)`; never checkpoint between spend-gate reserve and terminal.
- **U7/U8 gates:** journal order `reserve → call_started → outcome →
  release/commit`, never a call without prior reserve (same call_id); write-tool
  without approval → no Port opened, `approval_required` durable present; after
  deny, no later success for that call_id.
- **Causality:** every `tool_result.call_id` has a prior `tool_call` same-turn;
  after any fail-closed path, no subsequent durable claims success for the
  failed op_id.

## Meta-invariants — the harness must prove itself (grok §3, all adopted)

1. **Dead-injector detection:** every named fault site keeps a counter; suite
   FAILS if a site never fired. A dead injector = green lies.
2. **Seed-reproducible fault schedules;** failures dump seed + schedule.
3. **Branch probes:** each fail-closed path asserts its specific observable
   (enospc → `{:error, :enospc}` reply + no offset bump), not "system still runs".
4. **Negative controls:** one mutation per invariant (violate I in production
   code) → its property must fail within budget. Periodic CI job, not every run.
5. **Required trace patterns:** generator must produce {async-crossing turns,
   attach mid-stream, kill mid-immediate-sync, dual open} — fail if a 10k-run
   sample lacks any.
6. **Oracle independence:** journal truth = raw file read + independent decoder,
   never the Writer's in-memory offset; live truth = subscriber process, never
   the publisher's return value.
7. **No clock cheats:** virtual time for the 200ms ceiling; real SIGKILL for
   durability.

## Holes the original 9 had (why this doc exists)

Full table in brief 16 §2. The shared hole: **without overlapping async turns,
multi-segment rotation, disk-full, and crash-between-append-and-HEAD in the
generator, all core properties stay green on a hollow system.** The generator
IS the suite; the assertions are secondary.
