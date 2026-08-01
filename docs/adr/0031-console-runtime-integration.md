# ADR-0031: Raxol as a Virtuals ACP Console runtime

## Status

Proposed, 2026-07-29. The `raxol_console` loader is implemented and tested (`Package` parser,
`RuntimeConfig`, `Boot`/`Supervisor`/`Reconciler`, the gateway channel subtree, `Console.Bench.Adapter`,
and the `Console.Application` entrypoint), and the one non-mechanical seam is proven end to end (see
"Validation"). The remaining work is external and partner-blocked: native ACP seller registration and
the Console's package/runtime-registration contract.

Builds on the agent runtime (`Raxol.Agent.Session`, `Raxol.Agent.Stream`), the cron scheduler
(ADR-0025), the unified messaging gateway (ADR-0023), the agent skill runtime (ADR-0021), the agent
persona seam (`Raxol.Agent.SystemPrompt`), and the Virtuals ACP stack (`raxol_acp`, ADR-0016/0030).

## Context

The Virtuals ACP Console (`app.virtuals.io/acp/new`, part of EconomyOS) provisions a managed agent
runtime in a sandboxed environment. A user picks a runtime, then a template (persona plus scheduled
tasks), and the Console hosts it. Today the picker offers two open-source runtimes:

- Hermes Agent (Nous Research): self-curating memory, a large built-in tool set with MCP, and a
  built-in cron scheduler.
- OpenClaw: persona and memory in plain markdown files (`SOUL.md`, `AGENTS.md`), with messaging
  channels and ACP skills built in.

Raxol is already in this ecosystem on the selling side, not the runtime side.
`Raxol.ACP.Console.AgentOffering` (the `custom_console_agent` offering) generates deployment-ready
packages (`soul.md`, `AGENTS.md`, `tasks.json`, `skills/<name>/SKILL.md`, `manifest.json`) for Hermes
or OpenClaw. The runtime enum is a fixed `hermes | openclaw | either`
(`packages/raxol_acp/lib/raxol/acp/console/spec.ex`).

We want the inverse: Raxol itself as a third selectable runtime, with web3 capabilities native to the
runtime rather than bolted on as a skill. This is the differentiator. The incumbents talk ACP by
shelling out to a CLI; Raxol speaks the ACP v2 hook model natively (`raxol_acp`) and carries
cross-chain settlement, stealth or private payments, and spend gating (`raxol_payments`) as
first-class runtime primitives.

Three facts frame the decision:

1. Raxol already ships a native equivalent of every capability the Console advertises: persona and
   memory (`SystemPrompt`, `Agent.Memory`), cron (`Agent.Scheduler`, a superset of `tasks.json`),
   messaging channels (`raxol_gateway`), skills (the same `SKILL.md` format OpenClaw uses), and the
   ACP job stack (which the incumbents do not have natively). The work is an adapter, not new runtime
   engineering.
2. The runtime is packaged as a runtime package, not an OCI container image, matching how the Node
   incumbents are installed and run. The Console provisions the EconomyOS primitives (EVM and Solana
   wallets, agent email inbox, virtual card, ACP identity) into the runtime environment through its
   `acp-cli`, and templates do not declare a required runtime capability set. A runtime therefore does
   not advertise template compatibility or supply the primitives itself; it consumes what the `acp-cli`
   provisions.
3. The contract for adding a third-party runtime to the picker is not publicly documented, and the
   incumbents may be curated. The package format and start contract for a non-Node (BEAM) runtime, the
   interface by which the `acp-cli` hands the provisioned primitives to the runtime process, and the
   path by which a new runtime becomes selectable are all unresolved. These are external and must be
   settled with Virtuals directly, not by more design.

## Decision

Add a new deployable package, `raxol_console`, that is the inverse of `Raxol.ACP.Console.Generator`:
it loads a Console agent package and boots a running Raxol runtime on the gateway stack. ACP is wired
natively through `raxol_acp`. The one non-mechanical seam, a scheduled task running under the agent's
persona and delivering to its channels, is pure composition of primitives that already ship.

### 1. Placement: a new top-of-graph package

The loader boots a runtime, so it needs `raxol_agent` and `raxol_gateway` at runtime. `raxol_acp` has
`raxol_agent` only at compile time (through `raxol_payments`, `runtime: false`), and main `raxol` does
not depend on `raxol_agent` at all, so neither can host the loader. `raxol_console` sits above them
all, depending on `raxol_agent`, `raxol_gateway`, `raxol_acp`, `raxol_payments`, and `raxol_mcp`. It is
also the package the Console would provision: it ships as a self-contained executable (Burrito wraps
the release with an embedded ERTS, no host Erlang required) inside an npm wrapper, so an `acp-cli`
that installs Node packages installs and runs it like the incumbents. Placement and packaging are
solved together.

