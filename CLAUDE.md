# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Essential Commands

### Initial setup

```bash
mix deps.get
```

The termbox2 NIF source (in `packages/raxol_terminal/lib/termbox2_nif/c_src/`) is vendored directly in the repo, no git submodules needed.

### Building & Compilation

```bash
MIX_ENV=test mix compile
MIX_ENV=test mix compile --warnings-as-errors
```

### Testing

```bash
MIX_ENV=test mix test --exclude slow --exclude integration --exclude docker
MIX_ENV=test mix test test/path/to/test_file.exs      # specific file
MIX_ENV=test mix test test/path/to/test_file.exs:42   # specific line
MIX_ENV=test mix test --max-failures 5                 # limit failures
MIX_ENV=test mix test --failed                         # rerun failed
```

Note: `TMPDIR=/tmp` and `SKIP_TERMBOX2_TESTS=true` are set automatically via `.claude/settings.json`. `MIX_ENV=test` must be specified explicitly for compile and test commands.

### Code Quality

```bash
mix raxol.check               # All checks: format, compile, credo, dialyzer, security, docs, rate, test
mix raxol.check --quick       # Skip dialyzer
mix raxol.check --only format,credo  # Run specific checks only
mix raxol.check --skip test   # Skip specific checks
mix format                    # Format code
mix format --check-formatted  # Check formatting (CI)
mix credo                     # Style checks
mix dialyzer                  # Type checking
```

Packages format at their own line length (98), not the root's 80. The root
`.formatter.exs` delegates to the packages CI format-gates (`:subdirectories`),
so a root `mix format` handles those correctly. For any other package, format
from inside it: `cd packages/<pkg> && mix format`.

### Running examples

```bash
mix run examples/getting_started/counter.exs  # Known working example (TEA model)
```

Working examples: `counter.exs`, `getting_started/todo_app.exs`, `apps/showcase_app.exs`, `apps/file_browser.exs`, `demo.exs` (all TEA pattern).
`demo.exs` is the flagship demo showing dashboard layout, live stats, and OTP differentiators.

Agent examples: `agents/zero_system.exs` (the ZERO System cockpit: boot self-check, swarm funnel deploy, private cross-chain settlement with streaming LLM reasoning: mock by default, `FREE_AI=true` for LLM7.io, `AI_API_KEY`/`AI_BASE_URL` for any OpenAI-compatible provider; crash-mid-settlement ledger reconcile, pilot takeover). Framework primitives run from the raxol_agent package (`packages/raxol_agent/examples/agents/`): `react_agent.exs` (Actions + ReAct strategy + tools + shell) and `agent_team.exs` (Team supervision + inter-agent messaging).

Sensor examples: `sensor_hud_demo.exs` (3 mock sensors with gauge, sparkline, threat HUD Components).

Adaptive examples: `adaptive_ui_demo.exs` (behavior tracking, layout recommendations, feedback loop).

Playground: `mix raxol.playground` is an interactive Component catalog with 40 demos across 8 categories (input, display, feedback, navigation, overlay, layout, visualization, effects). Demos are self-contained TEA apps in `lib/raxol/playground/demos/`. Chart demos use View DSL functions directly. SSH mode: `mix raxol.playground --ssh` serves the playground over SSH (port 2222 by default). Production SSH enabled via `RAXOL_SSH_PLAYGROUND=true` env var in fly.toml.

### Coding agent

```bash
mix raxol.code                          # interactive coding-agent TUI
mix raxol.code --continue               # resume the most recent session
mix raxol.code --sessions               # list saved sessions and exit
mix raxol.code --replay ID              # print a session transcript and exit
mix raxol.code --ssh --ssh-tenants DIR  # serve multi-tenant over SSH
mix raxol.acp                           # serve over ACP on stdio (editors); bin/raxol-acp is the shim
mix raxol.inspect                       # print every config source the agent resolves here
mix raxol.p "prompt"                    # one-shot headless run: answer on stdout, JSON events on stderr
```

Tasks live in `packages/raxol_agent/lib/mix/tasks/`. `raxol.code`, `raxol.acp`, and `raxol.p` are boot shims over Mix-free modules (`Raxol.Agent.Code.Launcher`, `Raxol.Agent.ClientProtocol.Serve`, `Raxol.Agent.P`), so the Burrito-packaged CLI's `raxol code` / `raxol acp` / `raxol p` run the same code.

### Live Settlement Gates (go-live sequence)

`scripts/run_live_gates.sh` is the single launcher for the stablecoin cross-chain go-live checks. It drives every asset (USDC, USDT, USDG) across every route (`xochi` direct pay, `acp` order-through-the-storefront, `relay` EVM->Tron) from one `--asset` / `--route` flag pair, so the full launch matrix is one command. It replaces the four old per-package gate scripts.

```bash
# rehearse the whole grid, NO funds (read-only preflight per cell)
GATE_FROM_ADDRESS=0x<addr> ./scripts/run_live_gates.sh --asset all --dry-run

# funded USDC across all routes (prints plan + spend ceiling, asks to confirm)
GATE_KEY=0x<funded> GATE_FROM_ADDRESS=0x<addr> GATE_RPC_8453=https://mainnet.base.org \
  ./scripts/run_live_gates.sh --asset USDC

# just the ACP storefront path (raxol as seller) for one asset
GATE_KEY=0x<funded> ./scripts/run_live_gates.sh --asset USDC --route acp
```

Each cell runs isolated: one failure does not abort the rest, and a PASS/SKIP/FAIL matrix prints at the end (non-zero exit on any FAIL). A funded run prints the plan + worst-case spend ceiling and requires confirmation (`yes`, or `--yes`/`GATE_YES=1` for CI). Secrets/inputs via env: `GATE_KEY`, `GATE_XOCHI_TOKEN`, `GATE_RELAY_TOKEN` (both auto-read from 1Password), `GATE_RPC_<chainid>`, `GATE_FROM_ADDRESS`. Per-asset corridors, pull method, and the server-gate warnings are fixed in the script to what Riddler/Xochi support; the full flag/secret reference is the file header. Under the hood it drives the package live tests (`live_xochi*` in raxol_payments, `live_xochi_order*` / `live_relay` in raxol_earn), which are tag-excluded by default.

### Development

```bash
mix phx.server                # Start Phoenix server (includes Tidewave in dev)
mix raxol.gen.specs lib/path  # Generate type specs for private functions
mix docs                      # Generate documentation
```

### Headless MCP Tools

`mix mcp.server` starts the MCP server on stdio (for Claude Code integration). Six Raxol-specific tools are registered at startup: `raxol_start`, `raxol_screenshot`, `raxol_send_key`, `raxol_get_model`, `raxol_stop`, `raxol_list`. Tools are auto-derived from the Component tree via `Raxol.MCP.ToolProvider`. Each interactive Component exposes semantic actions (e.g., Button exposes `click`, TextInput exposes `type_into`/`clear`/`get_value`). Set `mcp_exclude: true` in Component attrs to suppress tool derivation for internal Components. When raxol_agent is loaded in the same VM, `Raxol.Agent.Harness.McpTools` also registers four coding-agent tools (`harness_start_session`, `harness_send_prompt`, `harness_read_transcript`, `harness_list_sessions`).

### Development Scripts

```bash
./scripts/dev.sh test [pattern]  # Run tests with grep filter
./scripts/dev.sh test-all        # Comprehensive test suite
./scripts/dev.sh check           # Pre-commit quality checks
./scripts/dev.sh dialyzer        # Static analysis with PLT caching
./scripts/dev.sh setup           # Environment setup
./scripts/check_toolchain.sh     # Verify the active Elixir/OTP matches .tool-versions
./scripts/acp_probe.py CMD ARGS  # Drive an ACP agent over stdio, record the wire
```

### Install paths

The packaged CLI is self-contained (Burrito wraps its own ERTS), so none of
these need Elixir at run time:

```bash
curl -fsSL https://raxol.io/install | bash   # scripts/install.sh, checksum-verified
brew install droodotfoo/tap/raxol            # scripts/gen_homebrew_formula.sh emits the formula
npm install -g raxol                         # wrapper + one per-platform binary
```

