# ADR-0030: ACP session/update delivery ordering contract

## Status

Proposed, 2026-07-18. Raised from three consecutive review rounds on PR #640
(`fix(acp): single-sender session/update delivery`). No code has landed on master;
this ADR exists to settle the contract before a fourth patch round.

## Context

The ACP client delivers `session/update` notifications to a user-supplied handler
(`on_update`) as an agent turn streams. Two properties are required at once:

- **In-order**: updates reach the handler in the order the agent produced them.
- **No-drop**: no update is silently discarded.

Plus a third, softer requirement the streaming API implies:

- **Live/incremental**: `on_update` fires per chunk as the turn runs (O(1) memory),
  not once at the terminal result (O(turn) memory).

PR #640 has attempted this three times. Each round fixed the prior round's headline
finding and **relocated the no-drop + in-order guarantee onto a new mechanism with a
fresh hole**:

| Round | Commit | Mechanism | Fixed | New hole (verdict) |
|---|---|---|---|---|
| 1 | `732070c2` | Synchronous dispatch on the single-sender Connection loop | order + no-drop | Ran user handler code on the shared loop -> cross-session head-of-line blocking, silent reentrancy death, flood-shed-valve bypass (BLOCK) |
| 2 | `94c47a32` | Async dispatch restored; client-side `rx_seq` reordering | the 3 loop problems | `prompt_stream/4` buffered the whole turn and replayed at the result (streaming lost, O(turn)); `@update_settle_ms 25` timing-based drop bound; unbounded client reorder buffer (CONCERNS) |
| 3 | `d70c0dfd` | Per-session `update_seq`; live incremental restored | the streaming regression | `update_seq` is **peer-supplied and unvalidated** (`extract_update_seq/1` takes any non-neg integer from the peer's `_meta`): a reused ordinal silently overwrites the buffered update (`Map.put`), a stuck counter (agent always stamps 0) delivers only the first update and drops the rest with no telemetry, a withheld low ordinal parks an unbounded per-turn buffer, and the per-turn reset-to-0 aliases cross-turn stragglers (CONCERNS) |

### The root cause

Each round is a local patch. The pattern underneath is a design decision that has
never been made explicitly: **what assigns the ordering key, and is that assigner
inside or outside the trust boundary?**

Round 3 lands on the worst answer: the ordering key is chosen by the **peer** — the
untrusted counterparty on the other end of the ACP connection. A no-drop + in-order
guarantee whose correctness depends on a value the counterparty supplies is not a
guarantee. A buggy peer that never increments its counter, or a malicious peer that
replays an ordinal or withholds a low one, defeats it directly. No amount of
client-side buffer logic can restore the guarantee while the key stays peer-controlled.

This is the same class of problem ADR-0013 (event-dispatch backpressure) already
solved for the terminal hot path: unbounded, unobservable, timing-dependent dispatch,
replaced with a bounded, telemetry-emitting, deterministic-under-overload policy. The
ACP delivery path should adopt the same shape rather than reinvent it a fourth time.

## Decision

Establish the delivery-ordering contract for ACP `session/update`. Any implementation
that lands must satisfy all five clauses.

1. **Receiver-assigned ordering key.** The ordering key is assigned at the receiver's
   trust boundary (server-side arrival order for the single-sender Connection, or a
   receiver-stamped monotonic per-session counter), never read from peer `_meta`. The
   peer's `_meta` may be surfaced to the handler as data, but must not be load-bearing
   for delivery order or drop decisions.

2. **Bounded reorder buffer with explicit drop-with-telemetry.** The reorder buffer
   has a watermark. Crossing it triggers a declared policy (deliver-with-gap-marker or
   fail-the-turn), and emits `:telemetry` — never a silent drop, never an unbounded
   park. Mirror ADR-0013's `[:raxol, :*, :backpressure]`-style event so the drop rate
   is observable.

3. **Bounded gap resolution.** A missing ordinal is waited on for a bounded interval,
   then resolved deterministically (deliver the buffered tail plus a gap-telemetry
   event, or fail the turn) — not parked indefinitely. If a settle window is used, its
   guarantee must be gap-based, not wall-clock-based, so scheduler starvation cannot
   silently convert a late update into a dropped one.

4. **Streaming preserved.** `on_update` fires incrementally per contiguous update
   (O(1) steady-state memory). A test pins that the handler observes chunks live during
   the turn, not only at `:acp_result`.

5. **Cross-turn monotonicity.** Ordinals are namespaced per turn (or never reset within
   a session) so a straggler from turn N cannot be aliased into turn N+1's ordering.

### Invariants to pin with tests

- **Order**: for any interleaving of receiver-stamped updates, the handler observes them
  in stamped order (property test, mirroring `test/property/backpressure_ordering_test.exs`).
- **No silent drop**: every update either reaches the handler or produces exactly one
  drop/gap telemetry event; the count of (delivered + dropped) equals the count sent.
- **Bounded memory**: buffer size never exceeds the watermark; a never-filled gap
  resolves within the bounded interval rather than growing the buffer.
- **Peer cannot wedge delivery**: a peer that replays, withholds, or freezes its
  `_meta` sequence cannot cause an unbounded buffer, a silent drop, or out-of-order
  delivery (adversarial test with a hostile peer stub).
- **Live streaming**: handler receives >1 update before the terminal result for a
  multi-chunk turn.

## Alternatives considered

- **Keep patching round-by-round.** Rejected: three rounds have each moved the hole,
  not closed it; the fourth would too, because the trust-boundary decision is unmade.
- **Trust the peer's `_meta` seq but validate monotonicity.** Rejected: validation can
  detect a bad sequence but cannot reconstruct the intended order from an untrusted
  source, so it degrades to "fail the turn" — which is clause 2/3 anyway, minus the
  false sense that the peer key is authoritative.
- **Drop the no-drop guarantee; best-effort delivery.** Viable and simpler, but it is a
  product decision, not a silent side effect of a buffer bug. If chosen, it must be
  stated in the API docs, and the streaming test still applies.

## Consequences

The ACP delivery path gains a stated contract and an observable, bounded, peer-hostile
implementation, converging with ADR-0013 rather than diverging from it. PR #640's
remaining findings (peer-controlled ordinal, unbounded buffer, timing-based drop bound,
cross-turn aliasing) collapse into "does it satisfy the five clauses" instead of four
independent bugs. The cost is a receiver-side sequencer plus a bounded reorder buffer
with telemetry (small), and the property/adversarial tests above.

## References

- PR #640 (`DROOdotFOO/raxol`): three review rounds; commits `732070c2`, `94c47a32`,
  `d70c0dfd`, and the posted adversarial re-reviews.
- ADR-0013: Event-dispatch backpressure — the in-repo pattern for bounded, observable,
  deterministic-under-overload dispatch this contract adopts.
- `packages/raxol_acp` client delivery path: `extract_update_seq/1`, `emit_update/3`,
  `cascade_release/2`, `@update_settle_ms`.
