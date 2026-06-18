# ADR-0024: Pluggable execution backends and serverless hibernation

## Status

Proposed, 2026-06-18. First of the Hermes-extraction Tier 2 ADRs (research deliverable at
`~/Desktop/hermes-extraction-report.md`, item H2.1). Hermes is the benchmark agent this work targets.
Builds on ADR-0020 (the `Raxol.Agent.Sandbox` protocol and the `CommandHook`/`ThreadLog` seams) and
the omnigent item-log (`Raxol.Agent.Conversation.{Store,Log}`).

## Context

Where an agent's shell commands and code actually run is fixed today. `Raxol.Agent.Sandbox.Shell`
(`packages/raxol_agent/lib/raxol/agent/sandbox/shell.ex`) and the `:shell` Command directive run on
the local host only. Symphony adds gating sandboxes (budget, time, rate) via the
`Raxol.Agent.Sandbox` protocol and `Sandbox.Chain.authorize/4`, but those decide *whether* a turn
runs, not *where* its effects land.

Hermes selects one of six execution backends by `terminal.backend`: `local`, `docker`
(`--cap-drop ALL`, `no-new-privileges`, pids/cpu/mem/disk limits, a single long-lived container with
`/workspace` and `/root` bind mounts), `ssh`, `singularity`, `modal` (serverless, scale-to-zero
after `container_idle_timeout`, durable state in a `modal.Volume`), and `daytona` (a persistent
cloud dev environment). Two capabilities follow from this that Raxol lacks:

### Gap 1: No isolation boundary for execution

A misbehaving or prompt-injected agent runs shell commands directly on the host. The only guard is
the `Sandbox` gating chain plus whatever command classifier a consumer writes. There is no
containerized backend where the OS itself is the boundary.

### Gap 2: No hibernate-and-resume

A long-lived agent holds a host process for its whole lifetime. There is no scale-to-zero: an idle
agent cannot release its compute and resume later with its state intact. Hermes's hibernation model
is durable conversation state in SQLite plus a sandbox volume that survives scale-to-zero, so an
idle agent costs nothing and wakes with its working directory and history.

## Decision

**Add a `Raxol.Agent.ExecutionBackend` behaviour with local, docker, and ssh implementations, then a
cloud implementation on Fly Machines whose auto-stop/auto-start is the hibernation model. Durable
state lives in `Conversation.Store` plus a mounted volume. A containerized backend is the security
boundary, so the command classifier is skipped there. All backends are opt-in; the default stays the
local shell.**

### 1. The `ExecutionBackend` behaviour

```elixir
@callback resolve(config()) :: {:ok, handle()} | {:error, term()}   # locate or create the runtime
@callback activate(handle()) :: {:ok, handle()} | {:error, term()}  # wake/start it (no-op for local)
@callback run(handle(), command(), opts()) :: {:ok, result()} | {:error, term()}
@callback terminate(handle()) :: :ok                                # stop/hibernate
@callback isolation() :: :host | :container                         # security posture
```

The `:shell` directive and `Sandbox.Shell` route through the configured backend instead of calling
the host directly. `isolation/0` lets the runtime decide whether the dangerous-command classifier
(ADR roadmap H3.3) is needed at all.

### 2. Backends shipped in order

- `Backends.Local`: the current host shell, the default. `isolation: :host`.
- `Backends.Docker`: a single long-lived container per agent, `--cap-drop ALL`,
  `--security-opt no-new-privileges`, pids/cpu/mem/disk limits, `/workspace` and `/root` bind
  mounts. `isolation: :container`.
- `Backends.Ssh`: run on a remote host over the existing SSH stack (`Raxol.SSH`). `isolation: :host`
  (the remote host is the trust boundary).
- `Backends.FlyMachines`: a Fly Machine per agent. Raxol already deploys on Fly (`fly.toml`); Fly
  Machines auto-stop/auto-start IS the hibernation model. `isolation: :container`.

### 3. Hibernation = durable state plus a volume

A hibernating agent persists its conversation to `Conversation.Store` (ETS or a durable adapter) and
its working files to a mounted volume, then `terminate/1` stops the Machine. On the next inbound
message the runtime calls `activate/1`, which starts the Machine; the volume restores `/workspace`
and `Conversation.Log` restores history. Idle agents cost nothing.

### 4. Containerized backend as the security boundary

