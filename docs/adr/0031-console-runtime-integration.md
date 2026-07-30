# ADR-0031: Raxol as a Virtuals ACP Console runtime

## Status

Proposed, 2026-07-29. Builds on the agent runtime (`Raxol.Agent.Session`, `Raxol.Agent.Stream`),
the cron scheduler (ADR-0025), the unified messaging gateway (ADR-0023), the agent skill runtime
(ADR-0021), the agent persona seam (`Raxol.Agent.SystemPrompt`), and the Virtuals ACP stack
(`raxol_acp`, ADR-0016/0030). The `:raxol` runtime target and the package parser have landed and
are tested (see "Implementation status"); the Stage-3 persona and delivery seam is proven by a green
prototype in `packages/raxol_gateway/test/` (see "Validation"); the `raxol_console` loader package
and native ACP registration remain.

## Context

The Virtuals ACP Console (`app.virtuals.io/acp/new`, part of EconomyOS) provisions a managed agent
runtime in a sandboxed environment. A user picks a runtime, then a template (persona plus scheduled
tasks), and the Console hosts it. Today the picker offers two open-source runtimes:

- Hermes Agent (Nous Research): self-curating memory, 40-plus built-in tools with MCP, a built-in
  cron scheduler.
- OpenClaw: persona and memory live in plain markdown files (`SOUL.md`, `AGENTS.md`), with messaging
  channels and ACP skills built in.

Raxol is already in this ecosystem, but on the selling side, not the runtime side.
`Raxol.ACP.Console.AgentOffering` (the `custom_console_agent` offering) generates deployment-ready
packages (`soul.md`, `AGENTS.md`, `tasks.json`, `skills/<name>/SKILL.md`, `manifest.json`) for
Hermes or OpenClaw. The runtime enum is a fixed `hermes | openclaw | either`
(`packages/raxol_acp/lib/raxol/acp/console/spec.ex`).

We want the inverse: Raxol itself as a third selectable runtime, with web3 capabilities native to the
runtime rather than bolted on as a skill. This is the differentiator. Hermes and OpenClaw talk ACP by
shelling out to a CLI; Raxol speaks the ACP v2 hook model natively (`raxol_acp`) and carries
cross-chain settlement, stealth or private payments, and spend gating (`raxol_payments`) as
first-class runtime primitives.

Two facts frame the decision:

1. Raxol already ships a native equivalent of every capability the Console advertises. Persona and
   memory (`SystemPrompt`, `Agent.Memory`), cron (`Agent.Scheduler`, a superset of `tasks.json`),
   messaging channels (`raxol_gateway`), skills (the same agentskills `SKILL.md` format OpenClaw
   uses), and the ACP job stack (which the incumbents do not have natively). The work is an adapter,
   not new runtime engineering.
2. The Console's third-party runtime-registration contract is not publicly documented. There is no
   published manifest schema, container contract, or partner API for adding a runtime to the picker,
   and the incumbents may be curated. This is the one load-bearing unknown, and it is external: it
   must be resolved with Virtuals directly, not by more design.

## Decision

**Add a new deployable package, `raxol_console`, that is the inverse of `Raxol.ACP.Console.Generator`:
it loads a Console agent package and boots a running Raxol runtime on the gateway stack. ACP is wired
natively through `raxol_acp`. The one non-mechanical seam (a scheduled task running under the agent's
persona and delivering to its channels) is pure composition of primitives that already ship.**

### 1. Placement: a new top-of-graph package

The loader boots a runtime, so it needs `raxol_agent` and `raxol_gateway` at runtime. `raxol_acp`
only has `raxol_agent` at compile time (through `raxol_payments`, `runtime: false`), and main `raxol`
does not depend on `raxol_agent` at all, so neither can host it. `raxol_console` sits above them all,
depending on `raxol_agent`, `raxol_gateway`, `raxol_acp`, `raxol_payments`, and `raxol_mcp`. It is
also the container image the Console would provision, so placement and packaging are solved together.

### 2. The loader: three pure stages plus effectful boot

- `Raxol.Console.Package.load/1` (pure): read a package directory or tarball into a `%Package{}`, or
  a typed error. Reuses the generator's format knowledge, including `Raxol.ACP.Console.Cron.valid?/1`
  for each task cron and the generator's skill-name slug regex so a hostile `skills/../x` path cannot
  escape the workspace.
- `Raxol.Console.RuntimeConfig.build/2` (pure): merge the package (persona and behavior) with the
  deployment environment (credentials, channels, inference) into a validated `%RuntimeConfig{}`.
  soul.md resolves through `SystemPrompt.resolve({:file, path})` (cached by path, carries an sha256
  identity); AGENTS.md, when present, appends under an operating-rules heading, because both
  `Handler.Agent` and `Stream.run` take a single `:system_prompt` binary applied to every turn.
