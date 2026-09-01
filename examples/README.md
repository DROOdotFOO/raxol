# Raxol Examples

Learn Raxol by building. Each example is self-contained and runnable.

## Prerequisites

```bash
mix deps.get
MIX_ENV=test mix compile   # or MIX_ENV=dev mix compile
```

## Learning Path

### Beginner: TEA Fundamentals

| Example | What you'll learn | Run |
|---------|-------------------|-----|
| [hello_world](getting_started/hello_world.exs) | The four TEA callbacks, View DSL basics, quitting | `mix run examples/getting_started/hello_world.exs` |
| [counter](getting_started/counter.exs) | Button clicks vs keyboard events, layout macros | `mix run examples/getting_started/counter.exs` |
| [subscriptions](scripts/subscriptions.exs) | Time-based + multiple independent subscriptions | `mix run examples/scripts/subscriptions.exs` |
| [event_handling](scripts/event_handling.exs) | Event struct shapes, pattern matching order | `mix run examples/scripts/event_handling.exs` |

### Intermediate: Patterns & Architecture

| Example | What you'll learn | Run |
|---------|-------------------|-----|
| [todo_app](getting_started/todo_app.exs) | State machine modes, view decomposition | `mix run examples/getting_started/todo_app.exs` |
| [showcase_app](apps/showcase_app.exs) | Tab navigation, view dispatch by model state | `mix run examples/apps/showcase_app.exs` |
| [file_browser](apps/file_browser.exs) | Tree widget, filesystem I/O, preview pane | `mix run examples/apps/file_browser.exs` |
| [demo](demo.exs) | BEAM introspection, sparklines, scheduler stats | `mix run examples/demo.exs` |
| [chart_showcase](charts/chart_showcase.exs) | Line/bar/scatter/heatmap on a braille canvas | `mix run examples/charts/chart_showcase.exs` |

### Advanced: Agents, Sensors, Distributed Systems

| Example | What you'll learn | Run |
|---------|-------------------|-----|
| [zero_system](agents/zero_system.exs) | The ZERO System cockpit: boot self-check, swarm funnel deploy, private cross-chain settlement with streaming LLM reasoning, crash-mid-settlement ledger reconcile, pilot takeover | `mix run examples/agents/zero_system.exs` (mock) / `FREE_AI=true mix run examples/agents/zero_system.exs` (live) |
| [cluster_demo](swarm/cluster_demo.exs) | CRDTs (LWW, OR-Set), swarm topology, overlay sync | `mix run examples/swarm/cluster_demo.exs` |
| [process_component_demo](components/process_component_demo.exs) | Per-widget process isolation with `process_component/2` | `mix run examples/components/process_component_demo.exs` |
| [border_beam_demo](effects/border_beam_demo.exs) | Animated border effects (5 types, 7 palettes) | `mix run examples/effects/border_beam_demo.exs` |
| [ssh_counter](ssh/ssh_counter.exs) | SSH serving, per-connection process isolation | `mix run examples/ssh/ssh_counter.exs` |
| [hot_reload_demo](dev/hot_reload_demo.exs) | Hot code reload, no-restart updates to `view/1` | `iex -S mix run examples/dev/hot_reload_demo.exs` |
| [sensor_hud](subsystems/sensor_hud_demo.exs) | Sensor feeds, fusion, HUD widget rendering | `mix run examples/subsystems/sensor_hud_demo.exs` |
| [adaptive_ui](subsystems/adaptive_ui_demo.exs) | Behavior tracking, layout recommendations, feedback | `mix run examples/subsystems/adaptive_ui_demo.exs` |

### Agent framework examples

The agent-framework primitives run from inside the `raxol_agent` package (they need
`Raxol.Agent`, which the main app does not load). See
`packages/raxol_agent/examples/agents/`:

- `react_agent.exs`: Actions + ReAct strategy + tools + shell commands
- `agent_team.exs`: `Agent.Team` supervision + inter-agent messaging

### Agent payments

Agents that pay for things. These live in `packages/raxol_payments/examples/`
for the same reason as the agent examples: they need `Raxol.Payments`, which the
main app does not depend on. Run them from `packages/raxol_payments/`. All three
are offline and spend nothing.

- `agent_payment_tour.exs`: start here. The payment Actions an agent gets and
  which move funds, the `Router.select/1` matrix that picks x402 vs Xochi vs
  Relay, then a real x402 challenge paid end to end and the same call refused by
  the spend gate.
- `preflight.exs`: one request through the whole stack (wallet -> policy ->
  ledger -> AutoPay -> Req) against the echo server, over a socket.
- `crosschain_stealth_payment.exs`: the private cross-chain path, from
  delegation mandate through stealth Xochi intent to settlement, plus the Tron
  relay leg.

The commerce side (selling agent services on Base) is in
`packages/raxol_earn/examples/`. For real settlement that moves funds, see
`scripts/run_live_gates.sh` at the repo root.

## Interactive Playground

30 widget demos across 8 categories, searchable and filterable:

```bash
mix raxol.playground                # Terminal mode
mix raxol.playground --ssh          # SSH mode (port 2222)
```

## Directory guide

- `getting_started/`: First examples: TEA callbacks, events, state
- `scripts/`: Focused concept demos: subscriptions, event shapes
- `apps/`: Multi-section apps: showcase, todo, file browser
- `agents/`: The ZERO System cockpit (the launch demo)
- `charts/`: Streaming chart showcase (braille canvas)
- `components/`: Individual widget demos
- `effects/`: Visual effects (border beam)
- `advanced/`: Advanced patterns and small apps
- `dev/`: Developer workflow (hot reload)
- `ssh/`: Serving apps over SSH
- `swarm/`: Distributed CRDTs, discovery, topology
- `workflow/`: Saga compensation and retry strategies
- `subsystems/`: Subsystem demos (sensor fusion, adaptive UI)
- Payments and commerce live in their packages, not here: see
  `packages/raxol_payments/examples/` and `packages/raxol_earn/examples/`
- `reference/`: Low-level Buffer/Box API and LiveView (needs a Phoenix host, not `mix run`)

## Related

- [Quickstart Guide](../docs/getting-started/QUICKSTART.md): Build your first app step by step
- [Core Concepts](../docs/getting-started/CORE_CONCEPTS.md): Architecture and design philosophy
- [Component Gallery](../docs/getting-started/COMPONENT_GALLERY.md): All Components with examples
