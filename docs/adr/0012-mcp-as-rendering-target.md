# ADR-0012: MCP as Rendering Target

## Status
Accepted -- 2026-04-05. Implemented in `packages/raxol_mcp/` (ToolProvider, FocusLens, ContextTree, structured screenshots, stdio + SSE transports).

## Context

Raxol's MCP integration is held together with duct tape. Six tools get injected into Tidewave's ETS table via `:sys.replace_state` at startup, with a retry loop polling up to 10 times. A bash script proxies stdio to HTTP because Claude Code needs stdio and Tidewave speaks HTTP. The tools are low-level: raw keystrokes and plain-text screenshots. It works in dev only, and it's coupled to Tidewave's internals. One upstream change and it breaks.

The codebase already supports multiple rendering targets. TEA apps render to terminal (`:react`), browser (`:liveview`), templates (`:heex`), or raw output (`:raw`). The accessibility system tracks widget types, labels, and focus chains. The agent framework has its own MCP client for consuming external servers. All the pieces exist. They just aren't connected.

The real problem: MCP shouldn't be bolted onto the side. Every Raxol app is a structured widget tree with typed interactions. An AI controlling a Raxol app shouldn't send raw "j" keystrokes and parse text screenshots. It should see the widget tree, call semantic actions (click this button, type into this field), and browse model state -- the same way the terminal renderer sees cells and the LiveView renderer sees components.

## Decision

Treat MCP as a first-class rendering target. The framework derives the MCP surface -- tools, resources, prompts -- automatically from the widget tree and model. App authors write zero MCP glue code. Build a TUI app, get an AI interface for free.

### Category Theory Framing

This isn't a metaphor. The rendering targets are literally functors from the same source category:

```
TEA Model Category M = (States, Messages, compose, id)

F_term  : M -> TerminalOutput     (view -> cells -> ANSI)
F_mcp   : M -> ToolSet+Resources  (view -> widget tree -> tools)
F_tg    : M -> TelegramMessages   (model -> formatted messages)
F_voice : M -> SpeechOutput       (model -> spoken announcements)
F_watch : M -> WatchFace          (model -> compact display)
```

For any state transition (update message), all functors produce consistent outputs. One `update/2`, one model, multiple projections.

The Tool Functor composes: `T . W : M -> ToolSet` where `W` is `view/1` and `T` is the ToolProvider. For any model state, this gives us the available MCP tools. For any state transition, it gives us the tool set diff.

We use the theory for design and tests, not in the code. No `Functor` behaviours. Property-based tests verify the functor laws: incremental tool updates must match full recomputation.

### Architecture

**1. `raxol_mcp` package** (`packages/raxol_mcp/`)

New extracted package owning all MCP protocol concerns:

- `Raxol.MCP.Server` -- JSON-RPC 2.0 GenServer, tool/resource/prompt registry
- `Raxol.MCP.Transport.Stdio` -- for CLI tools (Claude Code, etc.)
- `Raxol.MCP.Transport.SSE` -- for HTTP/remote (Plug-based, no Phoenix dep)
- `Raxol.MCP.Registry` -- ETS-backed, anything can register tools/resources
- Absorbs `Agent.McpClient` -- client and server live together

Depends on `raxol_core` only. Same level as `raxol_terminal` in the dep graph:

```
raxol_mcp --> raxol_core
raxol (main) --> raxol_mcp
raxol_agent --> raxol_mcp (replaces internal McpClient)
```

Works in dev, test, and prod. No Tidewave dependency.

**2. ToolProvider behaviour** (automatic tool derivation)

Each widget type implements `Raxol.MCP.ToolProvider`:

```elixir
@callback mcp_tools(widget_state :: map()) :: [tool_def()]
@callback handle_tool_call(name :: String.t(), args :: map(), state :: map()) ::
  {:ok, result()} | {:error, reason()}
```

Built-in implementations for all existing widgets:

| Widget | Tools | What They Are |
|--------|-------|---------------|
| TextInput | type_into, clear, get_value | String state morphisms |
| Button | click | Terminal morphism (triggers effect) |
| SelectList | select, get_selected, get_options | Selection state morphisms |
| Table | sort, filter, select_row, get_rows | Query algebra on tabular data |
| Checkbox | toggle, get_checked | Boolean endomorphism |
| Tree | expand, collapse, select_node | Tree traversal morphisms |
| Modal | dismiss, confirm | Lifecycle morphisms |
| Chart | set_range, get_data, annotate | Visualization state morphisms |
| Viewport | scroll_to, get_visible_range | Window function on content |

A tree walker traverses the `view(model)` output, collects tools from each widget, namespaces by widget ID (`widget.search_input.type_into`), and registers with `MCP.Registry`. Tool set updates on every render via `tools/list_changed` notification.

**3. Focus lens** (attention-aware tool filtering)

A complex UI could expose 100+ tools. LLM tool selection degrades past ~20. The MCP server applies an attention-aware filter:

- Default: tools for focused widget + neighbors + global tools (5-10 total)
- `discover_tools` meta-tool for searching the full set by capability
- `@mcp_exclude` attribute to suppress derivation on specific widgets
- Mouse tracking feeds into the lens: hover/click events update which widget region has attention, even before keyboard focus moves there
  - Pre-exposes tools for the widget under the cursor (anticipatory surfacing)
  - Effects system (`Raxol.Effects`) renders visual feedback on hover targets -- highlights, glow, cursor trails
  - BehaviorTracker records mouse patterns (per-widget dwell, click frequency) feeding adaptive layout recommendations

