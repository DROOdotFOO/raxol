# Raxol

> Recursively, [axol](https://axol.io). Forever FOSS.

[![CI](https://github.com/DROOdotFOO/raxol/actions/workflows/ci-unified.yml/badge.svg?branch=master)](https://github.com/DROOdotFOO/raxol/actions/workflows/ci-unified.yml)
[![Hex](https://img.shields.io/hexpm/v/raxol.svg)](https://hex.pm/packages/raxol)
[![Frame bytes per keystroke](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FDROOdotFOO%2Fraxol%2Fgh-pages%2Fscoreboard%2Fbadges%2Ftable.keystroke.bytes.json&label=frame%20bytes%2Fkeystroke)](bench/README.md#scoreboard)
[![Keystroke cost](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FDROOdotFOO%2Fraxol%2Fgh-pages%2Fscoreboard%2Fbadges%2Ftable.keystroke.work_ratio.json&label=keystroke%20cost)](bench/README.md#scoreboard)

[![raxol MCP server](https://glama.ai/mcp/servers/DROOdotFOO/raxol/badges/card.svg)](https://glama.ai/mcp/servers/DROOdotFOO/raxol)

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

Bubble Tea, Ratatui, and Textual are excellent renderers. A2UI and AG-UI define agent-UI wire formats. Raxol is the runtime that renders all four surfaces from one source module. See [Why OTP](docs/WHY_OTP.md) for the framework comparison, and [Why Raxol](docs/WHY_RAXOL.md) for how the runtime compares to Python agent stacks like Hermes and Omnigent.

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

`mix mcp.server` starts the MCP server on stdio for Claude Code integration. Editors that speak the [Agent Client Protocol](https://agentclientprotocol.com) reach a Raxol agent: `raxol acp --agent <app>[:<id>]` (`bin/raxol-acp` from a checkout) serves one on stdio. The sensitive actions an agent runs past the turn's approver cost a `session/request_permission` round trip. See [Editor ACP](docs/features/EDITOR_ACP.md).

Agent sessions sit on the **Harness**, the agent-session engine: a durable event journal (`Raxol.Agent.Journal`), a typed event contract (`Raxol.Agent.Contract`), and surface state that is a pure fold over the event stream (`Raxol.Harness.Projection`). See [Harness architecture](docs/harness/architecture.md).

The agent subsystems ship as standalone packages:

- **Pay** ([`raxol_payments`](docs/features/AGENTIC_COMMERCE.md)): wallets, ledger-enforced spending limits, and transparent auto-pay when an agent hits an HTTP 402, across five protocols (x402, MPP, Xochi cross-chain, Permit2, Riddler).
- **Earn** (`raxol_earn`): the sell side. Declare an offering, implement two callbacks, and a buyer agent discovers it, escrows funds, and settles on-chain through the [Virtuals](https://virtuals.io) ACP job lifecycle (request, negotiation, transaction, evaluation, completed), one supervised process per job. Pre-alpha.
- **Skills** ([`raxol_agent`](docs/guides/SKILL_AUTHORING.md)): reusable `SKILL.md` procedures in the agentskills.io format, which an agent lists, reads, and writes through three tools.
- **Reach** (`raxol_gateway`): one adapter contract to many chat platforms, process-per-chat sessions, DM pairing for authorization, and `/handoff` to move a conversation across platforms with its history intact.
- **Bridge** (`raxol_agent_client_protocol`): Elixir/OTP implementation of the [Agent Client Protocol](https://agentclientprotocol.com): the JSON-RPC 2.0 wire protocol between code editors and AI coding agents (the protocol Zed and a growing ecosystem speak). Bidirectional agent/client roles, pluggable transports (stdio, in-process), and durable resumable sessions (offset-based reattach/replay) as a vendor extension. Zero raxol-internal deps. Pre-alpha.

## Install

```elixir
# mix.exs
def deps do
  [{:raxol, "~> 2.7"}]
end
```

Or generate a new project:

```bash
mix raxol.new my_app
```

With [Nix](https://nixos.org), `nix develop` drops you into a shell with the full BEAM and NIF toolchain (no local Elixir install required):

```bash
nix develop github:DROOdotFOO/raxol   # dev shell with elixir, erlang, NIF + speech deps
```

## Try it

Nothing to install: [raxol.io](https://raxol.io) runs the same catalog in a
browser, one LiveView per demo. That surface is this repo's `web/` app; see
[web/README.md](web/README.md) to run it yourself. In a terminal:

```bash
git clone https://github.com/DROOdotFOO/raxol.git
cd raxol && mix deps.get
mix raxol.playground          # 42 live demos, browse/search/filter
```

The flagship demo is a live BEAM dashboard with scheduler utilization, memory sparklines, and a process table:

```bash
mix run examples/demo.exs
```

See [examples/README.md](examples/README.md) for the full learning path, including agent examples, swarm demos, and the REPL.

Headless environment (CI, containers, agents)? The whole build-and-test path needs no tty:

```bash
mix local.hex --force        # fresh machines and CI: install Hex without a prompt
mix deps.get
mix compile                  # termbox2 NIF needs make + a C compiler
SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test --exclude slow --exclude integration --exclude docker
MIX_ENV=test mix raxol.rate  # RATE: render-determinism golden suite
```

Prerequisites, the quality gate, and constrained-sandbox notes are in [Development](#development).

## Performance

Full frame in 5.0ms on Apple M1 (Elixir 1.20 / OTP 29), 31% of the 60fps budget.

| What                                     | Time    |
| ---------------------------------------- | ------- |
| Full frame (create + fill + diff)        | 5.0 ms  |
| Tree diff (100 nodes, 1 changed)         | 32 us   |
| Cell write (single)                      | 1.4 us  |
| Buffer create (80x24)                    | 0.32 us |
| Emulator ingest (parse + apply, plain)   | 1.7 ms  |
| Memory per 80x24 buffer                  | 2 KB    |

Measured 2026-08-07 at `fce2465bb` with `mix run bench/suites/comparison/framework_comparison.exs` (full mode). The ingest row is the whole emulator path (parse plus state application), not the standalone ANSI lexer, which handles plain text in under a microsecond (`mix raxol.bench parser`).

Unix/macOS backend uses a termbox2 NIF; Windows uses a pure Elixir driver (usable, not yet tuned). See the [benchmark suite](docs/bench/README.md).

## Documentation

Start with the [documentation index](docs/README.md), or jump to:

- [Quickstart](docs/getting-started/QUICKSTART.md)
- [Components](docs/getting-started/COMPONENT_GALLERY.md)
- [Surfaces](docs/guides/SURFACES.md)
- [Agent framework](docs/features/AGENT_FRAMEWORK.md)
- [Payments](docs/features/AGENTIC_COMMERCE.md)
- [$RAXOL token facts](https://raxol.io/token)
- [API docs](https://hexdocs.pm/raxol)

## Development

Working from source needs Elixir/OTP (versions in `mise.toml`) and a C
toolchain: the termbox2 NIF compiles with `make` and `cc` (on Debian/Ubuntu,
`apt-get install build-essential`). `nix develop` provides all of it in one
shell. Every command below runs headless: no terminal is required for the
build, the test suite, or the golden checks.

```bash
git clone https://github.com/DROOdotFOO/raxol.git
cd raxol
mix local.hex --force        # fresh machines and CI: install Hex without a prompt
mix deps.get
mix compile                  # builds the termbox2 NIF
SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test --exclude slow --exclude integration --exclude docker
MIX_ENV=test mix raxol.rate  # RATE: render-determinism golden suite
mix raxol.check              # full gate: format, compile, credo, dialyzer, security, docs, rate, test
mix raxol.check --quick      # skip dialyzer
mix raxol.demo               # built-in demos (needs a terminal)
```

`SKIP_TERMBOX2_TESTS=true` excludes the tests that need a real local terminal
(pty lifecycle, timing-sensitive suites); CI sets the same variable. Plain
`mix test` without the exclude flags also runs integration suites that need
external services (the workflow checkpoint tests want PostgreSQL via
`RAXOL_WORKFLOW_PG_URL`), so stick to the command above unless you have
them. In sandboxes where `HOME` is read-only, point `MIX_HOME` and
`HEX_HOME` at a writable directory before running mix.

## Origin

Raxol started as two converging ideas: a terminal for AGI, where AI agents interact with a real terminal emulator the same way humans do; and an interface for the cockpit of a Gundam Wing Suit, where fault isolation, real-time responsiveness, and sensor fusion are survival-critical. The Gundam thing sounds like a joke. Then you look at the constraint set and it's exactly what OTP was built for: systems that can't go down, can't lose state, and have to hot-swap components while running.

The longer vision is [Raxol: The Terminal For My Gundam](https://droo.foo/posts/raxol-terminal-for-the-gundam).

## Built with Raxol

**[Xochi](https://xochi.fi)** is a private cross-chain DEX (intent-based swaps across 6 chains, sub-3s settlement, stealth addresses by default, ZKSAR compliance proofs) whose entire trading surface is raxol. One Component tree projects four ways: an SSH trader terminal, a LiveView web UI, a solver-agent surface for Riddler's sub-2ms solver, and an ops cockpit running sensor fusion on solver health. The solver executes behind a dedicated fail-closed stack (buyer-pre-signed intents, ledger-enforced spend gates, deployment guards that refuse to run unconfigured), kept deliberately off the MCP surface, so no fund-moving action is reachable as a generic tool call.

**[foglet-bbs](https://github.com/bmanturner/foglet-bbs)** by [Brendan Turner](https://foglet.io) is an SSH-only retro bulletin board ([bbs.foglet.io](https://bbs.foglet.io), `ssh bbs.foglet.io`) that stress-tested raxol's SSH path into shape.

## License

MIT. See [LICENSE.md](LICENSE.md).
