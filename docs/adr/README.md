# Architecture Decision Records

ADRs for the Raxol project. Each one captures a single architectural decision: why it was made, not just what was decided.

## ADR Index

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [0001](0001-component-based-architecture.md) | Component-Based Architecture | Accepted (Revised) | 2025-01-27 |
| [0002](0002-parser-performance-optimization.md) | Parser Performance Optimization | Implemented | 2025-01-27 |
| [0003](0003-terminal-emulation-strategy.md) | Terminal Emulation Strategy | Accepted | 2025-01-27 |
| 0004 | -- | Withdrawn (number reserved, never authored) | -- |
| [0005](0005-runtime-plugin-system-architecture.md) | Runtime Plugin System Architecture | Implemented | 2025-06-20 |
| 0006 | -- | Withdrawn (number reserved, never authored) | -- |
| [0007](0007-state-management-strategy.md) | State Management Strategy | Implemented | 2025-05-15 |
| [0008](0008-phoenix-liveview-integration-architecture.md) | Phoenix LiveView Integration Architecture | Implemented | 2025-05-20 |
| [0009](0009-high-performance-buffer-management.md) | High-Performance Buffer Management | Implemented | 2025-04-20 |
| [0010](0010-functional-error-handling-architecture.md) | Functional Error Handling Architecture | Implemented | 2025-02-01 |
| [0011](0011-terminal-module-consolidation.md) | Terminal Module Consolidation | Implemented | 2025-02-27 |
| [0012](0012-mcp-as-rendering-target.md) | MCP as Rendering Target | Implemented | 2026-04-05 |
| [0013](0013-event-dispatch-backpressure.md) | Event-dispatch Backpressure | Implemented | 2026-06-03 |
| [0014](0014-telegram-ai-guardian.md) | Telegram AI Guardian admin behaviour | Accepted | 2026-06-13 |
| [0015](0015-workflow-graph.md) | Workflow Graph (`Raxol.Workflow.*`) | Accepted | 2026-06-15 |
| [0016](0016-acp-job-workflow.md) | raxol_acp Job migration to `Raxol.Workflow` | Implemented (Phase A + B) | 2026-06-16 |
| [0017](0017-acp-workflow-paused-jobs.md) | Workflow paused-run query and pause-checkpoint contract | Implemented | 2026-06-16 |
| [0018](0018-operator-flow-contract.md) | Operator-flow contract for paused runs | Proposed | 2026-06-16 |
| [0019](0019-workflow-concurrency.md) | Workflow concurrency (`add_join/4` + `add_channel/4`) | Proposed | 2026-06-16 |
| [0020](0020-agent-sandbox-thread-policies.md) | Phase 26: Agent Sandbox, Thread log, declarative Policies | Proposed | 2026-06-16 |
| [0021](0021-self-improving-agents-skills-curation.md) | Self-improving agents: runtime skills + background curation | Proposed | 2026-06-17 |
| [0022](0022-memory-providers-fulltext-dialectic.md) | Memory provider stack, full-text recall, dialectic user modeling | Proposed | 2026-06-17 |
| [0023](0023-unified-messaging-gateway.md) | Unified messaging gateway (`raxol_gateway`) | Proposed | 2026-06-17 |
| [0024](0024-execution-backends-hibernation.md) | Pluggable execution backends and serverless hibernation | Proposed | 2026-06-18 |
| [0025](0025-cronjob-scheduled-tasks.md) | Cronjob scheduled-task tool | Proposed | 2026-06-18 |
| [0026](0026-execute-code-pipeline-collapse.md) | `execute_code` programmatic tool-calling | Proposed | 2026-06-18 |
| [0027](0027-delegate-task-subagents.md) | `delegate_task` summary-only subagents | Proposed | 2026-06-18 |
| [0028](0028-auxiliary-model-routing.md) | Auxiliary-model routing | Proposed | 2026-06-18 |

## Template

New ADRs should follow this structure:

