# Raxol

> Recursively, [axol](https://axol.io). Forever FOSS.

[![CI](https://github.com/DROOdotFOO/raxol/actions/workflows/ci-unified.yml/badge.svg?branch=master)](https://github.com/DROOdotFOO/raxol/actions/workflows/ci-unified.yml)
[![Hex](https://img.shields.io/hexpm/v/raxol.svg)](https://hex.pm/packages/raxol)

Write one app. Render it to a terminal, a browser, an SSH session, or an agent.

Your application is a single [TEA](https://guide.elm-lang.org/architecture/) module (`init`, `update`, `view`) running as an [OTP](https://en.wikipedia.org/wiki/Open_Telecom_Platform) GenServer. Raxol renders that module to four surfaces from one codebase:

```
                          +---> Terminal (termbox2 NIF)
                          |
  TEA module (GenServer) -+---> Browser (Phoenix LiveView)
                          |
                          +---> SSH (Erlang :ssh)
                          |
                          +---> Agent (MCP tools)
```

The interesting part is the runtime, not the terminal.

Your app gets crash isolation per Component, hot code reload without restart, distributed clustering with CRDTs, and an agent surface where LLMs interact with structured Component trees instead of scraping pixels.

Bubble Tea, Ratatui, and Textual are excellent renderers. A2UI and AG-UI define agent-UI wire formats. Raxol is the runtime that renders all four surfaces from one source module.

## Built with Raxol

### Xochi

[Xochi](https://xochi.fi) is a private cross-chain DEX: intent-based swaps across 5 chains, sub-3s settlement, stealth addresses by default, ZKSAR compliance proofs. Its entire trading surface is raxol:

- **Trader terminal** serves over SSH, zero install, dark-pool aesthetic
- **Web trading UI** renders the same TEA module via LiveView
- **Solver agent surface** lets Riddler's sub-2ms solver consume auto-derived MCP tools to bid on intents
- **Ops cockpit** runs a BEAM dashboard with sensor fusion on solver health, validator peers, settlement latency

One TEA module. Four surfaces. The solver agent and the human trader interact with the same Component tree through different projections. That's the pitch nothing else in this space can match.

### foglet-bbs

[foglet-bbs](https://github.com/bmanturner/foglet-bbs) is a retro-inspired bulletin board system, SSH-only, by [Brendan Turner](https://foglet.io). Drop in:

```bash
ssh bbs.foglet.io
```

Marketing site at [bbs.foglet.io](https://bbs.foglet.io). Brendan stress-tested raxol's SSH path early on with detailed bug reports; foglet-bbs is what shook out the other end.

## Symphony

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
# session |> click("+") |> assert_component("Count: 1")
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

Every interactive Component automatically exposes MCP tools. Button gives you `click`, TextInput gives you `type_into`/`clear`/`get_value`. A focus lens tracks what's relevant and filters to ~15 tools per interaction, so agents work with a contextual slice of the Component tree rather than a flat dump of every possible action.

Where A2UI and AG-UI define how agents talk to UIs at the wire level, raxol generates both the UI and the agent surface from a single Component tree. Same source of truth, two projections.

```elixir
import Raxol.MCP.Test
import Raxol.MCP.Test.Assertions

session = start_session(MyApp)

session
|> type_into("search", "elixir")
|> click("submit")
|> assert_component("results", fn c -> c[:content] != nil end)
|> stop_session()
```

`mix mcp.server` starts the MCP server on stdio for Claude Code integration.

## Why OTP matters here

Raxol's interface runtime is built on the BEAM, a VM originally designed for telephone switches: systems that couldn't go down, couldn't lose state, and had to hot-swap code on live calls. Those constraints turn out to be exactly right for multi-surface apps. Crash one Component, the rest stays up. Ship a fix, sessions don't drop. Cluster across regions, the framework already knows how to.

See [Why OTP](docs/WHY_OTP.md) for the full breakdown, including a comparison against Ratatui, Bubble Tea, Textual, and Ink.

## Try it

```bash
git clone https://github.com/DROOdotFOO/raxol.git
cd raxol && mix deps.get
mix raxol.playground          # 30 live demos, browse/search/filter
```

The flagship demo is a live BEAM dashboard with scheduler utilization, memory sparklines, and a process table:

```bash
mix run examples/demo.exs
```

See [examples/README.md](examples/README.md) for the full learning path, including agent examples, swarm demos, and the sandboxed REPL.

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

The structured Component tree already carries type, label, and state metadata on every Component. That's semantically richer than a pixel buffer, so screen reader support is a serialization step on top of existing structure rather than a redesign. On the roadmap, tracked, contributions welcome.

## Documentation

**Start here**

- [Quickstart](docs/getting-started/QUICKSTART.md)
- [Core Concepts](docs/getting-started/CORE_CONCEPTS.md)
- [Component Gallery](docs/getting-started/COMPONENT_GALLERY.md)

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

**Standalone packages**: grab just the subsystem you need. See [PACKAGES.md](docs/PACKAGES.md) for the full table.

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
