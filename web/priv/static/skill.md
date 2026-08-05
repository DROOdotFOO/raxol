---
name: raxol-onboarding
description: >
  Raxol agent onboarding for external developers and AI agents.
  TRIGGER when: agent fetches raxol.io/skill.md, user asks about getting
  started with Raxol agents, user wants to add Raxol to a new project,
  or agent needs to understand Raxol capabilities for tool selection.
  DO NOT TRIGGER when: already working inside a Raxol codebase (use the
  full raxol skill instead), debugging specific Raxol internals, or
  working with other TUI frameworks.
metadata:
  author: droo
  version: "1.0.0"
  tags: raxol, agents, onboarding, mcp, elixir, otp, tui
---

# Raxol

Multi-surface runtime for Elixir on OTP. One TEA module renders to terminal, browser (LiveView), SSH, MCP, Telegram, and watch surfaces.

## Quick start

```bash
# Zero install, try it now
ssh -p 2222 playground@raxol.io

# Or add to your project
mix new my_app && cd my_app
```

```elixir
# mix.exs: pick what you need
{:raxol, "~> 2.6"}         # Full framework (TUI + rendering + widgets)
{:raxol_agent, "~> 2.6"}   # Agent framework only (teams, strategies, streaming)
{:raxol_mcp, "~> 2.6"}     # MCP server + tool derivation only
```

## What you get

- **TEA apps**: `init/1`, `update/2`, `view/1` with OTP crash isolation and hot reload
- **AI agents**: TEA apps where input comes from LLMs, supervised and streaming
- **Agent teams**: coordinator/worker groups under one supervisor
- **6 surfaces**: same module renders to terminal, browser, SSH, MCP, Telegram, watch
- **Agent payments**: autonomous transactions via x402, MPP, Xochi cross-chain
- **MCP tools**: auto-derived from widget tree; headless sessions for programmatic UI
- **Distributed swarm**: CRDTs, elections, gossip/DNS/Tailscale discovery

## See also

- `raxol` skill: full framework internals (TEA agents, process agents, orchestration)
- `droo-stack`: general Elixir patterns (pipes, pattern matching, ExUnit)
- `claude-api`: Anthropic SDK integration

## Build an agent

```elixir
# Correct: always return {model, commands} from update/2
defmodule MyAgent do
  use Raxol.Agent

  def init(_ctx), do: %{results: []}

  def update({:agent_message, _from, {:analyze, file}}, model) do
    {model, [shell("wc -l #{file}")]}
  end

  def update({:command_result, {:shell_result, %{output: out}}}, model) do
    {%{model | results: [out | model.results]}, []}
  end

  def update(_msg, model), do: {model, []}
end

# Start it
{:ok, _} = Raxol.Agent.Session.start_link(app_module: MyAgent, id: :my_agent)
```

```elixir
# Incorrect: returning bare model crashes the runtime
def update(:some_msg, model), do: model
# Correct: always return {model, commands} tuple
def update(:some_msg, model), do: {model, []}
```

## Agent teams

```elixir
Raxol.Agent.Team.start_link(
  team_id: :review_team,
  coordinator: {CodeReviewAgent, id: :reviewer},
  workers: [{TestRunnerAgent, id: :tester}]
)
```

## Agent commands

| Command | What It Does | Return Shape |
|---------|-------------|-------------|
| `shell("cmd")` | Port-based shell execution | `{:shell_result, %{output: str, exit_status: int}}` |
| `async(fn)` | Async with streaming callback | `{:async_result, result}` |
| `send_agent(id, payload)` | Inter-agent message via Registry | Arrives as `{:agent_message, from, payload}` |

## Agent strategies

| Strategy | When to Use |
|----------|------------|
| `Strategy.Direct` | Sequential action execution, deterministic pipelines |
| `Strategy.ReAct` | LLM reasoning loop with tool use, autonomous agents |

## MCP Integration

