# Raxol Demo Showcase

## Interactive Demos

### Playground

28 demos across 8 categories with live preview:

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

### AI Cockpit

Multi-agent terminal dashboard with real LLM streaming:

```bash
mix run examples/agents/ai_cockpit.exs           # Mock mode (offline)
FREE_AI=true mix run examples/agents/ai_cockpit.exs  # Real AI via LLM7.io
```

### Sensor HUD

Gauge, sparkline, and threat widgets driven by mock sensors:

```bash
mix run examples/sensor_hud_demo.exs
```

## Recording Demos

Use the demo recording script to capture asciinema recordings and convert to GIFs:

```bash
./scripts/visualization/demo_videos.sh
```

## More Examples

- `examples/getting_started/counter.exs`: minimal TEA counter
- `examples/apps/todo_app.ex`: todo list
- `examples/apps/file_browser.exs`: file browser with tree nav
- `examples/agents/code_review_agent.exs`: single AI agent
- `examples/agents/agent_team.exs`: coordinator + worker agents
- `examples/adaptive_ui_demo.exs`: behavior tracking and layout recommendations