When `isolation/0` is `:container`, the OS sandbox (dropped capabilities, no-new-privileges,
resource limits) is the boundary, so the runtime skips the host-only command classifier and SSRF
guards for that backend. Host backends keep those guards. This keeps the classifier off the hot path
exactly where the container already contains the blast radius.

## Consequences

### Positive

- **A real isolation boundary.** Containerized backends contain a misbehaving or injected agent at
  the OS level, not just at the policy layer.
- **Scale-to-zero economics.** Idle agents on Fly Machines release compute and resume with state
  intact, reusing infrastructure Raxol already runs on.
- **One contract, many runtimes.** Local, docker, ssh, and cloud share the behaviour, so a consumer
  changes one config key to move where execution lands.
- **The classifier stays off the container path.** Isolation posture is a property of the backend,
  so the runtime spends classification cost only where the OS is not the boundary.

### Negative

- **Operational surface grows.** Docker and Fly Machines add deployment, image, and lifecycle
  concerns the local shell does not have.
- **Hibernate/resume adds state-management edges** (volume attach/detach, cold-start latency on
  wake, partial-write windows on hibernate).
- **Cross-backend behavior drift.** A command that works locally may differ in a stripped container
  (missing tools, path differences).

### Mitigation

- Keep `Backends.Local` the default; every other backend is opt-in via config.
- Make `activate/1` idempotent and bound cold-start latency; checkpoint conversation state before
  `terminate/1` so a hibernate never loses the last turn.
- Document the container image contract (what tools are present) so consumers pin a known base.

### What this ADR does not decide

- **Singularity, Modal, and Daytona backends.** Local/docker/ssh plus Fly Machines cover the
  isolation and hibernation goals; other providers are later adapters against the same behaviour.
- **The dangerous-command classifier itself** (report H3.3). This ADR only decides that containerized
  backends bypass it; the classifier is a separate ADR on the Authorization engine.
- **A per-agent fleet scheduler.** Single-agent activate/hibernate only; orchestrating a fleet of
  hibernating agents is future work.

## Alternatives considered

### Reuse the terminal `Driver` backend selection

`Raxol.Terminal.Driver` already picks termbox2 vs IOTerminal by platform. Rejected: that is the
*rendering* backend (how a TUI draws), orthogonal to *where shell/code executes*. Conflating them
couples rendering to isolation.

### A generic container runtime via an external library

Pull a Docker/OCI client dependency and expose it directly. Rejected as the contract: the behaviour
must also cover ssh and Fly Machines, which are not containers. The behaviour abstracts the lifecycle
(resolve/activate/run/terminate/isolation); concrete backends use whatever client they need.

### Hibernate by serializing the whole agent process

Freeze and restore the BEAM process. Rejected: the durable state that matters is the conversation
plus the working files, both of which already have homes (`Conversation.Store`, a volume). Process
serialization is fragile and unnecessary when the state is already externalized.

## Validation

- **Existing behavior unchanged.** With no backend configured, the `:shell` directive and
  `Sandbox.Shell` run on the host exactly as today.
- **Backend contract test:** a fake in-memory `ExecutionBackend` drives resolve -> activate -> run
  -> terminate; `Sandbox.Shell` routes a command through it with no host call.
- **Docker isolation test (tagged, opt-in):** a command in the docker backend cannot exceed the
  configured pids/mem limits and cannot escalate privileges.
- **Hibernate/resume test:** an agent writes a file and a conversation turn, hibernates
  (`terminate/1`), resumes (`activate/1`), and observes both the file and the history intact.
- **Isolation-posture test:** `isolation/0` is `:container` for docker/Fly and `:host` for
  local/ssh, and the runtime skips the classifier only for the former.

## References

- `~/Desktop/hermes-extraction-report.md` (item H2.1; the Hermes backends + hibernation model)
- ADR-0020: Agent Sandbox, ThreadLog, declarative Policies (the gating `Sandbox` protocol this
  execution boundary complements)
- `packages/raxol_agent/lib/raxol/agent/sandbox/shell.ex` (the `:shell` runner that routes through
  the backend)
- `packages/raxol_agent/lib/raxol/agent/conversation/store.ex` (durable conversation state for
  hibernation)
- `Raxol.SSH` (the ssh backend transport)
- `fly.toml` (the Fly deployment Fly Machines hibernation reuses)