npm ships as a small `raxol` launcher plus per-platform packages
(`@raxol/cli-<platform>-<arch>`) declared as `optionalDependencies` with
`os`/`cpu` set, so an install pulls one ~68MB binary instead of all four.
`packages/raxol_cli/npm/scripts/pack.sh` builds them from `burrito_out` and
fails if the wrapper's pinned versions drift from its own. Platform packages
publish before the wrapper, since the wrapper pins them exactly.

`raxol doctor` reports build commit, packaging, runtime, whether the ACP
surface is compiled in, and every provider it resolves. `raxol setup` is the
headless provider connect (`Raxol.Agent.Setup.CLI`, which `mix raxol.setup`
also shims), so a fresh npm install can connect a provider without Mix.

### Toolchain

`.tool-versions` is authoritative (currently elixir 1.20.2-otp-29, erlang
29.0.3, via mise). Running a different Elixir than `$MIX_HOME` was populated
for does not report a version conflict; it fails inside Hex on any
`mix deps.get` with:

```
** (UndefinedFunctionError) function Enum.__in__/2 is undefined or private
```

which looks like a corrupt dependency. The usual cause is a Homebrew-first
PATH with `$MIX_HOME` pointing at a mise install. `scripts/check_toolchain.sh`
names it and prints the fix. Burrito releases must be built on this toolchain
too: `BURRITO_TARGET=macos mix release raxol_cli` builds one target instead of
four, and the unpack cache (`~/Library/Application Support/.burrito/`) has to
be cleared afterwards or the new binary silently runs the old payload. The
CLI banner carries the build commit (`raxol 0.2.6+cfa343ea7`) so a stale
binary is visible at a glance.

### Probing the ACP surface

`scripts/acp_probe.py` is a dependency-free ACP client: it spawns the agent,
runs initialize -> session/new -> session/prompt, answers
`session/request_permission`, and records every frame. It catches what unit
tests cannot see, such as non-JSON reaching stdout before frame one (which
`mix raxol.acp` still does, since Mix reconsiders the termbox2 NIF on every
boot and prints `==> raxol_terminal` to the wire; the Burrito-packaged
`raxol acp` is clean). A `__NON_JSON_STDOUT__` entry in the transcript is a
wire defect.

Note that the native-CLI backends (`:claude_native`, `:grok_native`) run their
own tool loop (`Raxol.Agent.Backend.Native` reports
`handles_tools_internally? == true`), so on those backends raxol's Actions,
per-session cwd scoping and `session/request_permission` never execute. The
tools carry the other agent's names and its refusals are indistinguishable on
the wire from ours, so conclusions drawn there are about code that never ran.
`raxol acp` says so on stderr at boot. Test those paths with an API-key
backend or at the Action level.

## Architecture

Raxol is a multi-surface application runtime for Elixir built on OTP. One TEA module renders to terminal, browser (LiveView), SSH, and MCP (agent surface). It covers the component model, agent runtime, sensor fusion, distributed swarm, and time-travel debugging. Four UI paradigms: React, LiveView, HEEx, Raw.

### Application model

**TEA (The Elm Architecture) is the canonical app model.** Applications implement `init/1`, `update/2`, and `view/1` callbacks, mapped to a GenServer via `Raxol.start_link/2` which delegates to `Raxol.Core.Runtime.Lifecycle.start_link/2`. Do not introduce competing application models (e.g., LiveView-style `mount/render`).

```elixir
use Raxol.UI, framework: :react      # React patterns (TEA)
use Raxol.UI, framework: :liveview   # Phoenix LiveView patterns
use Raxol.UI, framework: :heex       # Phoenix templates
use Raxol.UI, framework: :raw        # Direct terminal control
```

### Extracted Packages

The codebase splits into focused packages under `packages/`:

```
packages/
├── raxol_core/      # Behaviours, utils, events, config, accessibility, plugins
├── raxol_terminal/  # Terminal emulation (VT100/ANSI), termbox2 NIF, screen buffer
├── raxol_sensor/    # Sensor fusion (zero Raxol deps)
├── raxol_agent/     # AI agent framework (depends on main raxol)
├── raxol_mcp/       # MCP protocol: server, client, registry, tool derivation, test harness
├── raxol_payments/  # Agent payments: x402/MPP auto-pay, Xochi cross-chain, wallet, spending
├── raxol_earn/       # Virtuals Agent Commerce Protocol: jobs, offerings, on-chain client, SCA wallet
├── raxol_agent_client_protocol/  # Editor<->agent ACP (agentclientprotocol.com): JSON-RPC, transports, durable sessions
├── raxol_liveview/  # LiveView bridge: TerminalBridge, TEALive, TerminalComponent, themes
├── raxol_plugin/    # Plugin SDK: use macro, API facade, testing utils, generator
├── raxol_speech/    # Speech surface: TTS (say/espeak), STT (Bumblebee/Whisper), voice commands
├── raxol_telegram/  # Telegram surface: bot handler, per-chat sessions, inline keyboards, gateway adapter + update poller
├── raxol_watch/     # Watch surface: APNS/FCM push, glanceable summaries, tap-to-event actions
├── raxol_symphony/  # Tracker-driven coding-agent orchestrator (port of OpenAI Symphony)
├── raxol_gateway/   # Unified messaging gateway: adapter contract, per-chat sessions, DM pairing
├── raxol_cli/       # The `raxol` command: agent/code/p/acp/playground/new, Burrito + npm
└── raxol_console/   # Console runtime: boots a Virtuals ACP Console agent package onto the gateway
```

**Dependency graph** (arrows = "depends on"):

```
raxol (main) --> raxol_core, raxol_terminal, raxol_sensor, raxol_mcp, raxol_liveview, raxol_plugin
raxol_terminal --> raxol_core
raxol_mcp --> raxol_core
raxol_liveview --> raxol_core (+ phoenix_live_view optional)
raxol_plugin --> raxol_core
raxol_agent --> raxol, raxol_mcp (+ req and phoenix_live_view optional; raxol_agent_client_protocol as a path dep in source builds, dropped under HEX_BUILD); main does NOT depend on raxol_agent
raxol_payments --> raxol_agent (runtime: false, compile-time only)
raxol_earn --> raxol_payments, raxol_mcp (runtime: false); main does NOT depend on raxol_earn
raxol_agent_client_protocol --> (none; jason only, zero raxol deps); main does NOT depend on it
raxol_speech --> raxol_core (+ bumblebee/nx/exla optional for STT)
raxol_telegram --> raxol_core, raxol (optional, for Lifecycle runtime; + telegex optional), raxol_gateway (optional, for GatewayAdapter)
raxol_watch --> raxol_core (+ pigeon optional for APNS/FCM)
raxol_symphony --> raxol_core, raxol_agent, raxol_mcp (all optional); raxol_liveview/raxol_telegram/raxol_watch optional surfaces
raxol_gateway --> raxol_core (+ raxol_agent optional, for per-chat Conversation.Log history); main does NOT depend on raxol_gateway
raxol_cli --> raxol, raxol_agent, burrito, req
raxol_console --> raxol_agent, raxol_gateway, raxol_earn, burrito
raxol_core --> telemetry (only external dep)
raxol_sensor --> (none)
web/ (the deployed Phoenix app) --> raxol, raxol_agent, raxol_payments, req
```

`web/mix.exs` takes those three raxol deps plus `req` explicitly: main raxol keeps raxol_agent optional, `req` is optional in raxol_agent and optional deps do not propagate, and `Raxol.Application` refuses to serve the hosted coding agent without an HTTP client and a `Raxol.Payments.Ledger`.

Cross-package references use `@compile {:no_warn_undefined, Module}` and `Code.ensure_loaded?/1` guards. Struct patterns across package boundaries use map patterns (`%{field: x}`) instead of struct patterns (`%Struct{field: x}`).

**Package test commands:**

