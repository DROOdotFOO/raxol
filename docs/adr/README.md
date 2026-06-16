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

## Coverage

16 active ADRs covering core framework, performance, web integration, extensibility, state management, code quality, AI/MCP architecture, surface-specific admin patterns, orchestration, and the cross-layer operator-flow contract. (Numbers 0004 and 0006 are withdrawn placeholders.)