### 2. The loader: three pure stages plus effectful boot

- `Raxol.Console.Package.load/1` (pure): read a package directory or tarball into a `%Package{}`, or a
  typed error. Reuses the generator's format knowledge, including `Raxol.ACP.Console.Cron.valid?/1` for
  each task cron and the generator's skill-name slug regex, so a hostile `skills/../x` path cannot
  escape the workspace.
- `Raxol.Console.RuntimeConfig.build/2` (pure): merge the package (persona and behavior) with the
  deployment environment (credentials, channels, inference) into a validated `%RuntimeConfig{}`.
  `soul.md` resolves through `SystemPrompt.resolve({:file, path})` (cached by path, carrying an sha256
  identity); `AGENTS.md`, when present, appends under an operating-rules heading, because both
  `Handler.Agent` and `Stream.run` take a single `:system_prompt` binary applied to every turn.
- `Raxol.Console.Boot.start/1` (effectful, idempotent): set the agent app env, then start
  `Raxol.Agent.Supervisor` (scheduler, skills, memory), `Raxol.Gateway.Supervisor` (channels), the
  `raxol_acp` runtime, and a reconciler. App env must be set before the agent subtree starts, because
  `Raxol.Agent.Supervisor` reads it at init and starts a child only when its key is configured.

### 3. Boot target: the gateway stack

A Console agent is persona plus scheduled tasks plus channels plus skills, which maps directly onto
`raxol_gateway`. `Gateway.Supervisor` stands up `SessionRouter`, `Pairing`, and a session supervisor
as one child. `Handler.Agent` is the inbound-chat runtime, taking the resolved `soul.md` as
`:system_prompt` and the executor as `:agent_opts`. Scheduled-task output is delivered through
`Gateway.Delivery`, whose `{:home, route}` destination is documented for cron and background results.

### 4. Scheduled-task persona and delivery: composition, not new code

The scheduler already carries everything needed. `Raxol.Agent.Scheduler.Fire.runner/1` accepts a
`:system_prompt` (the resolved `soul.md`) and `:agent_opts` (the executor), and injects the job's
skills on each history-free fire. `Raxol.Agent.Scheduler.Delivery.gateway/1` routes a job's
`"platform:chat_id"` target through `Gateway.Delivery` against the connected-adapters map. Boot
composes these into the `config :raxol_agent, :scheduler` option set. No net-new runtime code is
required for this seam.

Job registration reconciles rather than blindly creates: the scheduler is DETS-persisted and replays
jobs on boot, so a reconciler diffs the desired set from `tasks.json` (keyed by task name as the stable
job id) against `Scheduler.list/1`, then creates, updates, or removes to converge. A failing operation
is reported, not raised, so one bad task cannot restart-loop the supervision tree.

### 5. ACP and EconomyOS primitives

`Raxol.Console.Supervisor` starts the `raxol_acp` seller and buyer runtime directly; on-chain writes go
through the existing `HookClient` and `ProviderAdapter` against ACP Core. The Console's `acp-cli`
provisions the EconomyOS primitives (wallet keys, email, card, ACP identity) into the runtime
environment. The split is therefore both-and: the `acp-cli` supplies the credentials, and `raxol_acp`
consumes them natively for the ACP v2 job hook model. The differentiator holds (native hooks,
cross-chain settlement, and spend gating are runtime primitives rather than a per-job CLI shell-out),
but the runtime does not route around the `acp-cli` for the primitives themselves. The interface by
which those credentials arrive is an open question (see below).

### 6. Making `:raxol` a real target and self-validating

Small edits in `raxol_acp` add the runtime: `"raxol"` in the `Console.Spec` runtime enum and type,
`Console.Generator` handling `:raxol` (emitting `AGENTS.md` as for OpenClaw, since the loader consumes
both), and `"raxol"` in the `AgentOffering` deliverables enum. `Console.Bench` is a config-injected
behaviour (`config :raxol_acp, :console_bench_module`), so a `Raxol.Console.Bench.Adapter` that boots
`Console.Boot` in a sandbox and runs the boot, prompt, and task-dry-run checks lives in `raxol_console`
and is wired by config. This avoids a compile cycle: `raxol_acp` knows only the behaviour, and the
implementation is injected from the package above it.

## Alternatives considered

