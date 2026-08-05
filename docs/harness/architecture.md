# Harness Architecture

The harness is a headless agent-session **core** that owns all durable state
and speaks a typed **contract** of events (core → surface) and commands
(surface → core). Surfaces are pure subscribers that hold nothing persistent:
attach, detach, and reattach are all replay from an offset, so the local view
is a throwaway materialization. Kill a surface and respawn it and it shows the
same truth, because the truth was never in the surface.

## Where this sits

The harness is the **engine**, not a product you run directly (there is no
`mix raxol.harness`: the `raxol.harness.*.bless` tasks only regenerate this
engine's golden/fixture test snapshots). The products are the surfaces built on
the contract: `mix raxol.code` is the interactive coding-agent TUI and
`mix raxol.p` is its headless twin, both in the `raxol_agent` package. Above
them, `raxol_symphony` orchestrates many such agent runs. The same contract also
lets the engine drive *external* agent CLIs: `Raxol.Agent.Backend.ClaudeCode`
and `Raxol.Agent.Backend.Cursor` wrap `claude` / `cursor` as harness sessions.
"Harness" here is the session engine; it is unrelated to the `--backend` flag
(which picks an LLM backend) and to the RATE render-determinism suite.

## The event contract

Events flow core → surface; commands flow surface → core.

An event carries `id`, `turn_id`, `ts`, `family`, `type`, `tier`, `scope`,
`provenance`, and `payload`: the shape `Raxol.Harness.Projection`,
`Raxol.Harness.EventBoundary`, and `Raxol.UI.Components.Harness.Block.from_events/3`
all consume. Two properties of that shape are load-bearing:

- **Two families.** `:loop` events are the agent's turns; `:meta` events are
  everything else. Only `:loop` events become transcript blocks.
- **Two tiers.** Durable events are journaled before they reach the surface.
  `item_delta` is the one ephemeral event: it feeds the live tail, is never
  journaled, and is reconstructable from the matching `item_completed`, so no
  durable state ever depends on having seen every chunk.

Commands are the built lane vocabulary (submit, steer, interrupt, approval
answer, halt) carried as `Raxol.Harness.Directive.Lane` structs and decoded
through `Raxol.Agent.Command`.

**The contract only grows.** Producers are strict; readers are tolerant and
skip what they do not recognize (`EventBoundary` drops unknown fields; `Block`
normalizes an unknown `kind` to `:opaque` and renders it safely). A surface
must never need a lockstep update to keep painting.

## The security seam

A live event crosses a process boundary (`Raxol.Harness.SessionLane`'s
`subscribe/1` delivers events from a process this side does not control) so it
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
implementation: one directory per session under `~/.raxol/sessions/<id>/`,
size-capped `NNNNNN.jsonl` segments, each event assigned a monotonic offset
that is its id, torn-tail recovery on replay, and fail-closed on interior
corruption (a gap is diagnosed, never silently healed).

`Raxol.Harness.Projection.project/2` folds durable events into an ordered block
list (`item_delta` feeds a live tail, never a durable block). Recovery is part
of the fold: `filter_ids/1` drops duplicate/out-of-order records and marks a
forward gap `damaged?` without withholding the survivors; `partition_families`
keeps only `:loop` events; `bucket_by_turn` groups by `turn_id` in first-seen
order; `BlockBuilder` folds each turn's items into blocks. Because the model is
a pure fold over the event stream, a snapshot of it is complete: time-travel
debugging (`time_travel: true`) is free.

### Frozen golden corpora

Every record carries the `schema_version` the Writer stamped. Upcast-on-read (
letting a current reader open a journal written by an older version) can only
be tested against real journals those versions actually wrote, and those become
unrecoverable the moment the default moves on: nothing regenerates a 1.0.0
journal once the writer emits 1.2.0.

So each version is frozen exactly once, while it is current, under
`packages/raxol_agent/test/invariants/fixtures/golden/v<version>/`. A corpus is
produced by the real pipeline (`Contract.pump/3` generates the payloads,
`EmitBus` -> `EmitBridge` -> `FileStore.Writer` writes the journal) with only
`ts`, `turn_id`, and `meta.json`'s `created_at` normalized so the bytes are
reproducible.

| step | command |
| --- | --- |
| freeze the current version | `cd packages/raxol_agent && MIX_ENV=test mix run scripts/freeze_golden_journal.exs` |
| re-pin the manifest | `elixir scripts/check_journal_goldens.exs --bless` |
| verify (CI, `format` job) | `elixir scripts/check_journal_goldens.exs` |

`scripts/check_journal_goldens.exs` enforces three rules against
`fixtures/golden/MANIFEST.json`: the current `@default_schema_version` has a
frozen corpus (so a bump fails until one is frozen), every pinned corpus still
exists with the exact same bytes (history is not editable or deletable), and
nothing on disk is unpinned. `Raxol.Agent.Invariants.ContractInvariantsTest`
replays the current corpus through the live reader and asserts the shapes its
version added, for 1.1.0, that all three `evidence` states are present and
decode.

### Multi-surface parity

`Raxol.Harness.Surface.Parity` is the check behind "one TEA module renders to
terminal, browser, SSH, and MCP". Every fixture is rendered ONCE and projected
four ways, so a divergence is always the projection's fault and never the
input's:

```
session (.jsonl) -> Projection.project/2 -> [Block.t()] -> Block.render/2
  -> LayoutEngine.apply_layout/2 -> Renderer.render_to_cells/2   (the grid)
```

| surface | projection | from |
| --- | --- | --- |
| `:cells` | canonical row-major cell dump | the grid |
| `:liveview_dom` | `TerminalBridge.buffer_to_html/2` | the grid |
| `:ssh_ansi` | `Core.Renderer.render_diff/2` + `apply_diff/1` | the grid |
| `:structured_json` | `MCP.StructuredScreenshot.from_view_tree/2` | the view tree |

`:structured_json` is taken from the view tree deliberately: that is the MCP
surface's actual input, and pinning it from the grid would test a pipeline
nothing runs.

Two independent properties, both in `test/harness/surface_parity_test.exs`:

- **Drift**: each fixture x surface artifact
  (`test/fixtures/harness/parity/`) still matches a fresh render, and
  `priv/harness/parity.refs` still hashes the artifacts. Bless with
  `mix raxol.harness.parity.bless` (`--check` for the CI half).
- **Parity**: the surfaces agree. The three grid-derived surfaces must be
  character-for-character equal; `:structured_json`'s block headers must match
  the screen's, as a prefix (the viewport clips a long session). This is the
  property a single-surface golden cannot have: an encoder that drops a wide
  character still hashes consistently with itself and only diverges against a
  sibling.

The corpus convention: **every rendering bug fixed leaves a fixture behind.**
Membership is `Fixture.Session.golden?/1`, the same predicate the fixture bless
uses, so the two corpora cannot drift apart; a `kind: "adversarial"` fixture
exists to be rejected by the loader, so there is no render to pin. That is a
header field, not a filename convention: a `.notes.md` sidecar is
documentation and says nothing about whether a fixture renders.

Snapshot bytes are a function of content alone: `Fixture.Bless` stringifies
every key before encoding, because an atom-keyed map iterates in atom-table
order and a recompile that shifts which module interned an atom first would
otherwise reorder the JSON and report drift that is not there.
## Process topology

Two independent supervision facts, often conflated:

- **The agent session.** `Raxol.Agent.Session` runs under
  `Raxol.Agent.Session.Supervisor`'s `:rest_for_one` tree together with its
  Lifecycle, ordered so a restart is deterministic: the Lifecycle starts
  first and the session re-resolves a fresh Lifecycle pid on restart rather
  than racing a stale one.
- **The live surface stack.** `Raxol.Harness.Live` boots
  `Raxol.Harness.SessionPump` (`:runtime_boot`), which owns the tty, stdin, the
  alt-screen bracket, and the clock, and in turn boots
  `Lifecycle(environment: :harness)` running `Raxol.Harness.HarnessApp`.
  `Raxol.Harness.DeliveryShim` casts every pump term into the Dispatcher as
  `{:harness, term}`: except a `:resize` event, which rides the system-event
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
  non-journaled. Interrupt and steer are deliberately asymmetric: interrupt is
  fire-and-forget and its acknowledgment is the event stream; steer returns a
  synchronous typed decision, because a silently-dropped steer would leave the
  surface unable to tell "accepted" from "lost" (see `Raxol.Harness.SessionLane`).
- **Atomic spend and blast-radius gates.** `Raxol.Agent.SpendGate` reserves
  before the call and fails closed (no reserve, no call) using the same
  atomic `try_spend` shape as `Raxol.Payments.Ledger`.
  `Raxol.Agent.Authorization.BlastRadiusGate` gates scope the same way. A
  string denylist is provably incomplete; enforce typed intent instead.

## The live TUI chain

```
Raxol.Harness.SessionLane   (behaviour in main raxol: the seam main satisfies
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
applies backpressure: the newest deltas are the live tail's value, and
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
`Ext.AttachPolicy` issues `RXC1` Ed25519 capability tokens: the journal/offset
model exported onto the ACP wire. It is distinct from `Raxol.Earn`
(`packages/raxol_earn/`, the unrelated Virtuals commerce protocol). Steer
bridges through it: `Raxol.Agent.Harness.SessionLane.steer/2` dispatches to a
live `Raxol.AgentClientProtocol.Session`'s compare-and-swap when the session
handle is ACP-backed, and returns the honest `:no_steer_channel` refusal when
it is not.