```bash
cd packages/raxol_core && MIX_ENV=test mix test
cd packages/raxol_terminal && MIX_ENV=test mix test
cd packages/raxol_sensor && MIX_ENV=test mix test
cd packages/raxol_agent && MIX_ENV=test mix test
cd packages/raxol_mcp && MIX_ENV=test mix test
cd packages/raxol_payments && MIX_ENV=test mix test
cd packages/raxol_earn && MIX_ENV=test mix test
cd packages/raxol_agent_client_protocol && MIX_ENV=test mix test
cd packages/raxol_liveview && MIX_ENV=test mix test
cd packages/raxol_plugin && MIX_ENV=test mix test
cd packages/raxol_speech && MIX_ENV=test mix test
cd packages/raxol_telegram && MIX_ENV=test mix test
cd packages/raxol_watch && MIX_ENV=test mix test
cd packages/raxol_symphony && MIX_ENV=test mix test
cd packages/raxol_gateway && MIX_ENV=test mix test
cd packages/raxol_cli && MIX_ENV=test mix test
cd packages/raxol_console && MIX_ENV=test mix test
```

### Core Layers (main raxol)

```
lib/raxol/
├── ui/              # Multi-framework UI
│   ├── components/  # Components: TextInput, Table, Button, Modal, SelectList, Checkbox, Tree, etc.
│   ├── charts/      # Streaming charts: LineChart, ScatterChart, BarChart, Heatmap, BrailleCanvas
│   ├── layout/      # Flexbox/CSS grid engines, Preparer (two-phase), ScrollContent (lazy scroll)
│   ├── rendering/   # UI rendering (TreeDiffer, Composer, Painter, DamageTracker, etc.)
│   ├── text_measure.ex  # Unicode display width facade (single source of truth)
│   └── theming/
├── core/            # Services and utilities (runtime stays here; behaviours/events/config in raxol_core)
│   ├── renderer/    # Core rendering primitives (layout, views)
│   ├── runtime/     # Plugin system, lifecycle, event management
│   └── *_compat.ex  # Compatibility layers (Buffer, Renderer, Style, Box)
├── adaptive/        # Self-evolving interface (behavior tracking, layout recommendations)
├── debug/           # Time-travel debugger (snapshot TEA state per update cycle)
├── recording/       # Session recording & replay (Asciinema v2 format)
├── swarm/           # Distributed subsystem (CRDTs, node monitoring, topology)
│   ├── discovery.ex   # libcluster wrapper with strategy presets
│   ├── strategy/      # Custom libcluster strategies (Tailscale)
│   └── crdt/          # LWWRegister, ORSet (pure functional)
├── playground/      # Interactive Component catalog (40 demos, 8 categories)
├── ssh/             # SSH serving
├── repl/            # Interactive REPL
├── performance/     # Performance monitoring, profiling, caching
├── live_view/       # README only (code moved to packages/raxol_liveview)
└── effects/         # Visual effects (CursorTrail, HoverHighlight)
```

### Key Architectural Decisions

**Terminal Backend**: Automatic platform detection in `packages/raxol_terminal/lib/raxol/terminal/driver.ex`

- Unix/macOS: Native termbox2 NIF (`packages/raxol_terminal/lib/termbox2_nif/c_src/`)
- Windows: Pure Elixir IOTerminal (`packages/raxol_terminal/lib/raxol/terminal/io_terminal.ex`)

**Compat Layer**: The `lib/raxol/core/*_compat.ex` files provide the public `Raxol.Core.*` API (Buffer, Renderer, Style, Box).

**BaseManager Pattern**: GenServers use `use Raxol.Core.Behaviours.BaseManager` for consistent lifecycle management.

**State Management**: `Raxol.Core.StateManager` (`lib/raxol/core/state_manager.ex`), which selects between functional (map-based), process-based, and ETS-backed strategies. It replaced the two duplicate `UnifiedStateManager` modules deleted in `5f2fb352d`.

**Configuration**: TOML-based (`config/raxol.example.toml` as template) with environment overrides in `config/environments/`

**Agent Framework** (in `packages/raxol_agent/`): `use Raxol.Agent` creates TEA apps for AI agents. `Agent.Session` wraps Lifecycle with `environment: :agent` (skips terminal driver and plugin manager, uses anonymous Dispatcher to avoid singleton conflicts). Agents discover each other via `Raxol.Agent.Registry` (unique Registry). `Agent.Team` is an OTP Supervisor for coordinator/worker groups. Three agent-specific Command types: `:async` (streaming sender callback), `:shell` (Port-based execution), `:send_agent` (Registry-routed inter-agent messages arriving as `{:agent_message, from, payload}`). `view/1` is optional; headless agents skip rendering entirely. Note: raxol_agent depends on main raxol, not the other way around. `Raxol.Agent.Scheduler` is an opt-in cron scheduler (`config :raxol_agent, :scheduler, [...]`): a `BaseManager` GenServer with one `Process.send_after` timer per job, recurring re-arm / one-shot retire, DETS persist + boot replay, per-owner cap, and injectable `now_fn`/`dispatch`/`runner`/`deliver`/`thread_log` (fires never run inline). `Raxol.Agent.Schedule.parse/1` parses four formats once at creation (relative `30m`, interval `every 2h`, 5-field cron, ISO timestamp) into a pure `next_fire/2`; NL schedules are lowered to one of these by the agent at creation, never an LLM per tick. The `cronjob` Action (`Raxol.Agent.Actions.Cronjob`, `create`/`list`/`update`/`pause`/`resume`/`run`/`remove`) reaches the scheduler via `context[:scheduler]` and blocks `create`/`run` when `context[:in_cron]` is set. Each fire runs a fresh, history-free agent via `Raxol.Agent.Scheduler.Fire` (skills injected from `Skills.Store`) and delivers through `Raxol.Agent.Scheduler.Delivery`: `gateway/1` routes a `"platform:chat_id"` target via `Raxol.Gateway.Delivery` behind a `Code.ensure_loaded?` guard (raxol_agent does not depend on raxol_gateway), `local/1` posts to an in-process callback. `Raxol.Agent.P` is the headless one-shot runner (the `raxol -p` surface: prompt on argv, answer on stdout, one JSON contract event per stderr line; exit 0/1/2/64/143). It contains no Mix calls, so `mix raxol.p` (a boot shim) and the Burrito-packaged CLI's `raxol p` share the same code path. Its env contract is `Raxol.Agent.BenchmarkProfile` (`RAXOL_MODEL` provider/model, `RAXOL_PROFILE=benchmark` forces allow-all tools + skills off and announces itself as the first stderr line, `RAXOL_MAX_TURNS`, `RAXOL_MAX_COST_USD` requiring `RAXOL_COST_PER_MTOK_IN`/`_OUT`, `RAXOL_TRAJECTORY_PATH`; all parsed fail-closed, CLI flags win over env). `Raxol.Agent.SignalTrap` turns SIGTERM into a flushed exit 143 and `Raxol.Agent.Trajectory` writes a `raxol-trajectory/1` JSON on every exit path. Burrito's zig launcher does NOT forward signals to the BEAM: harness/timeout contexts must enter through `packages/raxol_cli/tbench/launch.sh`, which forwards TERM/INT/HUP via /proc and restores the tty.

