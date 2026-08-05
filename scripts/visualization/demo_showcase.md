# Raxol Demo Showcase

## Interactive Demos

### Playground

40 demos across 8 categories with live preview:

```bash
mix raxol.playground
```

Over SSH:

```bash
mix raxol.playground --ssh
# Then: ssh localhost -p 2222
```

### Flagship Demo

Live BEAM dashboard with scheduler utilization, memory sparklines, and a process table:

```bash
mix run examples/demo.exs
```

### ZERO System cockpit

The launch cockpit: boot self-check, swarm funnel deploy, a private cross-chain
settlement with streaming LLM reasoning, crash-mid-settlement ledger reconcile, and
pilot takeover.

```bash
mix run examples/agents/zero_system.exs           # Mock mode (offline)
FREE_AI=true mix run examples/agents/zero_system.exs  # Live LLM via LLM7.io
```

### Sensor HUD

Gauge, sparkline, and threat widgets driven by mock sensors:

```bash
mix run examples/subsystems/sensor_hud_demo.exs
```

## Recording Demos

Use the demo recording script to capture asciinema recordings and convert to GIFs:

```bash
./scripts/visualization/demo_videos.sh
```

## More examples

- `examples/getting_started/counter.exs`: minimal TEA counter
- `examples/getting_started/todo_app.exs`: todo list
- `examples/apps/file_browser.exs`: file browser with tree nav
- `examples/agents/zero_system.exs`: the ZERO System cockpit (mock or live LLM)
- `packages/raxol_agent/examples/agents/react_agent.exs`: single agent with tools + shell
- `packages/raxol_agent/examples/agents/agent_team.exs`: coordinator + worker agents
- `examples/subsystems/adaptive_ui_demo.exs`: behavior tracking and layout recommendations