```bash
mix mcp.server   # stdio, fast startup
```

Built-in tools: `raxol_start`, `raxol_screenshot`, `raxol_send_key`, `raxol_get_model`, `raxol_stop`, `raxol_list`. Widgets also auto-derive tools via `ToolProvider`.

```json
{
  "mcpServers": {
    "raxol": {
      "command": "mix",
      "args": ["mcp.server"],
      "cwd": "/path/to/your/raxol/app"
    }
  }
}
```

## Agent payments

Agents that can pay for things autonomously:

| Protocol | Route | Gasless |
|----------|-------|---------|
| x402 | HTTP 402 micropayments (EIP-712/ERC-3009) | No |
| MPP | Stripe/Tempo machine payments | Yes |
| Xochi | Cross-chain intent settlement (stealth addresses) | Yes |

Spending controls: per-request/session/lifetime limits via `SpendingPolicy` + `Ledger`.

## Headless sessions

```elixir
# Correct: start headless, interact programmatically
{:ok, session} = Raxol.Headless.start(MyApp)
html = Raxol.Headless.screenshot(session)
Raxol.Headless.send_key(session, :tab)
model = Raxol.Headless.get_model(session)
```

```elixir
# Incorrect: using string for special keys
Raxol.Headless.send_key(session, "tab")
# Correct: atoms for special keys, strings for characters
Raxol.Headless.send_key(session, :tab)
Raxol.Headless.send_key(session, "q")
```

## Which package do I need?

| I want to... | Add this dep |
|-------------|-------------|
| Build a TUI app | `{:raxol, "~> 2.6"}` |
| Build an AI agent | `{:raxol_agent, "~> 2.6"}` |
| Serve MCP tools | `{:raxol_mcp, "~> 2.6"}` |
| Render in LiveView | `{:raxol_liveview, "~> 2.6"}` |
| Add agent payments | `{:raxol_payments, "~> 0.2"}` |
| Use sensor fusion | `{:raxol_sensor, "~> 2.6"}` (zero deps) |
| Build a plugin | `{:raxol_plugin, "~> 2.6"}` |
| Add voice commands | `{:raxol_speech, "~> 0.2"}` |
| Telegram bot surface | `{:raxol_telegram, "~> 0.2"}` |
| Watch/push surface | `{:raxol_watch, "~> 0.2"}` |

## Common pitfalls

| Mistake | Why It Fails | Fix |
|---------|-------------|-----|
| Returning bare `model` from `update/2` | Runtime expects `{model, commands}` tuple | Always return `{model, []}` |
| Not replying to `{:call, pid, ref, msg}` | Caller blocks until timeout | `send(pid, {:agent_reply, ref, reply})` |
| `send_agent` for sync request-reply | Deadlock if both agents call each other | Use async `send_agent/2`, break cycles |
| String keys for special keys in `send_key` | Sends literal character, not the key event | Use atoms: `:tab`, `:enter`, `:escape` |
| Using real LLM backends in tests | Flaky, slow, costs money | Always use `Backend.Mock` in tests |
| `view/1` returning complex tree for headless | Wastes cycles rendering to nothing | Return `nil` from `view/1` |

## Key conventions

- All agents auto-register in `Raxol.Agent.Registry` by `:id`
- Always return `{model, commands}` from `update/2`, never bare `model`
- `view/1` returning `nil` = headless (no rendering overhead)
- Use `text("string")` not `text(content: "string")` in the View DSL
- Use style attrs (`fg: :cyan, style: [:bold]`), never raw ANSI codes
- Use `Backend.Mock` in tests, never real HTTP backends

## Links

- Docs: https://hexdocs.pm/raxol
- GitHub: https://github.com/DROOdotFOO/raxol
- Hex: https://hex.pm/packages/raxol
- Playground: https://raxol.io/playground
- SSH: `ssh -p 2222 playground@raxol.io`