**Coding Agent** (in `packages/raxol_agent/lib/raxol/agent/code/`): `Raxol.Agent.Code.App` is the TEA coding-agent TUI (per-call tool approval, plan mode, 22 slash commands), launched by `Raxol.Agent.Code.Launcher.main/2`. Every session appends to a durable journal (`Raxol.Agent.Journal.FileStore`: one directory per session under `~/.raxol/sessions/`, framed JSONL segments plus a `HEAD` sidecar); only the owning `Writer` heals a torn tail, via `Reader.resume_scan/1`, so replaying cannot disturb a live session. `Raxol.Agent.Code.Replay` folds that journal through `Raxol.Harness.Projection` for `--replay` (`--to-offset N` replays a prefix), respecting the rewind markers `/rewind` writes; `Raxol.Agent.Code.Inspection` backs both `mix raxol.inspect` and `/inspect`. `Raxol.Agent.Code.Tenant.app_opts/2` gives multi-tenant SSH hosting one directory per tenant (`ssh/authorized_keys`, a `work/` cwd jail, its own session store and journal base, spending identity `"ssh:<user>"`); `jail: true` disables the shell tool, since a jail confines only the fs tools. `Raxol.Application` serves this on `RAXOL_SSH_CODE` (default port 2223) and refuses to start without `RAXOL_SSH_CODE_TENANTS`, raxol_agent, an HTTP client, and a `RAXOL_SSH_CODE_BUDGET_USD` ledger. `Raxol.Agent.Code.CostLedger` meters LLM spend into `Raxol.Payments.Ledger` (priced by `Raxol.Agent.LlmPrices`, longest model-name prefix wins); an exhausted budget halts the running turn, and an unpriced model fails closed once a ledger and policy are wired. `Raxol.Agent.Code.ShareToken` mints HMAC-SHA256 expiring read-only links with the session id AND tenant scope inside the signed bytes; `Raxol.Agent.Code.ShareLive` (compile-gated on phoenix_live_view) replays them and follows the tail via `Raxol.Agent.Reattach`. `Raxol.Agent.Code.McpLoader` turns `.mcp.json` servers into session-scoped tools owned by a janitor that monitors the session, so clients and their subprocesses die with it. Two headless surfaces run the same loop: `Raxol.Agent.ClientProtocol.Serve` + `StdioAgent` (ACP over stdio for editors; exits 0 on clean peer disconnect) and `Raxol.Agent.Harness.McpTools` (still read-only, pending the MCP authorizer). The ACP surface carries the FULL toolset: `Raxol.Agent.ClientProtocol.Permission.authorizer/2` gates every `sensitive: true` Action on a `session/request_permission` round trip, injected per turn by `TurnRunner.with_permission_gate/3` as the context's `:tool_authorizer`. Reads are not gated. It is fail-closed on the DECISION rather than the toolset: `Ctx.request_permission/4` already collapses timeout/error/disconnect/racing-cancel to `:cancelled`, and this narrows further, denying a `:selected` that names an option we never offered. ACP has no permission capability to negotiate, so a client that does not implement the method answers method-not-found, which denies writes and leaves reads working. `Serve.apply_requested_model/2` honours `HARBOR_ACP_REQUESTED_MODEL` (harbor's litellm-style `provider/model`), since nothing on the ACP wire carries a model and a benchmark otherwise reports a model it never used; `--backend`/`--model` win and suppress it whole, and a set-but-unparseable value is refused. ACP sessions are DURABLE: ids are minted by `Raxol.Agent.SessionKey` (the one authority, shared with the TUI, since the id is a journal directory and a client hands it back to resume), and every `session/update` the `TurnRunner` delivers is also appended to that session's journal through the single `deliver/2` site, recorded as the notification itself under `family: :acp` so a replay re-sends the same frames rather than rebuilding them from a second vocabulary. `StdioAgent` advertises `loadSession` and implements `session/load`: the capability is load-bearing, not decoration, because `Capabilities.negotiated?/2` resolves it against the agent's own advertised `AgentCapabilities` and a non-negotiated method is refused with -32601 before decode. Load validates the id BEFORE reading (`FileStore.open/2` validates, `read_records/2` joins onto the base unsanitized), answers an unknown id with -32602 rather than an empty replay, and binds a Session so the next prompt continues. Conversation context is derived from that journal, not held in the runner: `Raxol.Agent.Stream`'s react loop reports `messages` on `{:done, ...}` so tool calls and results survive a resume, and each `turn_completed` records the turn's CONTRIBUTION (a whole-conversation snapshot per turn makes an append-only journal grow with the square of the turn count). Only completed turns contribute. Note `--replay`/`Projection` fold `family: :acp` records as `:opaque` for now, and an ACP session has no `Code.Store` record, so it does not appear in `/sessions` or `--resume`. Fs tools decide containment on the real path (`Raxol.Agent.Actions.Fs.resolve/2`), and grep/glob re-check every walked path, so a symlink out of the sandbox is skipped. See `docs/features/CODING_AGENT.md`.