- `Raxol.Console.Boot.start/1` (effectful, idempotent): set the agent app env, then start
  `Raxol.Agent.Supervisor` (scheduler, skills, memory), `Raxol.Gateway.Supervisor` (channels), the
  `raxol_acp` runtime, and a reconciler. App env must be set before the agent subtree starts, because
  `Raxol.Agent.Supervisor` reads it at init and only starts a child when its key is configured.

### 3. Boot target: the gateway stack

A Console agent is persona plus scheduled tasks plus channels plus skills, which maps directly onto
`raxol_gateway`. `Gateway.Supervisor` stands up `SessionRouter`, `Pairing`, and a session
supervisor as one child. `Handler.Agent` is the inbound-chat runtime, taking the resolved soul.md as
`:system_prompt` and the executor as `:agent_opts`. Scheduled-task output is delivered through
`Gateway.Delivery`, whose `{:home, route}` destination is documented for cron and background results.
The alternative (a full TEA app per chat via `Handler.Lifecycle`) is deferred to a follow-up (issue
#763); its upside is a stateful per-chat TUI or LiveView, its cost is that the package format carries
no TEA app and persona threading stops being automatic.

### 4. Scheduled-task persona and delivery: composition, not new code

The scheduler already carries everything needed. `Raxol.Agent.Scheduler.Fire.runner/1` accepts a
`:system_prompt` (the resolved soul.md) and `:agent_opts` (the executor), and injects the job's
skills on each history-free fire. `Raxol.Agent.Scheduler.Delivery.gateway/1` routes a job's
`"platform:chat_id"` target through `Gateway.Delivery` against the connected-adapters map. Boot
composes these into the `config :raxol_agent, :scheduler` option set. No net-new runtime code is
required for this seam.

Job registration reconciles rather than blindly creates: the scheduler is DETS-persisted and replays
jobs on boot, so a reconciler diffs the desired set from `tasks.json` (keyed by task name as the
stable job id) against `Scheduler.list/1`, then creates, updates, or removes to converge.

### 5. ACP wired natively

`Raxol.Console.Supervisor` starts the `raxol_acp` seller and buyer runtime directly. Registration and
on-chain writes go through the existing `HookClient` and `ProviderAdapter` against ACP Core. There is
no `acp-cli` shell-out fallback. This keeps the web3 story native and is where Raxol exceeds the
incumbents, whose own first-class ACP support is still partial.

### 6. Making `:raxol` a real target and self-validating

Small edits in `raxol_acp` add the runtime: `"raxol"` in the `Console.Spec` runtime enum and type,
`Console.Generator` handling `:raxol` (emitting `AGENTS.md` as for OpenClaw, since the loader consumes
both), and `"raxol"` in the `AgentOffering` deliverables enum. `Console.Bench` is already a
config-injected behaviour (`config :raxol_acp, :console_bench_module`), so a `Raxol.Console.Bench.Adapter`
that boots `Console.Boot` in a sandbox and runs the existing boot, prompt, and task-dry-run checks
lives in `raxol_console` and is wired by config. This avoids a compile cycle: `raxol_acp` only knows
the behaviour, and the implementation is injected from the package above it.

## Validation

The Stage-3 seam (a scheduled task running under the agent's persona and delivering to a channel) is
the only part that was not obviously mechanical, so it was prototyped first. A composition helper
(`Raxol.Console.Scheduler.Wiring.scheduler_opts/1`) and an end-to-end test live under
`packages/raxol_gateway/test/` (the gateway package already has both `raxol_agent` and `Delivery`
compiled, so the test runs today without the not-yet-built `raxol_console`). The test stands up a real
`Scheduler`, fires a job, and asserts two things against real `Fire`, `Stream`, `Delivery`, and the
in-memory gateway adapter, with only the LLM faked at the external boundary by a capturing backend:

1. The scheduled fire's turn included the soul.md persona as a system message (persona threaded
   through `Scheduler` to `Fire` to `Stream`).
2. The result was delivered to the agent's channel via the gateway (delivery routed the
   `"platform:chat_id"` target through `Gateway.Delivery`).

Both assertions pass. The finding is that Stage 3 needs no new runtime code, only the composition
wiring, which graduates from test support into `raxol_console`'s `Boot` when the package lands.

## Implementation status

Landed 2026-07-29 (the format layer plus the Stage-3 seam; the loader package and native
registration remain):

- `:raxol` is a first-class runtime target. `Console.Spec` accepts it (enum and type),
  `Console.Generator` emits `AGENTS.md` for it as it does for OpenClaw (the `resolve_runtime`
  catch-all already passed `:raxol` through), and the `AgentOffering` deliverables enum lists it. Our
  own offering can now generate a raxol-targeted package.
