# Harness Architecture

The harness is a headless agent-session **core** that owns all durable state
and speaks a typed **contract** of events (core → surface) and commands
(surface → core). Surfaces are pure subscribers that hold nothing persistent:
attach, detach, and reattach are all replay from an offset, so the local view
is a throwaway materialization. Kill a surface and respawn it and it shows the
same truth, because the truth was never in the surface.

## Where this sits

The harness is the **engine**, not a product you run directly (there is no
`mix raxol.harness` — the `raxol.harness.*.bless` tasks only regenerate this
engine's golden/fixture test snapshots). The products are the surfaces built on
the contract: `mix raxol.code` is the interactive coding-agent TUI and
`mix raxol.p` is its headless twin, both in the `raxol_agent` package. Above
them, `raxol_symphony` orchestrates many such agent runs. The same contract also
lets the engine drive *external* agent CLIs — `Raxol.Agent.Backend.ClaudeCode`
and `Raxol.Agent.Backend.Cursor` wrap `claude` / `cursor` as harness sessions.
"Harness" here is the session engine; it is unrelated to the `--backend` flag
(which picks an LLM backend) and to the RATE render-determinism suite.

## The event contract

Events flow core → surface; commands flow surface → core.

An event carries `id`, `turn_id`, `ts`, `family`, `type`, `tier`, `scope`,
`provenance`, and `payload` — the shape `Raxol.Harness.Projection`,
`Raxol.Harness.EventBoundary`, and `Raxol.UI.Components.Harness.Block.from_events/3`
all consume. Two properties of that shape are load-bearing:

- **Two families.** `:loop` events are the agent's turns; `:meta` events are
  everything else. Only `:loop` events become transcript blocks.
- **Two tiers.** Durable events are journaled before they reach the surface.
  `item_delta` is the one ephemeral event — it feeds the live tail, is never
  journaled, and is reconstructable from the matching `item_completed`, so no
  durable state ever depends on having seen every chunk.

Commands are the built lane vocabulary — submit, steer, interrupt, approval
answer, halt — carried as `Raxol.Harness.Directive.Lane` structs and decoded
through `Raxol.Agent.Command`.

**The contract only grows.** Producers are strict; readers are tolerant and
skip what they do not recognize (`EventBoundary` drops unknown fields; `Block`
normalizes an unknown `kind` to `:opaque` and renders it safely). A surface
must never need a lockstep update to keep painting.

## The security seam

A live event crosses a process boundary — `Raxol.Harness.SessionLane`'s
`subscribe/1` delivers events from a process this side does not control — so it
is untrusted input, not merely differently-shaped input.
`Raxol.Harness.EventBoundary.normalize/1` enforces four properties on the way
in: it never mints an atom from wire strings (no growing the atom table by
sending events), drops every field outside the nine the pipeline understands,
never launders taint (an ambiguous `provenance.trust` is absorbed to
`:tainted`, never cleared), and never guesses `:tier` (anything but
`:durable`/`:ephemeral` is a hard error, because tier decides what becomes
permanent transcript).

## Journal and projection

The durable journal is the source of truth. `Raxol.Agent.Journal` is the
append-only behaviour; `Raxol.Agent.Journal.FileStore` is the file-backed
implementation — one directory per session under `~/.raxol/sessions/<id>/`,
size-capped `NNNNNN.jsonl` segments, each event assigned a monotonic offset
that is its id, torn-tail recovery on replay, and fail-closed on interior
corruption (a gap is diagnosed, never silently healed).

`Raxol.Harness.Projection.project/2` folds durable events into an ordered block
list (`item_delta` feeds a live tail, never a durable block). Recovery is part
of the fold: `filter_ids/1` drops duplicate/out-of-order records and marks a
forward gap `damaged?` without withholding the survivors; `partition_families`
keeps only `:loop` events; `bucket_by_turn` groups by `turn_id` in first-seen
order; `BlockBuilder` folds each turn's items into blocks. Because the model is
a pure fold over the event stream, a snapshot of it is complete — time-travel
debugging (`time_travel: true`) is free.

## Process topology

Two independent supervision facts, often conflated:

- **The agent session.** `Raxol.Agent.Session` runs under
  `Raxol.Agent.Session.Supervisor`'s `:rest_for_one` tree together with its
  Lifecycle, ordered so a restart is deterministic — the Lifecycle starts
  first and the session re-resolves a fresh Lifecycle pid on restart rather
  than racing a stale one.
- **The live surface stack.** `Raxol.Harness.Live` boots
  `Raxol.Harness.SessionPump` (`:runtime_boot`), which owns the tty, stdin, the
  alt-screen bracket, and the clock, and in turn boots
  `Lifecycle(environment: :harness)` running `Raxol.Harness.HarnessApp`.
  `Raxol.Harness.DeliveryShim` casts every pump term into the Dispatcher as
  `{:harness, term}` — except a `:resize` event, which rides the system-event
  path so the Rendering Engine's size sync sees it. `HarnessApp.update/2` folds
  those messages and returns `Directive.{Lane,Editor}` back to the pump, which
  performs the lane mechanics and answers with the matching result message.

Ordering holds end to end: the pump establishes input-first order in its own
selective receive, and a FIFO Dispatcher downstream preserves it. Session death
is normalized to a `session_down` message and is never teardown; the shim dies
by link with the pump.

## The safety substrate

Three guarantees live in enforcement layers, outside the model, because a model
under adversarial input cannot be trusted to enforce them:

- **Staged supervised interrupt.** `Raxol.Agent.Interrupt.interrupt/3` runs a
  cooperative signal → bounded wait → OS process-group SIGKILL
  (`kill -9 -<os_pid>`; the BEAM makes each port program its own process-group
  leader, so `pgid == os_pid`), and confirms death at the OS level rather than
  trusting `:exit_status`. Each stage is a durable event
  (`:interrupt_signaled`, `:interrupt_waited`, `:interrupt_killed` /
  `:interrupt_kill_failed`, `:turn_canceled`). BEAM-native `Port.close` /
  `Process.exit` are insufficient against a wedged child, which is why the OS
  path exists.
- **Steer as compare-and-swap.** `Raxol.Agent.Steer` carries an
  `expected_turn_id`; a stale-turn rejection changes nothing and is
  non-journaled. Interrupt and steer are deliberately asymmetric — interrupt is
  fire-and-forget and its acknowledgment is the event stream; steer returns a
  synchronous typed decision, because a silently-dropped steer would leave the
  surface unable to tell "accepted" from "lost" (see `Raxol.Harness.SessionLane`).
- **Atomic spend and blast-radius gates.** `Raxol.Agent.SpendGate` reserves
  before the call and fails closed — no reserve, no call — using the same
  atomic `try_spend` shape as `Raxol.Payments.Ledger`.
  `Raxol.Agent.Authorization.BlastRadiusGate` gates scope the same way. A
  string denylist is provably incomplete; enforce typed intent instead.

## The live TUI chain

```
Raxol.Harness.SessionLane   (behaviour in main raxol — the seam main satisfies
                             without depending on raxol_agent)
  ← Raxol.Agent.Harness.SessionLane   (agent-side impl: SessionStreamer out,
                                       Raxol.Agent.Command in)
Raxol.Harness.SessionPump   (sole tty owner, alt-screen bracket, the clock)
  → live events through EventBoundary.normalize/1  (the untrusted-input seam)
  → Raxol.Harness.StreamCadence   (decouples token ingest from render egress)
  → DeliveryShim → Dispatcher {:harness, term} → HarnessApp
      (update/2 folds the contract, view/1 renders)
  → out: Directive.Lane structs the pump executes against SessionLane
Raxol.Harness.StallDetector  (pure observer; verdict + evidence to the human)
```

`Raxol.Agent.Harness.SessionInbox` is the session runtime on the agent side: it
runs one turn at a time (a submit mid-turn is queued for the next boundary),
parks the tool loop on a blocking await keyed by `request_id` before a
consequential tool and replies when the keyboard answer arrives, and drives the
staged kill against the live shell tool. `StreamCadence` load-sheds rather than
applies backpressure — the newest deltas are the live tail's value, and
blocking the SSE reader would cascade into transport timeouts, so visibly lossy
above the watermark beats dead. `StallDetector` never acts on the agent;
judgment over visible output belongs to the human it reports to.

**External-agent drivers.** `Raxol.Agent.NativeHarness` is the behaviour for a
CLI that owns its own loop. `Raxol.Agent.Harness.ClaudeCode` drives
`claude -p --output-format stream-json` with Raxol's tools injected over MCP
(`--mcp-config`); `Raxol.Agent.Harness.Cursor` is the sibling driver; both
parse NDJSON through `Raxol.Agent.Harness.StreamJson`.

## ACP wiring

`packages/raxol_agent_client_protocol/` is an Elixir/OTP implementation of the
Agent Client Protocol (the editor ↔ agent protocol at agentclientprotocol.com),
both roles, with a durable-resumable-sessions vendor extension: `Ext.Journal`
is an append-only offset journal, `Ext.Reattach` does offset-based replay, and
`Ext.AttachPolicy` issues `RXC1` Ed25519 capability tokens — the journal/offset
model exported onto the ACP wire. It is distinct from `Raxol.ACP`
(`packages/raxol_acp/`, the unrelated Virtuals commerce protocol). Steer
bridges through it: `Raxol.Agent.Harness.SessionLane.steer/2` dispatches to a
live `Raxol.AgentClientProtocol.Session`'s compare-and-swap when the session
handle is ACP-backed, and returns the honest `:no_steer_channel` refusal when
it is not.
