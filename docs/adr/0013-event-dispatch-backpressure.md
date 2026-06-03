# ADR-0013: Event-dispatch backpressure

## Status

Proposed, 2026-06-03. Implementation deferred to follow-up PRs (see Rollout).

## Context

Raxol's hot-path event dispatch uses unbounded `GenServer.cast` at three sites. The dispatcher mailbox can grow without observable signal under per-keystroke load (typing, mouse motion, animation frames). The refactor backlog item #3 -- and CLAUDE.md's project guidance ("when in doubt, use `call` over `cast`, to ensure back-pressure") -- both flag this as a real concern.

The three sites and their characteristics:

- `lib/raxol/ui/rendering/render_batcher.ex:50` -- `submit_update/4` casts `{:submit_update, tree, diff_result, priority, ts}` per UI update. The receiver coalesces into frame batches; dropped updates merge naturally into the next batch.
- `lib/raxol/core/runtime/events/dispatcher.ex:383` -- `handle_manager_cast({:dispatch, event}, state)` consumes the dispatch. The sender is the terminal driver (`packages/raxol_terminal/lib/raxol/terminal/driver.ex:338`). Every keystroke / mouse / focus / paste event goes through here. Dropping events corrupts user input; ordering matters.
- `lib/raxol/headless.ex:423` -- `dispatch_key/3` casts `{:dispatch, event}` to the dispatcher from Headless / MCP / agent tests. Same ordering and loss-intolerance as the live driver path.

The first two refactor waves (commits `723f085b..898ac5e0` and `37dc1298..69c0a934`) cleared cheap mechanical wins (ETS hints, Task wrappers, `String.to_atom`, pdict caches). This is the highest-risk remaining item: changing cast/call semantics alters the timing of the event loop and could regress UX or break property invariants. It earns its own ADR before any code lands.

### Why a blanket cast -> call swap is wrong

A naive "cast becomes call everywhere" change makes every keystroke synchronous on the typing user, even when the dispatcher mailbox is healthy. The Erlang GenServer call adds a round-trip and a monitor; under nominal load this is pure overhead. The right shape is: **cast normally, escalate to call only when the queue is hot**.

### Prior art for queue-depth probing

The repo already uses `Process.info(pid, :message_queue_len)` in two places:

- `lib/raxol/memory/optimizer.ex:78-82` -- triggers memory triage when a process has `message_queue_len > 1000`.
- `lib/raxol/core/error_recovery/recovery_wrapper.ex:279` -- probes `self()` for diagnostics.

We are not inventing a new probe -- we are wrapping an existing one in a policy.

## Decision

Introduce `Raxol.Core.Runtime.Backpressure`, a small helper that wraps `GenServer.cast` with three pieces:

1. A queue-depth check via `Process.info(target_pid, :message_queue_len)`.
2. A per-site **policy** that decides what happens when the depth exceeds a watermark: cast normally, escalate to call, or drop.
3. A `:telemetry` event emitted on every invocation so the decisions are observable.

Each of the three hot-path sites adopts the helper with the policy that matches its loss tolerance.

### Module surface

```elixir
defmodule Raxol.Core.Runtime.Backpressure do
  @moduledoc """
  Adaptive backpressure for hot-path GenServer.cast.

  Probes the target mailbox depth and switches to call (or drops the message)
  when the queue crosses a watermark. Emits :telemetry on every invocation.
  """

  @type policy :: :call_when_full | :drop_when_full | :fail_when_full
  @type result :: :ok | {:dropped, :overflow | :no_proc}

  @default_watermark 1_000
  @default_timeout   5_000

  @spec cast(GenServer.server(), term(), keyword()) :: result()
  def cast(target, message, opts)
end
```

Options:

| Option | Default | Meaning |
|---|---|---|
| `:label` | required | atom tag, used as telemetry metadata so each site is distinguishable |
| `:watermark` | `1_000` | queue length above which the policy kicks in |
| `:policy` | required | `:call_when_full` / `:drop_when_full` / `:fail_when_full` |
| `:timeout` | `5_000` | only used when policy is `:call_when_full` |

Return values:

- `:ok` -- the message was delivered (via cast or call).
- `{:dropped, :overflow}` -- watermark exceeded under `:drop_when_full`.
- `{:dropped, :no_proc}` -- target is not alive (race; the caller treats this as a no-op).

### Per-site policy

| Site | Policy | Rationale |
|---|---|---|
| `RenderBatcher.submit_update/4` | `:drop_when_full` | Frame batching is the natural recovery. A dropped update will be subsumed by the next non-dropped update's diff. Telemetry surfaces the drop rate. |
| `Dispatcher` :dispatch (from driver) | `:call_when_full` | Input events must not be lost. The call applies backpressure to the driver, which stalls reading the next keystroke. A brief input stall under genuine overload is preferable to dropped keystrokes. |
| `Headless.dispatch_key/3` | `:call_when_full` | Test determinism. Cast-based tests already have flake risk; `:call_when_full` removes it under high-volume agent runs. |

`:fail_when_full` returns an error rather than dropping silently. Reserved for future callers that want explicit failure (e.g., admin commands).