**4. App-declared model projections** (MCP resources)

Apps declare which model paths to expose:

```elixir
def mcp_resources do
  [{"counter", & &1.counter}, {"status", & &1.status}]
end
```

Simple flat maps get auto-exposed (one level). Nested structures require explicit projection functions. Exposed as MCP resources at `raxol://session/{id}/model/{key}`.

The model is internal state -- not everything should be public. Projections are the "sections" the app publishes (presheaf interpretation: the app chooses which local state becomes globally visible).

**5. Context tree** (unified state view)

Assembled on demand from multiple sources:

```
Context Tree
+-- Model State (TEA model, via projections)
+-- Widget Tree (types, IDs, bounds, focus, attention)
|   +-- Available Tools (derived from widgets)
|   +-- Focus Chain (tab order, mouse attention)
+-- Agent State (models, health, pending commands)
+-- Swarm Topology (nodes, roles, latency)
+-- Notifications (accessibility queue, alerts)
+-- Session Metadata (pilot mode, dimensions, uptime)
```

Exposed as MCP resources. Streamed as diffs via SSE transport. Different agents see different subsets based on role and permissions (the presheaf structure -- each consumer gets a consistent projection).

**6. Agent-MCP symmetry**

Agents consume MCP (existing McpClient) AND serve their own Actions as MCP tools:

- Agent Action definitions auto-register as MCP tools via ToolConverter
- External systems invoke Raxol agents via MCP
- Agent discovery: `agent.list`, `agent.send`, `agent.get_model` as MCP tools
- Chain: Claude Code -> Raxol MCP -> Agent -> external MCP servers

**7. Multi-surface cockpit** (future)

The same functor pattern extends to additional surfaces:

- Telegram bridge (`raxol_telegram`): context tree changes -> Telegram messages, button presses -> TEA messages. One bot, session routing, user ID whitelist auth.
- Speech interface (`raxol_speech`): accessibility announcement queue -> spoken output, push-to-talk transcription -> TEA messages. Local Whisper for cockpit mode.
- Watch: compact glance display, tap to acknowledge alerts.

Not always in the gundam. Phone in pocket, watch on wrist. Agents keep running -- these bridges are remote viewports into the same model.

### Distributed State (Context Presheaf)

For swarm orchestration, the context tree is a presheaf over the agent topology:

```
P: AgentTopology^op -> Sets

P(node_A)     = local state visible to node A
P(node_A ^ B) = state shared between A and B
restriction   = CRDT merge operation
```

The "single source of truth" isn't a single location -- it's the global section. Every agent has a local view; CRDT merge guarantees convergence. This is why ORSet and LWWRegister are the right primitives for swarm state.

## Consequences

### Positive

- Every Raxol app is AI-controllable with zero extra code
- Semantic interactions (click_button, type_into) instead of raw keystrokes
- Works in all environments, not just dev
- Decoupled from Tidewave -- owned transport, no ETS hacking
- Same architecture extends to Telegram, speech, watch (more functors, same model)
- Test harness falls out naturally (semantic widget assertions without terminal emulation)
- Category-theoretic foundation gives us testable invariants (functor laws as property tests)
- Mouse tracking improves both human UX (hover effects) and AI UX (anticipatory tools)

### Negative

- New package to maintain (raxol_mcp)
- Dynamic tool sets are unusual for MCP clients -- some may not handle `tools/list_changed`
- Focus lens adds complexity (what's "focused" in a headless session?)
- ToolProvider behaviour is another thing widget authors need to know about

### Mitigation

- raxol_mcp depends only on raxol_core, small surface area
- Fallback to static tool list for clients that don't support dynamic tools
- Headless sessions default to "all tools visible" (no focus lens)
- Built-in ToolProvider for all standard widgets; custom widgets inherit sensible defaults
- Mouse tracking is opt-in (terminals that don't support it simply don't send events)

## Validation

- Playground demos controllable via MCP without code changes to demos
- AI cockpit example controllable from Claude Code via raxol_mcp (not Tidewave)
- Property tests verify functor laws (tool derivation consistency across state transitions)
- Tool count stays under 15 for typical apps with focus lens active
- No Tidewave dependency in production builds
- Telegram bridge can acknowledge alerts and send directives from phone

## References

- Current MCP implementation: `lib/raxol/headless/mcp_tools.ex`
- Headless session manager: `lib/raxol/headless.ex`
- Agent MCP client: `packages/raxol_agent/lib/raxol/agent/mcp_client.ex`
- Accessibility system: `packages/raxol_core/lib/raxol/core/accessibility/`
- Widget components: `lib/raxol/ui/components/`
- Tidewave endpoint: `lib/raxol/endpoint.ex`
- Effects system: `lib/raxol/effects/`
- Adaptive system: `lib/raxol/adaptive/`
- Swarm CRDTs: `lib/raxol/swarm/crdt/`
- [ADR-0001: Component-Based Architecture](0001-component-based-architecture.md)
- [ADR-0005: Runtime Plugin System Architecture](0005-runtime-plugin-system-architecture.md)
- [ADR-0008: Phoenix LiveView Integration Architecture](0008-phoenix-liveview-integration-architecture.md)