- **A full TEA app per chat via `Handler.Lifecycle`** instead of `Handler.Agent`. Its upside is a
  stateful per-chat TUI or LiveView that the text-only incumbents cannot offer; its cost is that the
  package format carries no TEA app and persona threading stops being automatic. Deferred to a
  follow-up (issue #763).
- **Packaging the runtime as an OCI container image.** Rejected once the Console's packaging model was
  confirmed to be a runtime package installed and run by the `acp-cli`, matching the incumbents.

## Validation

The Stage-3 seam (a scheduled task running under the agent's persona and delivering to a channel) is
the only part that was not obviously mechanical, so it was prototyped first. A composition helper
(`Raxol.Console.Scheduler.Wiring.scheduler_opts/1`) and an end-to-end test stand up a real `Scheduler`,
fire a job, and assert two things against real `Fire`, `Stream`, `Delivery`, and the in-memory gateway
adapter, with only the LLM faked at the external boundary by a capturing backend:

1. The scheduled fire's turn includes the `soul.md` persona as a system message (persona threaded
   through `Scheduler` to `Fire` to `Stream`).
2. The result is delivered to the agent's channel via the gateway (delivery routes the
   `"platform:chat_id"` target through `Gateway.Delivery`).

Both assertions pass, confirming Stage 3 needs no new runtime code, only the composition wiring, which
graduated into `raxol_console`'s `Boot`. The loader's own suite additionally covers the `Package`
round-trip against the generator, the pure `RuntimeConfig` mapping, idempotent job reconciliation
against a real scheduler, a chat turn that dispatches a bundled MCP tool and replies on a channel, the
`Bench.Adapter` boot and dry-run checks, and the `Console.Application` boot decisions.

## Consequences

### Positive

- Raxol becomes a runtime, not just a config generator, reusing the exact package format it already
  emits. The loader is the mirror image of a generator that already ships.
- The web3 story is native: cross-chain settlement, private payments, and spend gating are runtime
  primitives rather than a skill shelling to a CLI per job. This is a concrete reason to pick Raxol
  over the incumbents and aligns with EconomyOS turning an agent into an economic actor.
- The gateway stack collapses most of the boot work. Channels, per-chat sessions, DM pairing, and cron
  delivery are existing, tested subsystems.
- A later path (issue #763) opens to a Console agent that ships a live dashboard or TUI, which the
  text-only incumbents cannot.

### Negative

- Being selectable in the picker depends on a partner agreement, not on this design. The mitigation is
  to present as the incumbents do (a package the `acp-cli` installs and runs, reading `soul.md`, with
  native ACP, cron, MCP, gateway, and health endpoints), which is useful for self-hosted Console agents
  regardless of the picker outcome.
- The built-in tool count out of the box is smaller than the incumbents'. Closing it is a curation and
  external-MCP task: the dynamic-dispatch seam (`Raxol.Agent.Action.Dynamic`) lets a runtime-discovered
  MCP tool be offered and dispatched through the same authorizer and hook chain as a module Action, and
  `Raxol.Agent.McpBundle` bundles a default server set (filesystem, fetch, git, time, sequential
  thinking) at provision time. This is not a capability gap, but it is real.
- OS-level process sandboxing is the Console's substrate, not something the runtime supplies. Raxol
  adds in-BEAM guardrails (permission, tool policy, spend gate). The boundary needs confirmation.
- A new top-of-graph package compiles main raxol and the termbox NIF as dependencies. It is outside the
  fast test loop and needs its own CI consideration.

### Risks and open questions

- **Package and start contract for a non-Node runtime.** The runtime is packaged as a Burrito-built
  self-contained binary in an npm wrapper (`packages/raxol_console/npm`), which installs and starts
  like a Node package (`npx raxol-console start`). The remaining unknown is whether the Console's
  `acp-cli` accepts this form and what manifest, if any, it expects to register a non-Node runtime.
- **Primitive injection interface.** How the `acp-cli` hands the provisioned wallet keys, email, card,
  and ACP identity to the runtime process: environment variables, a mounted secrets file, or a
  metadata endpoint. `Console.Application` reads deployment inputs (credentials, channels, inference)
  through config keys and env; the concrete source must be confirmed.
- **Adding a runtime to the picker.** Whether the list is curated by Virtuals or there is a
  manifest-and-submission path.
- **On-chain identity standard for ACP registration.** Unresolved in public sources (ERC-8004 versus
  ERC-8183). Seller registration is currently delegated outside the runtime; the scaffolding is in
  place (`Chain` registry-address fields behind a fail-closed gate, an optional `JobApi.register_agent/2`
  callback, and idempotent `Raxol.ACP.Seller.Registration.ensure_registered/3`), but the on-chain
  register call is blocked on the canonical standard, the registry address, and its ABI. Confirm before
  wiring Service Registry registration.

## References

- Deferred TEA `app_module` handler: GitHub issue #763.
- Prototype and support: `packages/raxol_gateway/test/raxol/console/scheduler_wiring_prototype_test.exs`,
  `packages/raxol_gateway/test/support/console_scheduler_wiring.ex`,
  `packages/raxol_gateway/test/support/console_capture_backend.ex`.