### Ordering invariant

Under `:call_when_full`, the call goes to the same GenServer mailbox as the prior casts. From the same caller, Erlang guarantees per-process FIFO message ordering. So a `cast(A), cast(B), call(C)` sequence from one caller arrives in the dispatcher's mailbox as `A, B, C`. The policy switch does not reorder.

A property test (see Test strategy) pins this invariant. Without the test, a future refactor of the helper could break ordering invisibly.

### Telemetry

Single event name, three policies discoverable via metadata:

```elixir
:telemetry.execute(
  [:raxol, :runtime, :backpressure],
  %{queue_len: queue_len},
  %{
    label: opts[:label],
    policy: opts[:policy],
    decision: :cast | :call | :drop | :no_proc,
    target: target_name_or_pid
  }
)
```

This matches the existing 3-segment telemetry convention (compare `[:raxol, :runtime, :view_tree_updated]` in `lib/raxol/core/runtime/rendering/engine.ex:277`). Surfaces like `raxol_symphony` and the dev profiler can attach handlers without further plumbing.

### Watermark tuning

Default `1_000` matches `lib/raxol/memory/optimizer.ex`. The number is informed but not load-tested at the dispatcher rate. A load test (see Test strategy) measures the actual safe value. Each call site can override.

## Test strategy

Three layers:

**1. Unit tests** -- `test/raxol/core/runtime/backpressure_test.exs`. Cover each policy at known watermarks with a controllable target GenServer that holds its mailbox open. Asserts:

- Below watermark: every call decides `:cast`, `:ok` returned, target receives the message.
- Above watermark, `:drop_when_full`: returns `{:dropped, :overflow}`, target does not receive the message.
- Above watermark, `:call_when_full`: returns `:ok`, target receives the message synchronously, caller blocks until handler completes.
- Dead target: returns `{:dropped, :no_proc}` regardless of policy.
- Telemetry: every invocation emits exactly one event with correct metadata.

**2. Property test** -- `test/property/backpressure_ordering_test.exs`. StreamData generates an event sequence of length 1..1000 with random policy switches. Asserts:

- Under `:call_when_full` and `:fail_when_full`, the order observed by the target equals the order sent by the caller.
- Under `:drop_when_full`, the order observed equals the order sent **minus the dropped subset** (no reordering, only deletion).

**3. Load test** -- `test/performance/backpressure_load_test.exs`, tagged `:slow`. Saturates a controllable dispatcher and asserts:

- Watermark triggers under genuine overload (sustained 10k events/sec for 1s).
- Telemetry drop rate matches expected drop rate within tolerance.
- p99 latency under load is bounded (concrete number TBD by the test run).
- `Process.info(pid, :message_queue_len)` overhead at per-keystroke rate is < 1us (informs whether the probe itself becomes a bottleneck).

## Rollout

Three follow-up PRs after this ADR lands:

- **PR-A**: `lib/raxol/core/runtime/backpressure.ex` + unit tests + property test. No caller changes. Lands behind no flag. Helper is unused but exercised.
- **PR-B**: `RenderBatcher.submit_update/4` adopts the helper with `:drop_when_full`. Drop rate observable via telemetry attached in a small dev script.
- **PR-C**: Dispatcher caller (`packages/raxol_terminal/lib/raxol/terminal/driver.ex:338`) and `Headless.dispatch_key/3` adopt with `:call_when_full`. Property test pinning ordering across the cast/call boundary is added to the regression suite.

Each PR is individually revertable.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Timing change regresses an existing animation or input test | Medium | Rollout in 3 PRs; property tests pin ordering; revert is one git command |
| `:call_when_full` stalls the terminal driver loop under load | Medium | Watermark of 1000 means the stall fires only under genuine overload. If it triggers in normal use, the watermark is too low, not the policy |
| `Process.info(pid, :message_queue_len)` overhead at keystroke rate | Low | Load test measures it; if non-trivial, switch to periodic sampling (check every Nth cast) |
| Dispatcher calls back into the driver -> deadlock under `:call_when_full` | None | Verified: `dispatcher.ex` makes one `GenServer.call` (to the plugin manager at `:645`), never to the driver. No cycle |

## Consequences

The three hot-path sites become observable (telemetry on every cast). UX gains a bounded-latency guarantee under overload (input stalls instead of growing the mailbox). The repo gains a reusable backpressure pattern that future hot paths can adopt -- if a fourth or fifth call site emerges, the cost is one helper call plus a policy choice.

The cost is one new module (~80 LOC including docs and specs), one property test, one load test, and roughly a dozen call-site edits.

## References

- `lib/raxol/memory/optimizer.ex:78-82` -- prior art for queue-depth probing.
- `lib/raxol/core/error_recovery/recovery_wrapper.ex:279` -- prior art for `Process.info(:message_queue_len)`.
- `lib/raxol/core/runtime/rendering/engine.ex:277` -- existing telemetry shape `[:raxol, :runtime, :*]`.
- CLAUDE.md, "OTP / Process Communication" section -- "When in doubt, use `call` over `cast`, to ensure back-pressure".
