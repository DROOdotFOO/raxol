# Raxol

> Recursively, [axol](https://axol.io). Forever FOSS.

[![CI](https://github.com/DROOdotFOO/raxol/actions/workflows/ci-unified.yml/badge.svg?branch=master)](https://github.com/DROOdotFOO/raxol/actions/workflows/ci-unified.yml)
[![Hex](https://img.shields.io/hexpm/v/raxol.svg)](https://hex.pm/packages/raxol)

Write one app. Render it to a terminal, a browser, or an agent.

Your application is a single [TEA](https://guide.elm-lang.org/architecture/) module (`init`, `update`, `view`) running as an [OTP](https://en.wikipedia.org/wiki/Open_Telecom_Platform) GenServer. Raxol renders that module to four surfaces from one codebase:

```
                          +---> termbox2 NIF (terminal)
                          |
  TEA module (GenServer) -+---> Phoenix LiveView (browser)
                          |
                          +---> SSH daemon (remote terminal)
                          |
                          +---> MCP tools (agents)
```

The interesting part is the runtime, not the terminal. Your app gets crash isolation per component, hot code reload without restart, distributed clustering with CRDTs, and an agent surface where LLMs interact with structured widget trees instead of scraping pixels. Bubble Tea, Ratatui, and Textual are excellent renderers. A2UI and AG-UI define agent-UI wire formats. Raxol is the runtime that renders all four surfaces from one source module.

## Built with Raxol

### Xochi

[Xochi](https://xochi.fi) is a private cross-chain DEX: intent-based swaps across 5 chains, sub-3s settlement, stealth addresses by default, ZKSAR compliance proofs. Its entire trading surface is raxol:

- **Trader terminal** serves over SSH, zero install, dark-pool aesthetic
- **Web trading UI** renders the same TEA module via LiveView
- **Solver agent surface** lets Riddler's sub-2ms solver consume auto-derived MCP tools to bid on intents
- **Ops cockpit** runs a BEAM dashboard with sensor fusion on solver health, validator peers, settlement latency

One TEA module. Four surfaces. The solver agent and the human trader interact with the same widget tree through different projections. That's the pitch nothing else in this space can match.

### foglet-bbs

[foglet-bbs](https://github.com/bmanturner/foglet-bbs) is a retro-inspired bulletin board system, SSH-only, by [Brendan Turner](https://foglet.io). Drop in:

```bash
ssh bbs.foglet.io
```

Marketing site at [bbs.foglet.io](https://bbs.foglet.io). Brendan stress-tested raxol's SSH path early on with detailed bug reports; foglet-bbs is what shook out the other end.

## Symphony: manage work, not agents

`raxol_symphony` is an Elixir/OTP port of [OpenAI Symphony](https://github.com/openai/symphony). The orchestrator polls a tracker (Linear or GitHub Issues), claims eligible issues, isolates each in a per-issue workspace, and runs a coding agent until the work reaches a workflow-defined handoff state. Two runner backends ship: `raxol_agent` (the default, wraps `Raxol.Agent.Stream`) and the upstream `codex app-server` (Port-based JSON-RPC). Six surfaces consume the same orchestrator snapshot via PubSub: terminal dashboard, LiveView, MCP tools, Telegram inline keyboards, Watch push, and a JSON API. Evidence collection -- CI status, PR comments, complexity, asciinema replays -- ships per run.

```bash
mix raxol.symphony --workflow ./WORKFLOW.md
```

## Install

```elixir
# mix.exs
def deps do
  [{:raxol, "~> 2.4"}]
end
```

Or generate a new project:

```bash
mix raxol.new my_app
```

## Hello World

```elixir
defmodule Counter do
  use Raxol.Core.Runtime.Application

  def init(_ctx), do: %{count: 0}

  def update(:inc, model), do: {%{model | count: model.count + 1}, []}
  def update(:dec, model), do: {%{model | count: model.count - 1}, []}
  def update(_, model), do: {model, []}

  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        text("Count: #{model.count}", style: [:bold]),
        row style: %{gap: 1} do
          [button("+", on_click: :inc), button("-", on_click: :dec)]
        end
      ]
    end
  end

  def subscribe(_model), do: []
end
```

That module runs three ways without changes:

```bash
# Terminal
mix run examples/getting_started/counter.exs

# LiveView (mount in your Phoenix app)
# live "/counter", Raxol.LiveView.TEALive, app: Counter

# MCP (an agent clicks the "+" button)
# session |> click("+") |> assert_widget("Count: 1")
```

The GUI-vs-TUI debate is a rendering argument. Whether your app can be consumed by agents at the same time is a runtime problem, and that's what raxol solves.

## Agents that can pay

`raxol_payments` gives agents wallets, spending controls, and three payment protocols. An agent hits a 402'd resource. The Req plugin handles the rest.

```elixir
# Agent auto-pays for a resource via Xochi cross-chain settlement
client = Req.new(base_url: "https://api.example.com")
  |> Raxol.Payments.Req.AutoPay.attach(
    wallet: {:op, "Agent Wallet"},
    protocol: :xochi,
    spending_policy: %{per_request: 50_000, session: 500_000}  # in wei
  )

{:ok, response} = Req.get(client, url: "/premium-data")
# If 402 -> wallet signs EIP-712 -> Xochi settles cross-chain -> response arrives
```

Three protocols behind one interface: x402 (Coinbase HTTP 402, same-chain), MPP (Stripe/Tempo machine payments), and Xochi (cross-chain intent settlement, 0.10-0.30% fees, stealth-capable). Per-request, per-session, and lifetime spending limits enforced by a ledger GenServer. See [Agentic Commerce docs](docs/features/AGENTIC_COMMERCE.md).

## Agent surface (MCP)

Every interactive widget automatically exposes MCP tools. Button gives you `click`, TextInput gives you `type_into`/`clear`/`get_value`. A focus lens tracks what's relevant and filters to ~15 tools per interaction, so agents work with a contextual slice of the widget tree rather than a flat dump of every possible action.

Where A2UI and AG-UI define how agents talk to UIs at the wire level, raxol generates both the UI and the agent surface from a single widget tree. Same source of truth, two projections.

```elixir
import Raxol.MCP.Test
import Raxol.MCP.Test.Assertions

session = start_session(MyApp)

session
|> type_into("search", "elixir")
|> click("submit")
|> assert_widget("results", fn w -> w[:content] != nil end)
|> stop_session()
```

`mix mcp.server` starts the MCP server on stdio for Claude Code integration.

## Why OTP matters here

Raxol's interface runtime is built on the BEAM, a VM originally designed for telephone switches. Systems that couldn't go down, couldn't lose state, and had to hot-swap code on live calls. Those constraints turn out to be exactly right for multi-surface apps.

| What you need                         | Raxol                          | Building it yourself                   |
| ------------------------------------- | ------------------------------ | -------------------------------------- |
| Same UI for human + agent             | one TEA module, four renderers | two codebases, glue layer, drift       |
| Crash one widget, keep the rest up    | OTP supervisor per component   | process-per-widget, DIY restart        |
| Deploy a fix without closing sessions | hot code reload                | full restart, reconnect                |
| Replay an incident from recording     | asciinema v2 session capture   | build your own                         |
| Multi-region coordination             | libcluster + CRDTs             | DIY discovery, DIY conflict resolution |

For the TUI-framework audience, here's the comparison you'd expect:

| Capability                     | Raxol | Ratatui | Bubble Tea |       Textual       | Ink |
| ------------------------------ | :---: | :-----: | :--------: | :-----------------: | :-: |
| Crash isolation per component  |  yes  |   --    |     --     |         --          | --  |
| Hot code reload (no restart)   |  yes  |   --    |     --     |         --          | --  |
| Same app in terminal + browser |  yes  |   --    |     --     |       partial       | --  |
| Built-in SSH serving           |  yes  |   --    |  via lib   |         --          | --  |
| AI agent runtime               |  yes  |   --    |     --     |         --          | --  |
| Distributed clustering (CRDTs) |  yes  |   --    |     --     |         --          | --  |
| Time-travel debugging          |  yes  |   --    |     --     | partial<sup>1</sup> | --  |

<sup>1</sup> Textual has devtools with CSS inspection, but not state-level time-travel.

## Try it

```bash
git clone https://github.com/DROOdotFOO/raxol.git
cd raxol && mix deps.get
mix raxol.playground          # 30 live demos, browse/search/filter
mix raxol.playground --ssh    # same thing, served over SSH (port 2222)
```

The flagship demo is a live BEAM dashboard with scheduler utilization, memory sparklines, and a process table, all updating in real time:

```bash
mix run examples/demo.exs
```

More examples:

```bash
mix run examples/getting_started/counter.exs    # Minimal counter
mix run examples/apps/file_browser.exs           # File browser with tree nav
mix run examples/apps/todo_app.ex                # Todo list
mix run examples/agents/code_review_agent.exs    # AI agent analyzing files
mix run examples/agents/agent_team.exs           # Coordinator + worker agents
mix run examples/agents/ai_cockpit.exs           # Multi-agent AI cockpit (mock)
FREE_AI=true mix run examples/agents/ai_cockpit.exs  # Real AI via LLM7.io (free)
mix run examples/swarm/cluster_demo.exs          # CRDT state sync demo
```

Other tools:

```bash
mix raxol.repl                                    # Sandboxed REPL (--sandbox strict)
mix phx.server                                    # Web playground at /playground
```

See [examples/README.md](examples/README.md) for the full learning path.

## Features

**Process isolation.** Wrap any widget in `process_component/2` and it runs in its own process. Crashes restart cleanly; the rest of the UI stays up.

**Hot code reload.** Change your `view/1`, save, the running app picks it up. No restart.

**Widgets and layout.** Button, TextInput, Table, Tree, Modal, SelectList, Checkbox, Sparkline, Charts. Keyboard-navigable with focus management. Flexbox and CSS Grid, nested freely. Virtual DOM diffing with damage tracking.

**Theming.** Named colors, RGB, 256-color, and hex, downsampled to the terminal's capability. Inline images via Kitty, Sixel, and iTerm2.

**SSH serving.** `Raxol.SSH.serve(MyApp, port: 2222)`. Each connection gets its own supervised process.

**LiveView bridge.** Same TEA app renders in Phoenix LiveView. Animation hints declared in `view/1` become CSS transitions automatically, with `prefers-reduced-motion` respected.

**Distributed swarm.** CRDTs (LWW registers, OR-sets), node monitoring, seniority-based election. Discovery via libcluster with gossip, epmd, DNS, or Tailscale.

**Sensor fusion.** Poll sensors, fuse readings with weighted averaging, render gauges and sparklines. Self-adapting layout tracks usage and recommends changes.

**Time-travel debugging.** Snapshots every `update/2` cycle: step back, forward, jump, restore. Zero cost when disabled.

**Session recording.** Captures to asciinema v2 `.cast` files with pause, seek, speed control, and auto-save on crash.

**Sandboxed REPL.** `mix raxol.repl` with three safety levels. AST-based scanning blocks dangerous operations; safe for SSH exposure in strict mode.

## Performance

Full frame in 2.1ms on Apple M1 Pro (Elixir 1.19 / OTP 27), which is 13% of the 60fps budget. In a system like Xochi where the solver loop targets sub-2ms, raxol sits within that frame budget without adding overhead to the hot path.

| What                              | Time    |
| --------------------------------- | ------- |
| Full frame (create + fill + diff) | 2.1 ms  |
| Tree diff (100 nodes)             | 4 us    |
| Cell write                        | 0.97 us |
| ANSI parse                        | 38 us   |

Unix/macOS backend uses a termbox2 NIF; Windows uses a pure Elixir driver (usable, not yet tuned). See the [benchmark suite](docs/bench/README.md).

## Accessibility

The structured widget tree already carries type, label, and state metadata on every widget. That's semantically richer than a pixel buffer, so screen reader support is a serialization step on top of existing structure rather than a redesign. On the roadmap, tracked, contributions welcome.

## Documentation

**Start here**

- [Quickstart](docs/getting-started/QUICKSTART.md)
- [Core Concepts](docs/getting-started/CORE_CONCEPTS.md)
- [Widget Gallery](docs/getting-started/WIDGET_GALLERY.md)

**Cookbook**

- [Building Apps](docs/cookbook/BUILDING_APPS.md)
- [SSH Deployment](docs/cookbook/SSH_DEPLOYMENT.md)
- [Theming](docs/cookbook/THEMING.md)
- [LiveView](docs/cookbook/LIVEVIEW_INTEGRATION.md)
- [Performance](docs/cookbook/PERFORMANCE_OPTIMIZATION.md)

**Reference**

- [Architecture](docs/core/ARCHITECTURE.md)
- [Buffer API](docs/core/BUFFER_API.md)
- [Benchmarks](docs/bench/README.md)
- [API Docs](https://hexdocs.pm/raxol)

**Advanced**

- [Agent Framework](docs/features/AGENT_FRAMEWORK.md)
- [Agentic Commerce](docs/features/AGENTIC_COMMERCE.md)
- [Sensor Fusion](docs/features/SENSOR_FUSION.md)
- [Distributed Swarm](docs/features/DISTRIBUTED_SWARM.md)
- [Recording & Replay](docs/features/RECORDING_REPLAY.md)
- [Why OTP](docs/WHY_OTP.md)

**Standalone packages** (grab just the subsystem you need):

| Package                                                    | Hex                           | What                                       |
| ---------------------------------------------------------- | ----------------------------- | ------------------------------------------ |
| [`raxol_core`](https://hex.pm/packages/raxol_core)         | `{:raxol_core, "~> 2.4"}`     | Behaviours, events, config, plugins        |
| [`raxol_terminal`](https://hex.pm/packages/raxol_terminal) | `{:raxol_terminal, "~> 2.4"}` | Terminal emulation, termbox2 NIF           |
| [`raxol_mcp`](https://hex.pm/packages/raxol_mcp)           | `{:raxol_mcp, "~> 2.4"}`      | MCP server, client, registry, test harness |
| [`raxol_agent`](https://hex.pm/packages/raxol_agent)       | `{:raxol_agent, "~> 2.4"}`    | AI agent framework                         |
| [`raxol_sensor`](https://hex.pm/packages/raxol_sensor)     | `{:raxol_sensor, "~> 2.4"}`   | Sensor fusion (zero deps)                  |
| [`raxol_payments`](https://hex.pm/packages/raxol_payments) | `{:raxol_payments, "~> 0.1"}` | Agent payments, Xochi cross-chain, stealth |
| `raxol_acp` (pre-alpha)                                    | `path: "packages/raxol_acp"`  | Virtuals Agent Commerce Protocol (sell)    |
| `raxol_symphony` (pre-alpha)                               | `path: "packages/raxol_symphony"` | Tracker-driven coding-agent orchestrator |
| [`raxol_liveview`](https://hex.pm/packages/raxol_liveview) | `{:raxol_liveview, "~> 2.4"}` | Phoenix LiveView bridge, themes, CSS       |
| [`raxol_plugin`](https://hex.pm/packages/raxol_plugin)     | `{:raxol_plugin, "~> 2.4"}`   | Plugin SDK, testing, generator             |
| [`raxol_speech`](https://hex.pm/packages/raxol_speech)     | `{:raxol_speech, "~> 0.1"}`   | TTS (say/espeak), STT (Whisper), voice cmds |
| [`raxol_telegram`](https://hex.pm/packages/raxol_telegram) | `{:raxol_telegram, "~> 0.1"}` | Telegram bot, per-chat sessions, keyboards |
| [`raxol_watch`](https://hex.pm/packages/raxol_watch)       | `{:raxol_watch, "~> 0.1"}`    | APNS/FCM push, glanceable summaries        |

## Development

```bash
git clone https://github.com/DROOdotFOO/raxol.git
cd raxol
mix deps.get
MIX_ENV=test mix test --exclude slow --exclude integration --exclude docker
mix raxol.check              # format, compile, credo, dialyzer, security, test
mix raxol.check --quick      # skip dialyzer
mix raxol.demo               # run built-in demos
```

## Origin

Raxol started as two converging ideas: a terminal for AGI, where AI agents interact with a real terminal emulator the same way humans do; and an interface for the cockpit of a Gundam Wing Suit, where fault isolation, real-time responsiveness, and sensor fusion are survival-critical. The Gundam thing sounds like a joke. Then you look at the constraint set and it's exactly what OTP was built for: systems that can't go down, can't lose state, and have to hot-swap components while running.

## License

MIT. See [LICENSE.md](LICENSE.md).