```markdown
# ADR-XXXX: Title

## Status
[Proposed | Accepted | Deprecated | Superseded by ADR-YYYY]

## Context
What is the issue that we're seeing that is motivating this decision?

## Decision
What is the change that we're proposing and/or doing?

## Consequences
What becomes easier or more difficult to do because of this change?

### Positive
- List of positive consequences

### Negative
- List of negative consequences

### Mitigation
How do we mitigate the negative consequences?

## Validation
How do we validate that this decision was correct?

## References
Links to related documentation, discussions, or resources.
```

## Why ADRs?

They preserve context for why decisions were made, help new contributors understand the architecture, and give us something concrete to revisit when circumstances change.

## Adding a New ADR

1. Create a new file using the template above
2. Number it sequentially (0012, 0013, etc.)
3. Start with status "Proposed"
4. Get review, then update to "Accepted"
5. Update the index table in this file

## By Category

### Core Architecture
- [0001: Component-Based Architecture](0001-component-based-architecture.md)
- [0003: Terminal Emulation Strategy](0003-terminal-emulation-strategy.md)
- [0007: State Management Strategy](0007-state-management-strategy.md)
- [0011: Terminal Module Consolidation](0011-terminal-module-consolidation.md)

### Performance
- [0002: Parser Performance Optimization](0002-parser-performance-optimization.md)
- [0009: High-Performance Buffer Management](0009-high-performance-buffer-management.md)
- [0013: Event-dispatch Backpressure](0013-event-dispatch-backpressure.md)

### Web Integration
- [0008: Phoenix LiveView Integration Architecture](0008-phoenix-liveview-integration-architecture.md)

### Extensibility
- [0005: Runtime Plugin System Architecture](0005-runtime-plugin-system-architecture.md)

### Code Quality
- [0010: Functional Error Handling Architecture](0010-functional-error-handling-architecture.md)

### AI & MCP
- [0012: MCP as Rendering Target](0012-mcp-as-rendering-target.md)
- [0014: Telegram AI Guardian admin behaviour](0014-telegram-ai-guardian.md)

### Orchestration
- [0015: Workflow Graph](0015-workflow-graph.md)
- [0016: raxol_acp Job migration to Workflow](0016-acp-job-workflow.md)
- [0017: Workflow paused-run query and pause-checkpoint contract](0017-acp-workflow-paused-jobs.md)
- [0018: Operator-flow contract for paused runs](0018-operator-flow-contract.md)
- [0019: Workflow concurrency (joins + channels)](0019-workflow-concurrency.md)

### Agent stack
- [0020: Phase 26 — Agent Sandbox, Thread log, declarative Policies](0020-agent-sandbox-thread-policies.md)
- [0021: Self-improving agents: runtime skills + background curation](0021-self-improving-agents-skills-curation.md)
- [0022: Memory provider stack, full-text recall, dialectic user modeling](0022-memory-providers-fulltext-dialectic.md)
- [0023: Unified messaging gateway (raxol_gateway)](0023-unified-messaging-gateway.md)
- [0024: Pluggable execution backends and serverless hibernation](0024-execution-backends-hibernation.md)
- [0025: Cronjob scheduled-task tool](0025-cronjob-scheduled-tasks.md)
- [0026: execute_code programmatic tool-calling](0026-execute-code-pipeline-collapse.md)
- [0027: delegate_task summary-only subagents](0027-delegate-task-subagents.md)
- [0028: Auxiliary-model routing](0028-auxiliary-model-routing.md)

## Coverage

26 active ADRs covering core framework, performance, web integration, extensibility, state management, code quality, AI/MCP architecture, surface-specific admin patterns, orchestration, the cross-layer operator-flow contract, Workflow concurrency, the agent-stack sandbox + audit + policies primitive, self-improving agents (runtime skills + curation), the memory provider stack with full-text recall and dialectic user modeling, the unified messaging gateway, and the Hermes-extraction Tier 2 agent capabilities (execution backends + hibernation, cronjob scheduling, execute_code pipeline collapse, delegate_task subagents, and auxiliary-model routing). (Numbers 0004 and 0006 are withdrawn placeholders.)