**Agent Payments** (in `packages/raxol_payments/`): Agents that can pay for things. Two wallet backends behind `Raxol.Payments.Wallet`: `Wallets.Env` (key from env var) and `Wallets.Op` (key from 1Password via GenServer). Five protocols behind `Raxol.Payments.Protocol`: `Protocols.X402` (Coinbase x402, EIP-712/ERC-3009 signing), `Protocols.MPP` (Stripe/Tempo machine payments), `Protocols.Xochi` (cross-chain intent settlement, agent default), `Protocols.Permit2` (Permit2 `PermitWitnessTransferFrom` signing for Riddler's `/order`), and `Protocols.Riddler` (deprecated, delegates to Xochi). `Raxol.Payments.Req.AutoPay` is a Req response step that handles HTTP 402 flows transparently. `SpendingPolicy` + `Ledger` (ETS-backed GenServer) + `SpendingHook` (CommandHook) enforce per-request/session/lifetime spending limits; both the `SpendGate` (Actions) and `SpendingHook` (Pay directives) reserve atomically via `Ledger.try_spend` and reject non-positive/non-finite amounts. Fund-moving deployments fail closed with `require_policy` and `require_checkpoint` (context flags or `config :raxol_payments`); a missing checkpoint otherwise emits `[:raxol, :payments, :xochi, :unchecked_settlement]`, and a stranded poll returns `%Failure{reason: :stranded}`. Twelve Agent Actions cover wallet info, quotes, transfers, spending status, history, Xochi Mandate lifecycle (`payment_create_mandate` / `payment_list_mandates` / `payment_revoke_mandate`), Xochi intents (`payment_execute_xochi_intent` / `payment_poll_xochi_status`), and the Tron relay rail (`payment_execute_relay_transfer` / `payment_poll_relay_status`). `Raxol.Payments.Mandate` is a per-request EIP-712 Xochi delegation envelope (digest verified byte-for-byte against viem); `Mandate.Store` is a singleton ETS+optional-DETS holder; `Raxol.Payments.Req.Mandate` is the outbound Req plugin that attaches `X-Xochi-Delegation` on Xochi-host URLs. Depends on raxol_agent at compile time only (`runtime: false`). See `docs/features/AGENTIC_COMMERCE.md`.

**Privacy & Stealth** (in `packages/raxol_payments/`): `Xochi.Stealth` implements ERC-5564/ERC-6538 stealth addresses (~300 LOC, secp256k1). ECDH derivation, view tag scanning (256x speedup), domain-separated key derivation, meta-address encode/decode. `Pxe.Client` is a JSON-RPC 2.0 client for the Aztec Private eXecution Environment (shielded settlement). `PrivacyTier` maps trust scores to privacy tiers (Glass Cube model, 6 tiers). `Zksar` verifies ZKSAR attestation proofs (6 ZK proof types). `Zksar.TrustScore` aggregates with diminishing returns. Router is attestation-aware. Riddler solver wiring (ADR-0005) is complete on both sides.

**Payment Protocol Routing**: `Raxol.Payments.Router.select/1` picks the protocol. Same-chain HTTP 402 goes to x402/MPP (auto-pay). Cross-chain goes to Xochi (cash-positive, tier fees 0.10-0.40%). Privacy (stealth/shielded) also goes to Xochi. The intent flow: `get_quote/2` -> `execute/3` (wallet signs EIP-712) -> `poll_status/3`. `Xochi.Client` talks to the Xochi API (`/api/intent/quote`, `/api/intent/execute`, `/api/intent/:id/status`). Riddler solves intents behind the scenes. `Protocols.Riddler` + `Riddler.Client` give direct solver access (Commerce API, B2B only; don't use for agent payments, it's cash-negative). See `../riddler/docs/architecture/decisions/0005-xochi-integration.md` for the rationale.

**Agent Commerce Protocol** (in `packages/raxol_earn/`, pre-alpha, `0.2.0`): Elixir/OTP-native implementation of the Virtuals ACP for selling agent services on Base. The v1 memo model was fully retired (seller-stack migration Phases 1-4, 2026-07; see `MIGRATION_V2.md`); the active runtime is the v2 hook/event model. One supervised `Raxol.Earn.JobSession` per active job, registered by `{chain_id, job_id}` via `JobSession.Registry` + `JobSession.Supervisor` (transient restart). It is a pure state machine: role-aware status, a chronological entry log, subscriber notifications via `{Raxol.Earn.JobSession, {chain_id, job_id}, entry}`, and a canonical transition telemetry event `[:raxol, :earn, :job_session, :transition]` (metadata `%{chain_id, job_id, role, action, from, to}`, consumed cross-package by `raxol_symphony`'s Resumer). `Raxol.Earn.JobSession.Status` is the status enum (replaces the deleted `Job.StateMachine`): `:open -> :budget_set -> :funded -> :submitted -> :completed` plus `:rejected`/`:expired`; `apply_event/3` applies an OBSERVED on-chain/SSE status directly, bypassing role + adjacency gating. On-chain writes go through `Raxol.Earn.HookClient` -> the active `AgenticCommerceV3` core via an injected `Raxol.Earn.ProviderAdapter` (`SCA` sponsored ERC-4337 UserOps, `JSONRPC` EOA, or `Mock`). `Raxol.Earn.JobSession.Provider` is the seller-side driver: per lifecycle step it invokes the offering `Handler` (via `JobSession.HandlerSeam`), writes the hook call on-chain (the COMMIT POINT, since a failed write leaves the session untouched), then mirrors the resulting status via `apply_event`. `Raxol.Earn.Wallet.NonceServer` serializes EOA nonce assignment via the GenServer mailbox; `ProviderAdapter.JSONRPC` routes its nonce through it so two concurrent sends for one wallet never sign the same nonce (the SCA/UserOp path uses EntryPoint nonces and is unaffected). `Raxol.Earn.Wallet.SCA` is a full ERC-4337 v0.7 / Alchemy Modular Account v2 stack (`UserOp` hash viem-verified, `Bundler`, `ModularAccount`, `Paymaster`, `Provisioner` for counterfactual CREATE2 + session-key `installValidation`); `ProviderAdapter.SCA` detects an SCA wallet by capability and routes writes through sponsored UserOps, self-deploying on the first tx. `Raxol.Earn.ABI` is a hand-rolled Solidity encoder; `Raxol.Earn.Onchain.{RPC, Transaction, RLP}` are the EIP-1559 wire layer. `Raxol.Earn.Chain` is static Virtuals contract config: the active `acp_core_address` (`AgenticCommerceV3`) + hook/router/subscription addresses + `acp_socket_url`; the legacy `acp_contract_address`/`acp_router_address` stay only for indexer back-compat. Real ABIs vendored at `priv/abi/`. `Raxol.Earn.Offering` DSL: `use Raxol.Earn.Offering, name:, price_usdc:, sla_minutes:, cluster:` injects the `Handler` behaviour and registers metadata; the `Registry` (ETS) stores offering specs. Seller stack: `Backend.{InMemory, WebSocket}` (the WebSocket backend speaks Socket.IO v4/Engine.IO over `Mint.WebSocket`) + `Queue` + `Runtime` + `Supervisor`, opt-in via `:seller_enabled`; the Queue drives `JobSession.Provider`. The `Raxol.Earn.Xochi.TransferOffering` launch liquidity gate rejects unfillable corridors before escrow: per-order `:destination_caps`, `:closed_origins`, and a rolling-aggregate `Raxol.Earn.Xochi.CapacityLedger` (opt-in `capacity_gate_enabled` adds `CapacityGate` = ledger + periodic `CapacityRefresher` to the seller tree); `mix raxol_earn.derive_caps` seeds/refreshes it from the solver's on-chain `balanceOf` (shared `Raxol.Earn.Xochi.CapacityDeriver`). `mix raxol_earn.bench` is the sandbox-graduation harness (drives synthetic jobs through the seller stack against `ProviderAdapter.Mock`). A v2 agent stack mirroring `acp-node-v2`: `Raxol.Earn.Agent` wires three injected behaviours: `ProviderAdapter` (EVM provider: `sendCalls`/`signMessage`/`signTypedData`/`getLogs`), `Transport` (SSE chat stream, `Mock` + `SSE`), and `JobApi` (off-chain REST discovery, `Mock` + `HTTP`). Live-validated: a `:live_bundler` harness forks Base and submits a UserOp via the real on-chain `EntryPoint.handleOps` (RAN GREEN); needs foundry (`anvil`/`cast`), excluded by default. Self-starts via `RaxolEarn.Application` outside `:test`. Depends on raxol_payments at runtime, raxol_mcp compile-time only. **Retired in Phases 1-4** (all deleted): `Job.{Server,Supervisor,Registry,Workflow,StateMachine,MemoType,FeeType,Store}`, `ContractClient`(+`Onchain`+`InMemory`), the memo `Directive`s + `Onchain.LogDecoder`, and the `acp_version`/`ACP_VERSION` switch (the active core via `HookClient` never consulted it).

**Cross-repo payment method types** (canonical in Xochi `src/types/intent.ts`):

| Method       | raxol protocol         | Xochi type | Gasless | Route                         |
| ------------ | ---------------------- | ---------- | ------- | ----------------------------- |
| Direct Auth  | Protocols.X402/Riddler | `erc3009`  | yes     | USDC via ERC-3009             |
| Permit2      | Protocols.Riddler      | `permit2`  | yes     | Most ERC-20 tokens            |
| Sponsored    | Protocols.Xochi        | `pimlico`  | yes     | ERC-4337 stealth claims       |
| Pay-per-call | Protocols.X402         | `x402`     | no      | HTTP 402 micropayments        |
| Agent Relay  | Protocols.MPP          | `mpp`      | yes     | Stripe/Tempo machine payments |
| Approval     | (on-chain)             | `approval` | no      | Fallback, requires gas        |

**Swarm Discovery**: `Raxol.Swarm.Discovery` wraps libcluster (optional dep) with strategy presets: `:gossip` (LAN multicast), `:epmd` (static hosts), `:dns` (Fly.io/K8s), `:tailscale` (mesh via `tailscale status --json`, tag-filtered). NodeMonitor auto-wires `:nodeup`/`:nodedown` events to Topology (elections) and TacticalOverlay (peer sync). Custom strategy: `Raxol.Swarm.Strategy.Tailscale`.

**AI Backend Streaming**: `Raxol.Agent.Backend.HTTP.stream/2` does real SSE streaming for Anthropic, OpenAI, Ollama, and Kimi. Built on `Stream.resource/3` + `spawn_link` + message passing. Four SSE formats: Anthropic (content_block_delta), OpenAI/Kimi (data chunks + `[DONE]`), Ollama (NDJSON), Lumo (data: JSON per line with U2L decryption). `Raxol.Agent.Backend.Lumo` handles Proton Lumo's U2L encryption (per-request AES-256-GCM + PGP key delivery via gpg) with lumo-tamer proxy as fallback. Auto-detection is `Raxol.Agent.Backend.Resolver.resolve/1`: an explicitly named backend wins, else providers are tried in the order anthropic, openai, kimi, openrouter, longcat, lumo, ollama, lm_studio, llm7, mock, then the generic `AI_API_KEY`/`AI_BASE_URL` pair mapped onto `:openai`. Per provider the credential resolves explicit key -> stored `op://` reference -> provider env var, and a keyless local provider is auto-selected only when the user stored a reference for it, so a stray localhost server never becomes the default. `Raxol.Agent.Backend.Selector.select/1` maps a resolved `ExecutorConfig` to a backend module. The `:openrouter` backend (via `Backend.Selector`) targets OpenRouter (OpenAI-compatible) and attaches app-attribution headers (HTTP-Referer, X-OpenRouter-Title, X-OpenRouter-Categories) so Raxol appears on openrouter.ai/rankings; key via `ExecutorConfig` auth. The `:lm_studio` backend targets a local LM Studio server (OpenAI-compatible `/v1/chat/completions`, default `http://localhost:1234`) and reuses the `:openai` provider path, so no new SSE format is needed. The `:longcat` backend targets Meituan's LongCat (`https://api.longcat.chat/openai`, model `LongCat-2.0`) and also reuses the `:openai` path; that path already tolerates LongCat's non-standard frames (a full `message` chunk instead of `delta`, the `reasoning_content` channel, and the underscore-less `finishreason` key).

**Time-Travel Debugging**: `Raxol.start_link(MyApp, time_travel: true)` enables snapshot recording of every `update/2` cycle. `Raxol.Debug.TimeTravel` stores `{message, model_before, model_after}` in a CircularBuffer. Navigate with `step_back/0`, `step_forward/0`, `jump_to/1`. `restore/0` sends the historical model to the Dispatcher for re-render. `Snapshot.diff/2` computes recursive map changes. Zero cost when disabled.

**SSH Architecture**: `Raxol.SSH.Server` wraps `:ssh.daemon` with auto-generated host keys. Each connection spawns a `Raxol.SSH.Session` running a Lifecycle with `environment: :ssh`; `Raxol.SSH.Session.lifecycle_opts/4` is the opts merge seam, and `:ssh` (like `:agent`, `:telegram`, `:liveview`, `:gateway`) owns no plugin manager, so one disconnect cannot kill a concurrent session. Multi-tenant serving looks up per-user keys under `<tenants_dir>/<user>/ssh/authorized_keys` and hands the AUTHENTICATED username to the `:tenant_opts` fun (the coding agent supplies `Raxol.Agent.Code.Tenant.app_opts/2`), normalized through `Raxol.SSH.Server.sanitize_tenant/1` so the identity that authenticated and the workspace that opens cannot diverge. `CLI_Handler` translates SSH channel data to Raxol events. `IO_Adapter` bridges SSH channel I/O to the terminal rendering pipeline.

**REPL Architecture**: `Raxol.REPL.Evaluator` wraps `Code.eval_string` with `spawn_monitor` timeout, `StringIO` IO capture via group_leader swap, and persistent bindings across evaluations. `Raxol.REPL.Sandbox` scans ASTs via `Macro.prewalk` at three levels: `:none` (unrestricted), `:standard` (blocks System.cmd/File.rm/Port.open/etc), `:strict` (whitelist-only, safe for SSH exposure). `Evaluator.with_vfs/1` seeds a VFS binding and auto-imports `Raxol.REPL.VfsHelpers` via prelude.

**Virtual File System**: `Raxol.Commands.FileSystem` is a pure functional in-memory VFS. Flat map keyed by absolute path for O(1) lookups. CRUD: `new/0`, `mkdir/2`, `create_file/3`, `rm/2`, `exists?/2`, `stat/2`. Navigation: `ls/2`, `cd/2`, `pwd/1`, `tree/3`. Read: `cat/2`. REPL helpers in `Raxol.REPL.VfsHelpers` provide shell-like commands (`ls`, `cd`, `cat`, `mkdir`, `touch`, `rm`, `tree`, `stat`). Agent actions in `Raxol.Agent.Actions.Vfs` expose 7 LLM-callable tools via the Action behaviour. See `docs/features/FILESYSTEM.md` for full docs.

**Headless Sessions**: `Raxol.Headless` is a GenServer that manages headless TEA app instances in `:agent` environment. `start/2` takes a module or file path (AST-parsed to pull out `defmodule` blocks, skipping boot code). `screenshot/1` calls `:render_frame_sync` on the engine then reads the buffer via `:get_buffer`. `send_key/3` builds an Event via `Raxol.Headless.EventBuilder` and casts to the dispatcher. `Raxol.Headless.McpTools` defines 6 MCP tools registered with `Raxol.MCP.Registry` at startup. `mix mcp.server` starts the standalone MCP server on stdio (~18ms startup).

**MCP as Rendering Target** (see ADR-0012): MCP is a first-class rendering target, not bolted on. The framework derives MCP tools from the Component tree via `Raxol.MCP.ToolProvider` behaviour on each Component type (15 Components). A focus lens (attention-aware, mouse hover tracking via `:hover` mode) filters to ~15 relevant tools per interaction. `@mcp_exclude` suppresses tool derivation for internal Components. Model state is exposed as MCP resources via app-declared projections. `Raxol.MCP.Test` gives you a pipe-friendly test harness: `session |> type_into("field", "value") |> click("btn") |> assert_component("status")`. Functor law property tests verify tool derivation consistency. Package: `packages/raxol_mcp/` (depends on raxol_core). The context tree assembles state from model, Components, agents, swarm, and notifications as MCP resources, streamed as diffs.

**Symphony Orchestrator** (in `packages/raxol_symphony/`): Elixir/OTP port of OpenAI Symphony. `Raxol.Symphony.Orchestrator` is a `BaseManager` GenServer that polls a tracker (Memory / Linear GraphQL / GitHub Issues), claims eligible issues via `Candidate.eligible/4`, isolates each in a per-issue workspace under `config.workspace.root`, and runs a coding agent until the workflow's terminal state. Two `Raxol.Symphony.Runner` impls: `Runners.RaxolAgent` (default, wraps `Raxol.Agent.Stream`) and `Runners.Codex` (Port-spawned `codex app-server`, JSON-RPC 2.0 over stdio with three-step handshake `initialize` -> `initialized` -> `thread/start`, then per-turn `turn/start` cycles). The Codex runner does no interactive/OAuth sign-in (that stays out-of-band via `codex login`); an optional `codex.auth` block (`Runners.Codex.Auth`, mode `:inherit`/`:api_key`/`:codex_home`) selects and verifies the credential the CLI already holds; config stores only references (env var name, `CODEX_HOME` path), never the secret; the key is read at spawn and injected via `Port.open`'s `{:env, _}`; `require_login: true` fails preflight with `:codex_unauthenticated`; each spawn emits `[:raxol, :symphony, :codex, :auth]` telemetry (`%{mode, authenticated?, source}`). Six surfaces consume the orchestrator snapshot via Phoenix.PubSub: `Surfaces.Terminal` (TEA dashboard), `Surfaces.MCP` (5 tools + `symphony://runs` resource), `Surfaces.Telegram` (per-issue session router), `Surfaces.Watch` (debounced push, tap-to-approve), `Web.DashboardLive` (LiveView), and `Web.API` (JSON `/api/v1/*`). `Raxol.Symphony.Evidence.collect/3` aggregates GitHub CI + PR comments, complexity (`cloc` or SLOC fallback), and asciinema recordings; `Evidence.Capture` GenServer writes a `.cast` file per dispatched run when `recording.enabled: true`. `WorkflowStore` watches `WORKFLOW.md` via `file_system` and serves last-known-good config on parse failure. Three retry classes: continuation (1s), failure exponential (10s × 2^n, capped), stall detection (per-run `read_timeout_ms` / `turn_timeout_ms`).

**Agent Client Protocol** (in `packages/raxol_agent_client_protocol/`, module root `Raxol.AgentClientProtocol`, pre-alpha `0.1.0-rc.0`): Elixir/OTP implementation of [ACP](https://agentclientprotocol.com): the JSON-RPC 2.0 protocol between code editors and AI coding agents (the protocol Zed and a growing ecosystem speak). Not to be confused with `Raxol.Earn` (`packages/raxol_earn/`, the unrelated Virtuals **Agent Commerce** Protocol for on-chain payments). Three orthogonal layers: `Schema.*` (the ACP v1 data model, total decode, no `String.to_atom/1` on wire input), `Rpc.*`/`Transport.*` (JSON-RPC 2.0 envelope + pluggable carriers: `Transport.Stdio` newline-delimited over a real or spawned stdio pipe, `Transport.Paired` an in-process linked-mailbox pair for tests/BEAM-local wiring), and the runtime (`Connection`: one GenServer per peer, either role, never blocks on a peer, never mints an atom from wire input; `Session`: per-session turn state machine under a `DynamicSupervisor`; `Agent`/`Client`: thin `use`-able behaviours whose `@callback`s and dispatch are *generated* from `MethodTable`, the single source of truth for the wire vocabulary, so callback surface and dispatcher cannot drift from it). `Ext.*` is the durable-resumable-sessions vendor extension (`_meta["raxol.io"]` + `_raxol/*` methods, ACP's own extension mechanism): an append-only single-publisher journal per session, offset-based reattach/replay via a register-before-high-watermark seam (no gap, no dup), `RXC1` Ed25519 offline-verifiable capability tokens (no `alg` field: the algorithm binding is the literal version prefix inside the signed bytes), and taint annotation (never filtered, only annotated). Provenance is deliberately layered for pure-MIT license discipline: the `Schema.*` layer is ported MIT→MIT from `f1729/agent_client_protocol` with defects fixed; the conformance corpus (`test/conformance/cases/*.json`) is ported MIT→MIT from `openclaw/acpx`; the OTP runtime is a clean-room implementation (the official Apache-2.0 ACP SDKs, `lostbean/acpex`, and `xai-org/grok-build` were studied as design references only, no code copied); the official ACP JSON Schema is vendored as a SHA256-pinned dev/test oracle (`priv/schema-oracle/`, `mix acp.schema.verify` is the drift gate) and is excluded from the published Hex package so it never propagates Apache-2.0 terms downstream. Zero raxol-internal deps (just `jason`); main raxol does not depend on it. raxol_agent takes it as a source-build path dep (dropped under `HEX_BUILD`), which is what compile-gates `Raxol.Agent.ClientProtocol.StdioAgent`: a Hex install of raxol_agent has no ACP surface and `mix raxol.acp` exits 1 explaining why. See `NOTICE.md` and `docs/proposals/acp-package-adr.md` for the full provenance/license-discipline decision record.

**Unified Messaging Gateway** (in `packages/raxol_gateway/`, pre-alpha): one daemon connecting many chat platforms through a shared contract. `Raxol.Gateway.Adapter` is the five-callback per-platform behaviour (`connect`/`disconnect`/`platform`/`normalize_event`/`send_message`); `Adapter.InMemory` is a reference impl. `Raxol.Gateway.Route` keys sessions `agent:main:{platform}:{chat_type}:{chat_id}`. `Raxol.Gateway.SessionRouter` (BaseManager, generalizes the Telegram router) starts one `Raxol.Gateway.Session` process per chat under a `DynamicSupervisor`, with idle-timeout + per-key cooldown + max-session limits; sessions run a `Raxol.Gateway.Handler`. `Raxol.Gateway.Pairing` issues 8-char TTL DM pairing codes (per-user request cooldown, lockout after repeated failed confirms) and decides `authorize/2` in order platform-allow-all -> paired -> platform allowlist -> global allowlist -> deny. `Raxol.Gateway.Supervisor` (`:rest_for_one`) ties them together. `Raxol.Gateway.Delivery` resolves four outbound destinations (direct, home channel, cross-platform, explicit `"platform:chat_id"` target) and sends via the right adapter. A `Session` optionally records each turn to a `:log` (`append(server, conversation_id, items)`) keyed by a stable `conversation_id`; `SessionRouter.handoff/3` rebinds a conversation to another platform's route reusing that id so history follows. The `Adapter` contract is frozen (additions must be optional callbacks). `Raxol.Gateway.Handler.Agent` is the first production handler: each `%{text: ...}` event runs one synchronous `Raxol.Agent.Stream` turn (`auto_provider: true` unless a backend/executor is pinned, so credentials resolve op-ref -> provider-env -> `AI_API_KEY`; unresolved falls through to Mock), capped per-chat history in handler state, safe_call-guarded so a crashing backend cannot kill the session. Session idle timeouts are ref-tagged (a stale timer firing during a long turn is ignored). Depends on raxol_core; raxol_agent optional (for Handler.Agent + per-chat Conversation.Log history). Two platform adapters sit behind the frozen contract: Telegram (`Raxol.Telegram.GatewayAdapter`, in raxol_telegram, compiled only when raxol_gateway is present, + `Raxol.Telegram.UpdatePoller`, a getUpdates long-poll feed with optional DETS-durable offset) and Discord (`Raxol.Gateway.Adapter.Discord`, in-gateway: REST sends chunked at 2000 code points via optional `req`, + `Raxol.Gateway.Adapter.Discord.GatewaySocket`, a lean Gateway-v10 WebSocket feed on optional `mint_web_socket`: client heartbeats with zombie detection, identify/resume, exponential reconnect, injectable `Transport` seam; `Protocol` is the pure frame codec). Both feeds are sink-agnostic (`:on_update` / `:on_event`). `Raxol.Gateway.Pipeline.Transcribe` is the voice stage: a feed-loop transform (runs BEFORE `SessionRouter.route/3`, so the session log records the transcript and STT never blocks a chat mailbox) that turns `%{media: %{kind: :voice, ref: ...}}` events (emitted by the Telegram adapter for `message.voice`; `fetch_media/2` + `HTTP.download_file/2` do the token-redacted getFile download) into `%{text: transcript}` via injectable fetch/convert/recognize fns (defaults: ffmpeg temp-file shell-out with executable allowlist; optional raxol_speech `Recognizer.recognize/1`); fails open per event (drop + warning + telemetry). `Raxol.Gateway.Adapter.Email` (in-gateway) is a bidirectional email adapter via optional `gen_smtp`: outbound is text/plain SMTP delivery (injectable `:send_fn`), whose win is `Delivery` `{:home, route}` cron/background results; inbound `normalize_event/1` parses a raw RFC822 message (`:mimemail.decode`, never raises) into `{:ok, route, %{text: body}}`, routing on the normalized sender address (`chat_type: :dm`), taking the first text/plain part with quoted history trimmed, and surfacing `Message-ID`/`In-Reply-To`/`References`/`Subject` under `:email`. The transport that pulls mail off a mailbox is injected, not bundled (IMAP/POP/Gmail-API/SMTP-listener stay the deployment's choice): `Raxol.Gateway.Adapter.Email.Inbox` is the sink-agnostic poll feed (injectable `:fetch_fn` cursor loop, backoff, redacted status, mirrors `UpdatePoller`), and `Raxol.Gateway.Adapter.Email.ThreadStore` is a capped per-conversation store the wiring records inbound `Message-ID`s into and the adapter reads back through `conn`'s `:thread_lookup`, so outbound replies set `In-Reply-To`/`References`/`Re:` headers even though the frozen `send_message/3` carries no per-send channel for the reply id. `Raxol.Gateway.Handler.Lifecycle` runs a full TEA app per chat under `environment: :gateway` (a first-class Lifecycle environment: no driver, no plugin manager, unnamed Lifecycle/Dispatcher so one app module serves many concurrent chats; the same fix registered `:telegram` in both multi-instance lists); turns collect deterministically (event-fold `:sys` barrier + synchronous engine render, frame formatted to plain text via injectable `:event_fn`/`:format_fn`), and the new optional `Handler.terminate/2` (invoked by `Session` on clean stops) stops the per-chat Lifecycle so it cannot leak past its chat. The inbound-email transport (IMAP/POP/Gmail) is deployment-supplied, not bundled. See ADR-0023.

**Phoenix as library only**: No active web server in core. Ecto.Repo is disabled at runtime. MCP is served via `mix mcp.server` (stdio), not through Phoenix.

### Buffer/Renderer API

The `Raxol.Core.Renderer` API:

- `render_diff/2` returns operation tuples: `[{:move, x, y}, {:write, text, style}, ...]`
- `apply_diff/1` converts operations to ANSI string for `IO.write/1`

```elixir
diff = Renderer.render_diff(old_buffer, new_buffer)
IO.write(Renderer.apply_diff(diff))  # NOT Enum.each(diff, &IO.write/1)
```

### Render Pipeline

`view(model)` -> Preparer (text measurement + animation hints) -> LayoutEngine (positioning) -> UIRenderer (cell tuples) -> ScreenBuffer (diff) -> Terminal.Renderer (ANSI). See `docs/core/ARCHITECTURE.md` for the full layer-by-layer walkthrough.

Before calling `view/1`, the Engine applies animations to the model via `Raxol.Animation.Framework.apply_animations_to_state/1` (try/catch guarded). Animation hints declared via `Raxol.Animation.Helpers.animate/2` in `view/1` attach `%Raxol.Animation.Hint{}` metadata to elements. Hints flow through Preparer -> LayoutEngine -> backends. Terminal ignores them (server computes frames). LiveView emits CSS `transition` rules via `TerminalBridge.animation_css/1` with `data-raxol-id` selectors and `prefers-reduced-motion` media query. MCP includes hints in `StructuredScreenshot` JSON. The Dispatcher includes `reduced_motion` in the render context.

Key rules:

- Use `Raxol.UI.TextMeasure` for display width, never `String.length`; CJK chars are double-width
- `ScrollContent` behaviour enables lazy content for Viewport (`ListScrollContent`, `StreamScrollContent`)
- **Never embed raw ANSI codes** (`\e[...m`) in strings passed to `text()` or the View DSL. ANSI codes are only applied at the final Terminal.Renderer stage. Components must use `text("content", fg: :cyan, style: [:bold])`, not `text("\e[36mcontent\e[0m")`
- **Animation hints are declarative metadata**, not imperative commands. Use `import Raxol.Animation.Helpers` then `element |> animate(property: :opacity, to: 1.0, duration: 300)` in `view/1`. Hints describe intent; surfaces that understand them (LiveView) can accelerate rendering. Surfaces that don't (terminal) compute frames server-side via `Animation.Framework`. Also: `stagger/2` for cascaded delays, `sequence/2` for chained animations.

### Testing patterns

**Test Tags** (auto-excluded based on environment):

- `@tag :docker` - Requires termbox2/Docker (excluded when `SKIP_TERMBOX2_TESTS=true`)
- `@tag :skip_on_ci` - Skip in CI (excluded when `SKIP_TERMBOX2_TESTS=true`)
- `@tag :unix_only` - Unix/macOS only (excluded on Windows)
- `@tag :slow` / `@tag :integration` - Long-running tests

**Test Infrastructure**:

- Test helpers in `test/support/` (IsolationHelper, TerminalTestHelper, etc.)
- `Raxol.Test.IsolationHelper.reset_global_state()` runs between tests
- Property-based tests in `test/property/`
- MockDB used instead of Ecto sandbox
- Mox mocks defined in `test/test_helper.exs` for core runtime behaviours

### Naming conventions

- Module files: `<domain>_<function>.ex` (e.g., `cursor_manager.ex`, `buffer_server.ex`)
- Avoid generic names: `manager.ex`, `handler.ex`, `server.ex`
- Effects use full module paths: `Raxol.Effects.CursorTrail` not bare `CursorTrail`

### Consolidated Namespaces

These namespaces are settled; don't create new top-level alternatives:

- `Raxol.Terminal.Commands.*` - All command processing, in raxol_terminal package
- `Raxol.Terminal.Rendering.*` - All terminal rendering, in raxol_terminal package
- `Raxol.Performance.*` - All performance tools (not `core/performance/`)
- `Raxol.LiveView.*` - LiveView integration, in raxol_liveview package
- `Raxol.Debug.*` - Debugging tools (time-travel, snapshots)
- `Raxol.Recording.*` - Session recording/replay (not `session/`)
- `Raxol.Swarm.*` - Distributed swarm (CRDTs, discovery, topology)
- `Raxol.Swarm.Strategy.*` - Custom libcluster strategies (Tailscale)
- `Raxol.UI.TextMeasure` - Single facade for display width measurement (not `String.length`)
- `Raxol.UI.Layout.ScrollContent` - Cursor-based lazy scroll behaviour + adapters
- `Raxol.Headless.*` - Headless session manager, EventBuilder, TextCapture, McpTools
- `Raxol.MCP.*` - MCP protocol (server, client, registry, transports, tool derivation)
- `Raxol.Harness.*` - Coding-agent harness projection, event boundary, fixtures, in main raxol
- `Raxol.Agent.Code.*` - Coding-agent TUI, launcher, store, replay, tenancy, sharing, in raxol_agent
- `Raxol.Agent.Journal.*` - Durable per-session journal (FileStore Writer/Reader, checkpoints)
- `Raxol.Payments.*` - Agent payments (protocols, wallets, spending, actions) in raxol_payments package
- `Raxol.Earn.*` - Virtuals Agent Commerce Protocol (job sessions, offerings, hooks) in raxol_earn package
- `Raxol.Plugin` - Plugin SDK macro (`use Raxol.Plugin`), API, testing in raxol_plugin package
- `Raxol.Animation.*` - Animation hints (`Helpers`, `Hint`) in main raxol; CSS mapping in `Raxol.Core.Animation.Hint` (raxol_core package)

## Environment variables

**Set automatically** (via `.claude/settings.json`):

- `SKIP_TERMBOX2_TESTS=true` - Skip Docker/termbox2-dependent tests
- `TMPDIR=/tmp` - Temporary directory for test artifacts

**Optional**:

- `CI=true` - Triggers CI-specific config
- `RAXOL_SKIP_TERMINAL_INIT=true` - Skip terminal init in certain contexts
- `HEX_BUILD=1` - Strip path deps for Hex publishing (`HEX_BUILD=1 mix hex.publish`)
- `RAXOL_SSH_CODE` / `RAXOL_SSH_CODE_TENANTS` / `RAXOL_SSH_CODE_BUDGET_USD` - Hosted multi-tenant coding agent (all three required; `RAXOL_SSH_CODE_PORT` defaults to 2223)
- `RAXOL_SESSIONS_DIR` - Coding-agent journal base (default `~/.raxol/sessions/`); `RAXOL_SHARE_SECRET` signs `/share` tokens

## Dialyzer

- PLT cached in `priv/plts/` for faster reruns
- `.dialyzer_ignore.exs` contains 12 documented suppression patterns (fprof, broad API specs, flow narrowing)
- Mix aliases: `mix dialyzer.setup`, `mix dialyzer.check`, `mix dialyzer.clean`

## Deployment

**Production**: Fly.io at `https://raxol.io`

```bash
flyctl deploy              # Deploy
flyctl status --app raxol  # Status
flyctl logs --app raxol    # Logs
```

Configuration: `fly.toml`, Dockerfile: `docker/Dockerfile.web`. The playground SSH surface is on (port 2222); the multi-tenant coding agent (`RAXOL_SSH_CODE`, port 2223) is present in the build but its env block stays commented out in `fly.toml` until a tenants volume exists.

## Hex Publishing

12 packages are published to Hex (the main `raxol` package plus 11
subsystems); `raxol_earn`, `raxol_symphony`, `raxol_gateway`, and
`raxol_agent_client_protocol` are pre-alpha and not yet published.
`raxol_cli` and `raxol_console` are npm packages wrapping Burrito
binaries (`packages/raxol_cli/npm/`, `packages/raxol_console/npm/`, built
by `.github/workflows/release-raxol-{cli,console}.yml`).
Publish order matters (dependency chain):

```bash
# 1. No raxol deps (parallel)
cd packages/raxol_sensor && HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish
cd packages/raxol_core && HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish

# 2. Depend on raxol_core (parallel)
cd packages/raxol_terminal && HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish
cd packages/raxol_mcp && HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish
cd packages/raxol_plugin && HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish
cd packages/raxol_liveview && HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish
cd packages/raxol_speech && HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish
cd packages/raxol_watch && HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish

# 3. Main (depends on all above)
HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish

# 4. Depend on main raxol (parallel)
cd packages/raxol_agent && HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish
cd packages/raxol_telegram && HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish

# 5. Depends on raxol_agent
cd packages/raxol_payments && HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish

# 6. Depends on raxol_payments (raxol_earn, not yet published)
# cd packages/raxol_earn && HEX_BUILD=1 mix deps.get && HEX_BUILD=1 mix hex.publish
```

`HEX_BUILD=1` strips `path:` and `override:` from deps so `mix hex.build` sees only Hex packages. Without it, local path deps are used for development.

## Project notes

- Themes stored in `priv/themes/` as JSON
- Domain: raxol.io (made by axol.io)
- Plugin docs: `docs/plugins/GUIDE.md`
- `ROADMAP.md` is the tracked roadmap (`AGENTS.md` is gitignored and absent from a clone)
- HEEx terminal compilation (`compile_heex_for_terminal`) is experimental

<!-- usage-rules-start -->
<!-- usage_rules-start -->

## usage_rules usage

_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should _thoroughly_ consult before taking any
action. These usage rules contain guidelines and rules _directly from the package authors_.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```

## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```

<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->

## usage_rules:elixir usage

# Elixir Core Usage Rules

## Pattern Matching

- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling

- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid

- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design

- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures

- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing

- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->

## usage_rules:otp usage

# OTP Usage Rules

## GenServer Best Practices

- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication

- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance

- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async

- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