- `Raxol.ACP.Console.Package` parses that package, the inverse of the generator: a pure `parse/1`
  over a `filename => binary` map plus `load/1` for a directory, reusing `Console.Cron.valid?/1` and
  the generator's single-segment skill slug (so a `skills/../escape/SKILL.md` never becomes a struct
  entry), with typed `{:invalid_package, field, detail}` errors. A generator-to-parser round-trip
  test (driven by the `Inference.Static` stub) guards the format and its parser against drift. The
  full console suite is 25 tests green.
- The Stage-3 persona and delivery seam is proven end-to-end (see "Validation").
- MCP dynamic-dispatch seam (2026-07-30): `Raxol.Agent.Action.Dynamic` is a runtime-discovered tool
  value (an external MCP tool has no Action module). `ToolConverter` offers and dispatches it through
  the SAME authorizer and tool-call hook chain as a module Action, so it is not a security bypass;
  the default authorizer still denies a `sensitive` tool, hooks can veto or transform it, and
  transformed params are re-authorized. `Dynamic.from_mcp/3` / `from_client/2` wrap a
  `Raxol.MCP.Client` server's tool listing (invoke calls `call_tool/3`). This is the piece the
  external-MCP path was missing; the full raxol_agent suite (1958) stays green.
- MCP server bundling (2026-07-30): `Raxol.Agent.McpBundle` starts a set of external MCP servers from
  specs and wraps each server's tools as `Dynamic` values, fail-open per server (a broken or
  uninstalled server is skipped, never denying the rest). `default_servers/1` is the recommended
  catalog (filesystem, fetch, git, time, sequential-thinking). Client start is injectable, so it is
  unit-tested against an in-process fake server (no npx/uvx dependency). This is step (2) of the
  40-plus route; `raxol_console`'s `Boot` will call `McpBundle.load(McpBundle.default_servers(...))`
  at provision and add the tools to the agent's `:actions`.
- ACP registration scaffolding (2026-07-30): the non-blocked structure is in place. `Chain` gains
  `service_registry_address` / `identity_registry_address` (nil until Virtuals publishes them) plus a
  `require_service_registry/1` fail-closed gate; `JobApi` gains an optional `register_agent/2`
  callback (implemented by `Mock`, unsupported-by-default on the `HTTP` adapter); and
  `Raxol.ACP.Seller.Registration.ensure_registered/3` encodes the idempotent, fail-closed
  check-then-register logic. The two Virtuals-gated pieces (the registry address and the registration
  endpoint or ABI) are isolated behind the `Chain` gate and the `JobApi` seam, so confirming them is a
  config + adapter change, not a rewrite. Not wired at boot yet: with a nil address it would only ever
  fail closed.
- `raxol_console` package scaffolding (2026-07-30): the new top-of-graph package exists and compiles
  against the full dependency chain (raxol_agent + raxol_gateway + raxol_acp, which transitively pull
  main raxol and the termbox NIF). `Raxol.Console.RuntimeConfig.build/2` is the pure package + env ->
  config mapping (persona binary from soul.md + AGENTS.md with an sha256 identity; `tasks.json` ->
  `Scheduler.create` attrs keyed by task name; default MCP servers via `McpBundle`). The proven
  Stage-3 `Scheduler.Wiring` graduated from the gateway prototype into `raxol_console` (the gateway
  copy was removed). Remaining: `Boot` / `Supervisor` / `Application` (effectful: set app env, start
  the agent + gateway subtrees, reconcile scheduler jobs) and `Console.Bench.Adapter`.
- `raxol_console` `Boot` (2026-07-30): `Raxol.Console.Boot.start/2` brings up `Raxol.Console.Supervisor`
  (`:rest_for_one`): a `Raxol.Agent.Scheduler` wired with the agent's persona + executor (`:runner`) and
  gateway delivery (`:deliver`) via `Scheduler.Wiring`, plus a `Raxol.Console.Reconciler` that converges
  the scheduler's jobs to the runtime config's `tasks.json` set once the scheduler is up.
  `Boot.reconcile_jobs/2` is the idempotent convergence (create missing, update changed, remove stale,
  keyed by task name), tested against a real scheduler. Remaining in `raxol_console`: the gateway channel
  subtree, wiring the bundled MCP tools into the gateway handler's `:actions`, a `Console.Application`
  container entrypoint, and `Console.Bench.Adapter`.

Two audit findings (2026-07-29, deep read) shape the remaining work:

- **ACP registration.** The transacting path exists (`chain.ex` with the verified `acp_core_address`,
  `HookClient`, `ProviderAdapter`) and buyer-side discovery exists (`Agent.browse_agents`;
  `JobApi.get_me` only *reads* the agent record). Seller registration is delegated out of the runtime
  today: the `acp-cli` / dashboard per RUNBOOK, and `mix acp.register_offering` only emits JSON for
  manual upload (it POSTs nowhere). Gaps: `chain.ex` has no `service_registry_address` field, there is
  no seller `register_me` / `upsert_agent` call, and no on-chain identity or reputation is modeled.
  ERC-8004 is absent from the codebase; only ERC-8183 is named, and only in `MIGRATION_V2.md` prose.
  Scaffoldable now behind the unknowns: a registry-address config field in `Chain`, a `POST /agents`
  path in `JobApi.HTTP`, and a seller self-registration `JobApi` callback reusing the existing `Auth`
  JWT (`POST /auth/agent`). Blocked on Virtuals: the on-chain `HookClient.register_agent` (needs the
  canonical standard, the registry address, and its ABI) and modeling identity/reputation. Note:
  `chain.ex` carries the fund-transfer hook at `0x0EaD2515...`, verified against `acp-node-v2`; trust
  it over other cited values.
- **Tool count.** 25 distinct built-in tool names (31 counting the `cronjob` action's internal
  verbs); the default coding agent advertises only ~9 to 10, and the MCP surface adds a fixed ~9
  (`agent.list` / `send` / `get_model`, `discover_tools`, five adaptive), so the best fixed case is
  ~34, under the advertised 40-plus. Component-tree tool derivation (ADR-0012) adds real `tools/list`
  entries per interactive widget, but they are dynamic and view-specific, not a stable product-level
  tally. `Raxol.MCP.Client` can connect to and *list* external MCP servers, but their tools are **not
  yet callable from the agent's ReAct loop**: the loop dispatches only to `Action` modules, and the
  dynamic-dispatch seam for runtime-discovered tools is a documented, unbuilt follow-up
  (`agent/code/mcp_config.ex`). So the cheapest defensible route to 40-plus is (1) build that one
  dispatch seam, then (2) bundle a default set of standard MCP servers (filesystem, fetch, git, and
  optionally time / sequential-thinking) at provision time, which clears 40-plus with real
  capabilities rather than ~15 hand-written Actions. **(1) is now built** (see the dynamic-dispatch
  seam above); (2), bundling a default server set at provision, remains.

## Consequences

### Positive

- Raxol becomes a runtime, not just a config generator, reusing the exact package format it already
  emits. The loader is the mirror image of a generator that already ships.
- The web3 differentiator is native: cross-chain settlement, private payments, and spend gating are
  runtime primitives, not a skill shelling to a CLI. This is a concrete reason to pick Raxol over the
  incumbents and aligns with EconomyOS turning an agent into an economic actor.
- The gateway stack collapses most of the boot work. Channels, per-chat sessions, DM pairing, and
  cron delivery are existing, tested subsystems.
- The multi-surface runtime opens a later path (issue #763) to a Console agent that ships a live
  dashboard or TUI, which the text-only incumbents cannot.

### Negative

- The Console third-party runtime-registration contract is undocumented and possibly gated. Being
  selectable in the picker depends on a Virtuals partner conversation, not on this design. The
  mitigation is to look like the incumbents from the outside (a container image reading soul.md,
  native ACP, Service Registry registration, cron, MCP, gateway, and health endpoints), which is
  useful for self-hosted Raxol Console agents regardless of the picker outcome.
- The built-in tool count is roughly twenty Actions against the incumbents' 40-plus. Closing this is a
  curation and external-MCP task, not a capability gap, but it is real.
- OS-level container sandboxing is the Console's substrate, not something the runtime supplies. Raxol
  provides in-BEAM guardrails (permission, tool policy, spend gate). The boundary needs confirmation
  with Virtuals.
- A new top-of-graph package adds a build target that compiles main raxol and the termbox NIF as
  dependencies. It is not part of the fast test loop and needs its own CI consideration.

### Risks and open questions

- The Console container contract: entrypoint, how the provisioned wallet, email, and card credentials
  are injected, expected ports, and health and log conventions. Undocumented; escalate.
- The on-chain identity standard for ACP is unresolved in public sources (ERC-8004 versus ERC-8183).
  Confirm before wiring Service Registry registration.
- `openclaw-acp` is archived; the current path is `@virtuals-protocol/acp-cli`. The native `raxol_acp`
  path sidesteps this, but any parity comparison should reference the live CLI, not the dead repo.

## References

- Spike memory: `project-console-runtime-integration`.
- Deferred TEA app_module handler: GitHub issue #763.
- Prototype: `packages/raxol_gateway/test/raxol/console/scheduler_wiring_prototype_test.exs`,
  `packages/raxol_gateway/test/support/console_scheduler_wiring.ex`,
  `packages/raxol_gateway/test/support/console_capture_backend.ex`.
