# ADR-0030: ACP session/update delivery ordering contract

## Status

Accepted; implemented (`Raxol.AgentClientProtocol.Delivery` implements clauses 1/2/5,
per its moduledoc). Originally proposed 2026-07-18, raised from three consecutive
review rounds on PR #640 (`fix(acp): single-sender session/update delivery`); this
ADR settled the contract before the implementing patch. Revised the same
day after an adversarial self-review (see #641): clause 1 is now decided (not an
either/or), the receiver-assigned principle is applied recursively to the turn
namespace, the wall-clock/overflow contradiction in the gap clause is removed, and the
contract is reconciled with the reattach/replay contract (#569/#586).

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

Round 3 lands on the worst answer: the ordering key is chosen by the **peer**: the
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

Definitions used below. A **turn** is the lifecycle of one `session/prompt` request from
issue through its terminal `:acp_result`. An **update** is a `session/update`
notification observed between those two points. A **straggler** is an update the receiver
observes after it has already delivered the terminal result for that turn.

1. **Receiver-assigned, contiguous ordering key (decided).** The ordering key is a
   monotonic per-session counter **stamped by the receiver at the single sequential
   point where inbound frames are demultiplexed: before any async, per-session
   dispatch fan-out**. It is never read from, nor validated against, the peer's `_meta`.
   Arrival-order-per-connection is explicitly rejected as the key, because it is not
   stable across a reattach/replay onto a new connection (see clause 5 and the
   reattach/replay reconciliation below). Stamping before fan-out is load-bearing:
   stamping inside a per-session task reintroduces the round-2 race. The peer's `_meta`
   may be surfaced to the handler as opaque data, but is never load-bearing for delivery
   order or drop decisions.

   A consequence worth stating: because the receiver assigns *contiguous* ordinals, the
   peer cannot manufacture a gap. On a single reliable, ordered transport (TCP/WS) a gap
   in receiver-stamped ordinals can arise only from genuine connection loss, not from
   peer whim. This removes the "withhold one ordinal to force the degraded path" primitive
   that a peer-supplied key would have handed over.

2. **Bounded reorder buffer, observable.** The reorder buffer has a watermark; its
   occupancy and every drop/gap decision emit `:telemetry`, never a silent drop, never
   an unbounded park. Event name `[:raxol, :acp, :delivery]`, metadata
   `%{session, turn, decision: :emit | :buffer | :gap | :fail, buffered: n, ordinal: k}`,
   mirroring ADR-0013's convention. Default watermark: 1_024 buffered updates per turn
   (informed by ADR-0013's 1_000; a per-turn LLM stream should never legitimately hold
   more than a few outstanding). Crossing the watermark is treated as clause 3's failure
   case, not a silent trim.

3. **Overflow-bounded resolution, not timer-bounded.** In-order delivery is released as
   the next contiguous ordinal arrives; there is **no wall-clock settle window** and the
   no-drop guarantee never depends on a timer (this is the `@update_settle_ms` mistake
   the ADR criticizes: a bounded interval is still a wall-clock timeout). A gap is bounded
   by the buffer watermark, not by elapsed time: while the buffer is under watermark the
   receiver holds the tail and keeps waiting for the missing contiguous ordinal; only two
   events resolve a gap: (a) the missing ordinal arrives (normal case, release the tail),
   or (b) the connection to that session drops or the buffer hits its watermark, in which
   case the turn **fails** with a `:fail` telemetry event. **Fail-the-turn is the only
   lossless resolution and is the default.** A `:gap`-marker (deliver the tail past a hole)
   is permitted ONLY for update types the API explicitly marks coalescible/idempotent (as
   render frames are in ADR-0013); it is never applied to lossless streamed content, where
   a hole is corruption.

4. **Streaming preserved.** `on_update` fires incrementally per contiguous update
   (O(1) steady-state memory). A test pins that the handler observes chunks live during
   the turn, not only at `:acp_result`.

5. **Recursive receiver-assignment across turns.** The per-turn namespace that scopes
   ordinals (so a turn-N straggler cannot alias into turn N+1) is itself
   **receiver-assigned**, never derived from a peer-supplied session/job/turn id. Applying
   the clause-1 trust-boundary rule to only the ordinal and not its namespace would move
   the same defect up one level: a peer that reuses a turn id could re-alias stragglers.
   The receiver either never resets the counter within a session (single monotonic space)
   or scopes it under a receiver-generated turn token.

### Reconciliation with reattach/replay (#569 / #586)

Reattach/replay delivers a turn's updates on a **new** connection, so there is no single
per-connection arrival sequence spanning the original turn and its replay, which is why
clause 1 rejects arrival-order as the key. The per-session counter is the reconciliation:
ordinals are stamped once, in the session's monotonic space, and replay re-delivers
**already-stamped** ordinals rather than re-numbering by new-connection arrival. Delivery
is therefore idempotent by ordinal (a replayed ordinal the handler has already seen is a
no-op, not a reorder), and the frozen replay-closure contract in #569/#586 is preserved.
Any implementation must add a replay test asserting that a full replay onto a fresh
connection reproduces the original handler-visible order with no duplicates and no
renumbering.

### Invariants to pin with tests

- **Order**: for any interleaving of receiver-stamped updates, the handler observes them
  in stamped order (property test, mirroring `test/property/backpressure_ordering_test.exs`).
- **No silent drop**: every update either reaches the handler or is accounted for by
  exactly one `:gap`/`:fail` telemetry event; delivered + failed = sent.
- **No timer in the guarantee**: injecting arbitrary scheduler delay between updates
  changes latency but never the delivered set or order (pins clause 3, no wall-clock
  settle window).
- **Bounded memory**: buffer occupancy never exceeds the watermark; hitting the
  watermark fails the turn rather than growing the buffer or silently trimming it.
- **Peer cannot wedge or steer delivery**: because ordinals are receiver-stamped and
  contiguous, a peer that replays, withholds, or freezes its `_meta` cannot cause an
  unbounded buffer, a silent drop, out-of-order delivery, or force the degraded path
  (adversarial test with a hostile peer stub).
- **Replay idempotence**: a full replay onto a fresh connection reproduces the original
  handler-visible order with no duplicates and no renumbering (reconciles #569/#586).
- **Live streaming**: handler receives >1 update before the terminal result for a
  multi-chunk turn.

## Alternatives considered

- **Keep patching round-by-round.** Rejected: three rounds have each moved the hole,
  not closed it; the fourth would too, because the trust-boundary decision is unmade.
- **Trust the peer's `_meta` seq but validate monotonicity.** Rejected: validation can
  detect a bad sequence but cannot reconstruct the intended order from an untrusted
  source, so it degrades to "fail the turn", which is clause 2/3 anyway, minus the
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
- ADR-0013: Event-dispatch backpressure: the in-repo pattern for bounded, observable,
  deterministic-under-overload dispatch this contract adopts.
- `packages/raxol_earn` client delivery path: `extract_update_seq/1`, `emit_update/3`,
  `cascade_release/2`, `@update_settle_ms`.
