# Harness Architecture

The harness is a headless agent-session **core** that owns all durable state
and speaks a typed **contract** of events (core → surface) and commands
(surface → core). Surfaces are pure subscribers that hold nothing persistent:
attach and reattach are replay from an offset, so the local view is a
throwaway materialization. Kill a surface and respawn it and it shows the
same truth, because the truth was never in the surface.

## Where this sits

The harness is the **engine**, not a product you run directly (there is no
`mix raxol.harness`: the `raxol.harness.*.bless` tasks only regenerate this
engine's golden/fixture test snapshots). The products are the surfaces built on
the contract: `mix raxol.code` is the interactive coding-agent TUI and
`mix raxol.p` is its headless twin, both in the `raxol_agent` package. Above
them, `raxol_symphony` orchestrates many such agent runs. The same contract also
lets the engine drive *external* agent CLIs: `Raxol.Agent.Backend.ClaudeCode`
and `Raxol.Agent.Backend.Cursor` wrap `claude` / `cursor-agent` as harness
sessions.
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

Commands run the other way. `Raxol.Agent.Command.decode/1` is the single
validation seam: it turns a JSON string or a plain map into a
`%Raxol.Agent.Command{type, payload}` over the vocabulary `:prompt`,
`:interrupt`, `:attach`, `:seek`, `:steer`, `:approval_decision`. It is loud
(a non-map, an unknown or missing `type`, or a missing required payload field
is `{:error, {:invalid_command, reason}}`), it never raises, and it never
mints an atom from a wire string: `type` and `history_policy` are whitelisted
string-to-atom maps. `Raxol.Harness.SessionLane` is the behaviour main raxol
dispatches through so the surface never depends on `raxol_agent`;
surface-local commands minted by `Raxol.UI.Harness.Keymap` carry the same
`%{type: atom(), payload: map()}` field names as a plain map, one
`struct(Raxol.Agent.Command, cmd)` from the real thing.

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
size-capped `NNNNNN.jsonl` segments, and each event assigned a monotonic
offset that is its id. Interior corruption is fail-closed: `Reader.scan/2`
returns `{:damaged, records_before}`, deletes nothing, fires a `Logger.error`
plus `[:raxol, :agent, :journal, :damaged]` telemetry, and the damaged content
never reaches a surface.

Reads never write. A torn tail (a parse failure on the last line of the last
segment, the signature of a crash mid-write) is tolerated in memory by
`Reader.scan/2` and repaired only by the owning Writer at its own boot, via
`Reader.resume_scan/1`. A reader that truncated would compute the cut from a
file it read moments ago, so against a live session it could delete a record
the Writer already committed and counted, whose next append then lands past
the hole and leaves the session permanently damaged.

`Raxol.Harness.Projection.project/2` folds durable events into an ordered block
list (`item_delta` feeds a live tail, never a durable block). Recovery is part
of the fold: `filter_ids/1` drops duplicate/out-of-order records and marks a
forward gap `damaged?` without withholding the survivors; `partition_families`
keeps only `:loop` events; `bucket_by_turn` groups by `turn_id` in first-seen
order; `BlockBuilder` folds each turn's items into blocks. Because the model is
a pure fold over the event stream, time-travel is a re-fold rather than a
mechanism: the `:seek` command folds every durable record with id <= offset
back into the same block read-model.

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

- **The agent session.** `Raxol.Agent.Session.Supervisor` is one
  `:rest_for_one` subtree per session, children in dependency order:
  `Raxol.Agent.EmitBridge` (the per-session sink, owning the durable journal
  handle and the EmitBus subscription), then `Raxol.Core.Runtime.Lifecycle`
  (the per-session TEA runtime), then `Raxol.Agent.Session` (the thin
  forwarder). A session crash restarts only the session, which re-resolves the
  same running Lifecycle through `Raxol.Agent.Registry` so the model survives;
  a bridge crash restarts the whole subtree in dependency order, so a durable
  event is never emitted into a dead-sink gap.
- **The live surface stack.** `Raxol.Harness.LiveSessionDriver` supervises one
  live session as a plain process loop, deliberately not a GenServer. Inside
  its own process it builds the injected `{lane_module, session}`, a
  `Raxol.Harness.StreamCadence` server, a linked forwarder that owns the
  `subscribe/1` call and re-shapes `{:session_event, sid, event}` into
  `StreamCadence.ingest/2`, and a `Raxol.Harness.StallDetector`.

Ordering holds because `loop/1`'s first move on every pass is a `receive`
matching only `{:inline_input, _}` and `{:surface_command, _}` with `after 0`,
falling through immediately into a second blocking receive that also matches
`{:render_batch, _}`. That is the owner half of the cadence contract, which a
single `handle_info/2` callback cannot express. `StreamCadence`'s
`:input_check` source-side hold is a latency optimization layered on top of
that guarantee, and it defaults off until a caller wires a real check.

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
- **Atomic spend and blast-radius gates.** `Raxol.Agent.SpendGate` journals
  `reserve → call → settle` per spend-bearing call, correlated by an opaque
  `cost_ref`, and fails closed: no reserve, no call. raxol_agent does not
  depend on raxol_payments, so the gate replicates the atomic `try_spend`
  shape rather than importing `Raxol.Payments.Ledger`; its records leave
  through an injected `context.emit` sink, and a raising sink propagates as
  `Raxol.Agent.SpendGate.JournalWriteError` instead of dropping a record on
  irreversible spend state. `Raxol.Agent.Code.CostLedger` is the shipped
  bridge in the other direction: the coding TUI records LLM cost against a
  real `Raxol.Payments.Ledger`, and asks `check_budget` twice per turn: at
  submit, refusing to start the next one, and again as each `turn_completed`
  folds, interrupting the turn already running. It degrades to a no-op when
  raxol_payments is absent from the host application.
  `Raxol.Agent.Authorization.BlastRadiusGate` gates write and destructive
  tools the same way (locked by default, escalate to a human, live approval
  state rebuildable by a fold over `approval_decided` events); it has no
  non-test caller yet.
  `Raxol.Agent.Authorization.Engine` is the pure ALLOW/ASK/DENY reducer the
  coding TUI runs every sensitive tool call through. A string denylist is
  provably incomplete; enforce typed intent instead.

## The live TUI chain

Two TUI chains sit on the contract, and they do not share a driver.

`Raxol.Harness.LiveSessionDriver` is the harness-native one, a process loop
over the assembled `Raxol.Harness.Surface`. It is built and tested but not yet
launched: its only caller in the tree is
`test/harness/live_session_driver_test.exs`, and `Surface` has no consumer
outside it. The chain it assembles:

```
Raxol.Harness.SessionLane   (behaviour in main raxol: the seam main satisfies
                             without depending on raxol_agent)
  ← Raxol.Agent.Harness.SessionLane   (agent-side impl: SessionStreamer out,
                                       Raxol.Agent.Command in)
Raxol.Harness.LiveSessionDriver   (the process loop; input-first receive)
  → live events through EventBoundary.normalize/1  (the untrusted-input seam)
  → Raxol.Harness.StreamCadence   (decouples token ingest from render egress)
  → Raxol.Harness.Surface
      (Projection folds blocks; Composer, Keymap, StatusStrip, pickers)
  → out: %{type, payload} commands the driver runs against SessionLane
Raxol.Harness.StallDetector  (pure observer; verdict + evidence to the human)
```

`mix raxol.code` is the shipped one, and it drives its own loop.
`Raxol.Agent.Code.App` is a TEA app: on submit `update/2` spawns a worker that
subscribes to a `Raxol.Agent.SessionStreamer` session, runs
`Raxol.Agent.Stream.react/2` through `Raxol.Agent.Contract.pump/3`, and relays
each contract event back as `{:command_result, {:contract_event, event}}`.
Those go through the same `EventBoundary.normalize/1` and fold into the same
`Raxol.Harness.Projection` blocks that `Raxol.UI.Components.Harness.Block`
renders. It shares the contract and the rendering pieces with the driver
above, and reaches them by its own path.

`Raxol.Agent.Harness.SessionInbox` is the session runtime on the agent side:
it consumes the `{:harness_command, action}` messages `Command.route/2`
delivers, runs one turn at a time (a submit arriving mid-turn is queued for
the next boundary), parks the tool loop on a `GenServer.call` keyed by
`request_id` before a consequential tool and replies when the keyboard answer
arrives, and runs `Interrupt.interrupt/3` against the live shell tool's
`%{port, os_pid}`. It is written and tested; no non-test module starts one, so
`mix raxol.code` runs its own equivalents today. `StreamCadence` load-sheds
rather than applies
backpressure: the newest deltas are the live tail's value, and blocking the
SSE reader would cascade into transport timeouts, so visibly lossy above the
watermark beats dead. `StallDetector` never acts on the agent; judgment over
visible output belongs to the human it reports to.

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
`Ext.AttachPolicy` issues `RXC1` capability tokens (`Ext.AttachPolicy.Token`:
detached Ed25519, no header and no `alg` field, because the literal `RXC1`
prefix inside the signed bytes is the algorithm binding): the journal/offset
model exported onto the ACP wire. It is distinct from `Raxol.Earn`
(`packages/raxol_earn/`, the unrelated Virtuals commerce protocol).

The coding agent serves that protocol on stdio.
`Raxol.Agent.ClientProtocol.Serve` parses argv, reroutes logs to stderr before
the transport binds (a single stray stdout line is a protocol parse error at
the client), and serves until the peer disconnects, returning an exit code: 0
on a clean disconnect. It contains no Mix calls, so `mix raxol.acp` and the
Burrito CLI's `raxol acp` run the same code; `bin/raxol-acp` is the shim an
editor should point at, because `mix` prints compile output to stdout on first
run and that would corrupt the wire. `Raxol.Agent.ClientProtocol.StdioAgent`
is the handler: each `session/new` starts a `Raxol.AgentClientProtocol.Session`
whose `:turn_runner` is `Raxol.Agent.ClientProtocol.TurnRunner`, and each
session's file tools scope to the `cwd` the editor sent. Turns run the full
toolset: `Raxol.Agent.ClientProtocol.Permission.authorizer/2` gates every
sensitive Action on a `session/request_permission` round trip, injected per
turn as the context's `:tool_authorizer`. Reads are not gated. The gate is
fail-closed on the DECISION rather than on the toolset, so a client that
refuses, times out, disconnects, or answers method-not-found denies the write
and leaves reads working. The protocol package is a
dev/test path dependency, so `StdioAgent` compiles only when raxol_agent is
built from source with it present; a Hex install exits 1 with an explanation.

Steer does not bridge. `Raxol.Agent.Harness.SessionLane.steer/2` returns
`{:error, :no_steer_channel}`, always: no shipped session runtime owns a live
turn's `Raxol.Agent.Steer.TurnState` to resolve the compare-and-swap against,
and dispatching a fire-and-forget steer with no decision reply would let a
surface render a queued banner it could never know was accepted.
