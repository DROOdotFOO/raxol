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

The interesting part is the runtime. Your app gets crash isolation per Component, hot code reload without restart, distributed clustering with CRDTs, and an agent surface where LLMs interact with structured Component trees instead of scraping pixels. Those are BEAM properties, from a VM built for systems that can't go down, can't lose state, and hot-swap code while running.

Bubble Tea, Ratatui, and Textual are excellent renderers. A2UI and AG-UI define agent-UI wire formats. Raxol is the runtime that renders all four surfaces from one source module. See [Why OTP](docs/WHY_OTP.md) for the full comparison.

## Built with Raxol

**[Xochi](https://xochi.fi)** is a private cross-chain DEX: intent-based swaps across 6 chains, sub-3s settlement, stealth addresses by default, ZKSAR compliance proofs. Its entire trading surface is raxol. A trader terminal serves over SSH with a dark-pool aesthetic, the same TEA module renders as a LiveView web UI, a solver-agent surface lets Riddler's sub-2ms solver consume auto-derived MCP tools to bid on intents, and an ops cockpit runs sensor fusion on solver health. The solver agent and the human trader read the same Component tree through different projections.

**[foglet-bbs](https://github.com/bmanturner/foglet-bbs)** by [Brendan Turner](https://foglet.io) is an SSH-only retro bulletin board ([bbs.foglet.io](https://bbs.foglet.io), `ssh bbs.foglet.io`) that stress-tested raxol's SSH path into shape.

## Agents

Raxol is a runtime for agents as much as for humans. Every interactive Component automatically exposes MCP tools (Button gives `click`, TextInput gives `type_into`/`clear`/`get_value`), and a focus lens filters to roughly 15 relevant tools per interaction. Where A2UI and AG-UI define how agents talk to UIs at the wire level, raxol generates the UI and the agent surface from one Component tree: same source, two projections.

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

The agent subsystems ship as standalone packages:

- **Pay** ([`raxol_payments`](docs/features/AGENTIC_COMMERCE.md)): wallets, ledger-enforced spending limits, and transparent auto-pay when an agent hits an HTTP 402, across five protocols (x402, MPP, Xochi cross-chain, Permit2, Riddler).
- **Earn** (`raxol_acp`): the sell side. Declare an offering, implement two callbacks, and a buyer agent discovers it, escrows funds, and settles on-chain through the [Virtuals](https://virtuals.io) ACP job lifecycle (request, negotiation, transaction, evaluation, completed), one supervised process per job. Pre-alpha.
- **Improve** ([`raxol_agent`](docs/features/AGENT_FRAMEWORK.md)): a solved task becomes a reusable `SKILL.md`. A background reviewer runs on a cheap model after each turn, writing durable memory and new skills without spending the live turn's latency or context.
- **Reach** (`raxol_gateway`): one adapter contract to many chat platforms, process-per-chat sessions, DM pairing for authorization, and `/handoff` to move a conversation across platforms with its history intact.
- **Orchestrate** (`raxol_symphony`): an OTP port of [OpenAI Symphony](https://github.com/openai/symphony) that polls a tracker, isolates each issue in its own workspace, and runs a coding agent, feeding six surfaces (terminal, LiveView, MCP, Telegram, Watch, JSON API) from one snapshot.

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

Full frame in 2.1ms on Apple M1 Pro (Elixir 1.19 / OTP 27), 13% of the 60fps budget.

| What                              | Time    |
| --------------------------------- | ------- |
| Full frame (create + fill + diff) | 2.1 ms  |
| Tree diff (100 nodes)             | 4 us    |
| Cell write                        | 0.97 us |
| ANSI parse                        | 38 us   |

Unix/macOS backend uses a termbox2 NIF; Windows uses a pure Elixir driver (usable, not yet tuned). See the [benchmark suite](docs/bench/README.md).

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
