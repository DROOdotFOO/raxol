# Raxol

> Recursively, [axol](https://axol.io). Forever FOSS.

[![CI](https://github.com/DROOdotFOO/raxol/actions/workflows/ci-unified.yml/badge.svg?branch=master)](https://github.com/DROOdotFOO/raxol/actions/workflows/ci-unified.yml)
[![Hex](https://img.shields.io/hexpm/v/raxol.svg)](https://hex.pm/packages/raxol)

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

`mix mcp.server` starts the MCP server on stdio for Claude Code integration, and `mix raxol.code` is an interactive terminal coding agent (the axol face) with every mutating tool call gated by an ALLOW/ASK/DENY authorization engine. See the [Coding Agent](docs/features/CODING_AGENT.md).

**Code** is the coding-agent product, in two hands-on surfaces: `mix raxol.code` is the interactive terminal TUI (the axol face `≡··≡`), and `mix raxol.p` is its headless twin (prompt in on argv, answer to stdout, contract events to stderr) for pipes and CI. Every mutating tool call is gated by an ALLOW/ASK/DENY authorization engine. From a clone, one setup command and one launch:

```bash
(cd packages/raxol_agent && mix deps.get)   # once
bin/raxol-code                              # the TUI, your cwd as the workspace
```

No API key configured? The TUI opens on a provider wizard instead of failing. `/inspect` (or `mix raxol.inspect` from `packages/raxol_agent`) shows every config source the agent will use in the current directory.

Sessions are durable. Each session journals its events to disk, so `--continue` and `--resume <id>` restore the model context and the scrollback together, `--replay <id>` prints a transcript straight from the journal (`--to-offset N` stops at an offset), `/rewind` drops back to an earlier turn, and `/share` mints a signed 24-hour link to a read-only transcript that follows the session live (needs `RAXOL_SHARE_SECRET` and a host mounting `Raxol.Agent.Code.ShareLive`).

The same TUI serves over SSH: `mix raxol.code --ssh --ssh-tenants /srv/tenants` hosts many users from one daemon, each behind their own public key with their own cwd jail, session store, and spending identity (`ssh <you>@your-host -p 2222` is the whole client). Single-tenant (`--authorized-keys`) and hosted deployment (`RAXOL_SSH_CODE=true`) are in [Coding Agent](docs/features/CODING_AGENT.md).

Two unattended surfaces run the same agent. `bin/raxol-acp` (or `mix raxol.acp`) serves it over the [Agent Client Protocol](https://agentclientprotocol.com) on stdio, for editors that spawn an agent themselves; `Raxol.Agent.Harness.McpTools` registers `harness_start_session`, `harness_send_prompt`, `harness_read_transcript`, and `harness_list_sessions` with the MCP registry, so a session started by an MCP client resumes later in the TUI. Both run the read-only toolset: `write_file`, `edit_file`, and `bash` are absent where nobody is there to answer an approval prompt.

Every one of those surfaces sits on the **Harness**, the agent-session engine: a durable event journal (`Raxol.Agent.Journal`), a typed event/command contract (`Raxol.Agent.Contract`), and surface state that is a pure fold over the event stream (`Raxol.Harness.Projection`), with staged interrupt, steer, and spend/blast-radius gates underneath. The same engine can supervise external agent CLIs (`claude`, `cursor`) as readily as Raxol's own loop. See [Harness architecture](docs/harness/architecture.md).

The agent subsystems ship as standalone packages:

- **Pay** ([`raxol_payments`](docs/features/AGENTIC_COMMERCE.md)): wallets, ledger-enforced spending limits, and transparent auto-pay when an agent hits an HTTP 402, across five protocols (x402, MPP, Xochi cross-chain, Permit2, Riddler).
- **Earn** (`raxol_earn`): the sell side. Declare an offering, implement two callbacks, and a buyer agent discovers it, escrows funds, and settles on-chain through the [Virtuals](https://virtuals.io) ACP job lifecycle (request, negotiation, transaction, evaluation, completed), one supervised process per job. Pre-alpha.
- **Improve** ([`raxol_agent`](docs/features/SELF_IMPROVEMENT.md)): a solved task becomes a reusable `SKILL.md`. A background reviewer runs on a cheap model after each turn, writing durable memory and new skills without spending the live turn's latency or context.
- **Reach** (`raxol_gateway`): one adapter contract to many chat platforms, process-per-chat sessions, DM pairing for authorization, and `/handoff` to move a conversation across platforms with its history intact.
- **Orchestrate** (`raxol_symphony`): an OTP port of [OpenAI Symphony](https://github.com/openai/symphony) that polls a tracker, isolates each issue in its own workspace, and runs a coding agent, feeding six surfaces (terminal, LiveView, MCP, Telegram, Watch, JSON API) from one snapshot.
- **Bridge** (`raxol_agent_client_protocol`): Elixir/OTP implementation of the [Agent Client Protocol](https://agentclientprotocol.com): the JSON-RPC 2.0 wire protocol between code editors and AI coding agents (the protocol Zed and a growing ecosystem speak). Bidirectional agent/client roles, pluggable transports (stdio, in-process), and durable resumable sessions (offset-based reattach/replay) as a vendor extension. Zero raxol-internal deps. Pre-alpha.

## Install

```elixir
# mix.exs
def deps do
  [{:raxol, "~> 2.6"}]
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

```bash
git clone https://github.com/DROOdotFOO/raxol.git
cd raxol && mix deps.get
mix raxol.playground          # 40 live demos, browse/search/filter
```

The flagship demo is a live BEAM dashboard with scheduler utilization, memory sparklines, and a process table:

```bash
mix run examples/demo.exs
```

See [examples/README.md](examples/README.md) for the full learning path, including agent examples, swarm demos, and the sandboxed REPL.

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

Working from source needs Elixir/OTP (versions in `.tool-versions`) and a C
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

## Built with Raxol

**[Xochi](https://xochi.fi)** is a private cross-chain DEX (intent-based swaps across 6 chains, sub-3s settlement, stealth addresses by default, ZKSAR compliance proofs) whose entire trading surface is raxol. One Component tree projects four ways: an SSH trader terminal, a LiveView web UI, a solver-agent surface for Riddler's sub-2ms solver, and an ops cockpit running sensor fusion on solver health. The solver executes behind a dedicated fail-closed stack (buyer-pre-signed intents, ledger-enforced spend gates, deployment guards that refuse to run unconfigured), kept deliberately off the MCP surface, so no fund-moving action is reachable as a generic tool call.

**[foglet-bbs](https://github.com/bmanturner/foglet-bbs)** by [Brendan Turner](https://foglet.io) is an SSH-only retro bulletin board ([bbs.foglet.io](https://bbs.foglet.io), `ssh bbs.foglet.io`) that stress-tested raxol's SSH path into shape.

## License

MIT. See [LICENSE.md](LICENSE.md).
