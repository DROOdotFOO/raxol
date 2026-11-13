# Harness Architecture

The harness is a headless agent-session **core** that owns all durable state
and speaks a typed **contract** of events. Surfaces are pure subscribers that
hold nothing persistent: a surface's view is
`Raxol.Harness.Projection.project/2` over the session's events, a throwaway
materialization. Kill a surface and respawn it and it shows the same truth,
because the truth was never in the surface.

## Where this sits

The harness is the **engine**, not a product you run directly (there is no
`mix raxol.harness`: the `raxol.harness.*.bless` tasks only regenerate this
engine's golden/fixture test snapshots). Agent sessions run on it: `raxol acp
--agent` and the `agent_*` MCP tools each start one.
"Harness" here is the session engine; it is unrelated to an LLM backend and to
the RATE render-determinism suite.

## The event contract

Events flow core → surface. The contract defines no commands.

The event envelope, its two families and two tiers, and the rule that the
contract only grows are described in the
[`raxol_journal` README](../../packages/raxol_journal/README.md#the-event-contract).
`Raxol.Harness.Projection` and
`Raxol.UI.Components.Harness.Block.from_events/3` consume that shape. Only
`:loop` events become transcript blocks, and `item_delta`, the one ephemeral
event, feeds the live tail.

A surface's own commands are outside the contract. A command minted by
`Raxol.UI.Harness.Keymap` is a plain `%{type: atom(), payload: map()}` map, so
the surface never depends on `raxol_agent`. `:interrupt` and `:steer` leave
`Raxol.Harness.Surface` through its `:command_sink` option; nothing in the
tree consumes them.

On the surface side readers are tolerant and skip what they do not recognize
(`Block` normalizes an unknown `kind` to `:opaque` and renders it safely). A
surface must never need a lockstep update to keep painting.

## Journal and projection

The durable journal is the source of truth. `Raxol.Agent.Journal` and its
file-backed implementation `Raxol.Agent.Journal.FileStore` live in
`raxol_journal`; its
[README](../../packages/raxol_journal/README.md#the-journal) describes the
on-disk layout, the writer lock, damage handling and why reads never write. A
session's journal is one directory under `~/.raxol/sessions/<id>/`; an agent
started over MCP lives one level down, under
`<first 8 hex of sha256(project root)>/<id>/`.

Two record shapes come from the session rather than the Dispatcher. A session
started with `journal_required: true` writes `agent_started` (payload
`prior_offset`) each time it opens its journal, followed by a `turn_canceled`
(reason `agent_restarted`) for every turn the run before left open.
`Raxol.Agent.Session` brackets each prompt turn under a turn id of its own
(`acp-...`): `turn_started`, then one of `turn_completed`, `turn_canceled`
(reason `cancelled` or `caller_down`) or `error` (reason `turn_failed` or
`agent_down`). `agent_started` is a `loop` record outside the conversational
set, so it is never a tip.

`Raxol.Harness.Projection.project/2` folds durable events into an ordered block
list (`item_delta` feeds a live tail, never a durable block). Recovery is part
of the fold: `filter_ids/1` drops duplicate/out-of-order records and marks a
forward gap `damaged?` without withholding the survivors; `partition_families`
keeps only `:loop` events; `bucket_by_turn` groups by `turn_id` in first-seen
order; `BlockBuilder` folds each turn's items into blocks. Because the model is
a pure fold over the event stream, a view at an earlier offset is a re-fold of
the events up to it; nothing in the tree does that.

### Frozen golden corpora

`raxol_journal` ships one frozen journal per `schema_version` under
`packages/raxol_journal/priv/golden/v<version>/`; its
[README](../../packages/raxol_journal/README.md#frozen-golden-corpora) says
why. Each version is frozen exactly once, while it is current. A corpus is
produced by the real pipeline (`StreamPump.pump/3` generates the payloads,
`EmitBus` -> `EmitBridge` -> `FileStore.Writer` writes the journal) with only
`ts`, `turn_id`, and `meta.json`'s `created_at` normalized so the bytes are
reproducible.

| step | command |
| --- | --- |
| freeze the current version | `cd packages/raxol_agent && MIX_ENV=test mix run scripts/freeze_golden_journal.exs [DIR]` (`DIR` defaults to `priv/golden` of the `raxol_journal` path dependency) |
| re-pin the manifest | `elixir scripts/check_journal_goldens.exs --bless` |
| verify (CI, `format` job) | `elixir scripts/check_journal_goldens.exs` |

`scripts/check_journal_goldens.exs` enforces three rules against
`priv/golden/MANIFEST.json`: the current `@default_schema_version` has a
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

`Raxol.Agent.Session.Supervisor` is one `:rest_for_one` subtree per session,
children in dependency order: `Raxol.Agent.EmitBridge` (the per-session sink,
owning the durable journal handle and the EmitBus subscription), then
`Raxol.Core.Runtime.Lifecycle` (the per-session TEA runtime), then
`Raxol.Agent.Session` (the thin forwarder). A session crash restarts only the
session, which re-resolves the same running Lifecycle through
`Raxol.Agent.Registry` so the model survives; a bridge crash restarts the whole
subtree in dependency order, so a durable event is never emitted into a
dead-sink gap.

## The safety substrate

Spend is gated in an enforcement layer, outside the model, because a model
under adversarial input cannot be trusted to enforce it. The gate is built and
tested, and is not in the path of a session started by `raxol acp` or
`raxol mcp`.

- **Atomic spend gate.** `Raxol.Agent.SpendGate` journals
  `reserve → call → settle` per spend-bearing call, correlated by an opaque
  `cost_ref`, and fails closed: no reserve, no call. raxol_agent does not
  depend on raxol_payments, so the gate replicates the atomic `try_spend`
  shape rather than importing `Raxol.Payments.Ledger`; its records leave
  through an injected `context.emit` sink, and a raising sink propagates as
  `Raxol.Agent.SpendGate.JournalWriteError` instead of dropping a record on
  irreversible spend state. It runs only where a host puts
  `Raxol.Agent.McpSpendHook` in a context's `:tool_call_hooks` beside a
  `:spend_gate`; no non-test code does.
- `Raxol.Agent.Authorization.Engine` is the pure ALLOW/ASK/DENY reducer for
  tool calls. A string denylist is
  provably incomplete; enforce typed intent instead.

## The surface

`Raxol.Harness.Surface` is the assembled harness surface: `Projection` folds
blocks, and `Composer`, `Keymap`, `StatusStrip` and the overlay pickers sit
around them. It replays a fixture session, and
`examples/harness_fixture_demo.exs` is its process loop on a real terminal.
`append_events/2` and the `:command_sink` option are where a live session
would feed events in and take `:interrupt` and `:steer` out; nothing in the
tree drives them.

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

`raxol acp --agent <app>[:<id>]` serves a Raxol agent over that protocol on
stdio. `Raxol.Agent.ClientProtocol.Serve` parses argv, moves logs to stderr
before the transport starts (a stray stdout line is a parse error at the
client), reads and writes the `user` device, and serves until the peer
disconnects, returning an exit code: 0 on a clean disconnect. `bin/raxol-acp`
is the shim for a source checkout, because `mix` prints compile output to
stdout. `Raxol.Agent.ClientProtocol.StdioAgent` is the handler: each
`session/new` starts the named app through `Raxol.Agent.McpTools.start_owned/4`
(a required, locked journal bound to the `cwd` the editor sent and to the app)
and a `Raxol.AgentClientProtocol.Session` whose `:turn_runner` is
`Raxol.Agent.ClientProtocol.Turn`. A prompt is one turn of the agent's turn
contract (`{:acp_prompt, text, approver}`, `Raxol.Agent.Comm`), answered as one
message chunk; `session/cancel` sends the turn's `{:acp_cancel, ref}`.
`Raxol.Agent.ClientProtocol.Permission.authorizer/2` is the turn's `approver`:
it announces each tool call and asks `session/request_permission` for an action
marked `sensitive`, so a client that refuses, times out, disconnects, or
answers method-not-found denies it. `session/load` is not offered. The protocol
package is a path dependency, so `StdioAgent` compiles only when raxol_agent is
built from source with it present; a Hex install exits 1 with an explanation.

Steer does not bridge. `Raxol.AgentClientProtocol.Session` refuses every steer
with `{:error, :no_steer_channel}` unless a host injects a `SteerAdapter`, and
none ships.
