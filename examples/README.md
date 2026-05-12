# Raxol Examples

Learn Raxol by building. Each example is self-contained and runnable.

## Prerequisites

```bash
mix deps.get
MIX_ENV=test mix compile   # or MIX_ENV=dev mix compile
```

## Learning Path

### Beginner -- TEA Fundamentals

| Example | What you'll learn | Run |
|---------|-------------------|-----|
| [hello_world](getting_started/hello_world.exs) | The four TEA callbacks, View DSL basics, quitting | `mix run examples/getting_started/hello_world.exs` |
| [counter](getting_started/counter.exs) | Button clicks vs keyboard events, layout macros | `mix run examples/getting_started/counter.exs` |
| [clock](scripts/clock.exs) | Time-based subscriptions (`subscribe_interval`) | `mix run examples/scripts/clock.exs` |
| [subscriptions](scripts/subscriptions.exs) | Multiple independent subscriptions | `mix run examples/scripts/subscriptions.exs` |
| [event_handling](scripts/event_handling.exs) | Event struct shapes, pattern matching order | `mix run examples/scripts/event_handling.exs` |

### Intermediate -- Patterns & Architecture

| Example | What you'll learn | Run |
|---------|-------------------|-----|
| [todo_app](getting_started/todo_app.exs) | State machine modes, view decomposition | `mix run examples/getting_started/todo_app.exs` |
| [showcase_app](apps/showcase_app.exs) | Tab navigation, view dispatch by model state | `mix run examples/apps/showcase_app.exs` |
| [demo](demo.exs) | BEAM introspection, sparklines, scheduler stats | `mix run examples/demo.exs` |
| [01_hello_buffer](core/01_hello_buffer/main.exs) | Raw buffer API underneath the View DSL | `mix run examples/core/01_hello_buffer/main.exs` |
| [line_chart](charts/line_chart_demo.exs) | Braille rendering, ViewBridge for chart cells | `mix run examples/charts/line_chart_demo.exs` |

### Advanced -- Agents, Sensors, Distributed Systems

| Example | What you'll learn | Run |
|---------|-------------------|-----|
| [code_review_agent](agents/code_review_agent.exs) | Agent framework, shell commands, async processing | `mix run examples/agents/code_review_agent.exs` |
| [agent_team](agents/agent_team.exs) | Team supervision, inter-agent messaging | `mix run examples/agents/agent_team.exs` |
| [ai_cockpit](agents/ai_cockpit.exs) | Multi-agent cockpit, LLM streaming, pilot takeover | `mix run examples/agents/ai_cockpit.exs` |
| [cockpit_demo](agents/cockpit_demo.exs) | OTP supervision, crash recovery, animation hints, sparklines | `mix run examples/agents/cockpit_demo.exs` |
| [sensor_hud](sensor_hud_demo.exs) | Sensor feeds, fusion, HUD widget rendering | `mix run examples/sensor_hud_demo.exs` |
| [adaptive_ui](adaptive_ui_demo.exs) | Behavior tracking, layout recommendations, feedback | `mix run examples/adaptive_ui_demo.exs` |
| [ssh_counter](ssh/ssh_counter.exs) | SSH serving, per-connection process isolation | `mix run examples/ssh/ssh_counter.exs` |
| [hot_reload_demo](dev/hot_reload_demo.exs) | Hot code reload, no-restart updates to `view/1` | `iex -S mix run examples/dev/hot_reload_demo.exs` |
| [process_component_demo](components/process_component_demo.exs) | Per-widget process isolation with `process_component/2` | `mix run examples/components/process_component_demo.exs` |
| [cluster_demo](swarm/cluster_demo.exs) | CRDTs (LWW, OR-Set), swarm topology, overlay sync | `mix run examples/swarm/cluster_demo.exs` |

## Interactive Playground

30 widget demos across 8 categories, searchable and filterable:

```bash
mix raxol.playground                # Terminal mode
mix raxol.playground --ssh          # SSH mode (port 2222)
```

## Directory Guide

- `getting_started/` -- First examples: TEA callbacks, events, state
- `scripts/` -- Focused concept demos: subscriptions, event shapes
- `apps/` -- Multi-section apps: showcase, todo, file browser
- `agents/` -- AI agent framework: single agent, teams, cockpit
- `charts/` -- Streaming charts: line, scatter, bar, heatmap
- `core/` -- Low-level buffer and renderer API
- `ssh/` -- Serving apps over SSH
- `swarm/` -- Distributed CRDTs, discovery, topology
- `components/` -- Individual widget demos
- `advanced/` -- Advanced patterns

## Related

- [Quickstart Guide](../docs/getting-started/QUICKSTART.md) -- Build your first app step by step
- [Core Concepts](../docs/getting-started/CORE_CONCEPTS.md) -- Architecture and design philosophy
- [Widget Gallery](../docs/getting-started/WIDGET_GALLERY.md) -- All widgets with examples
