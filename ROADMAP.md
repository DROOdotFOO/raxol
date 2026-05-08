# Raxol Roadmap

Multi-surface application runtime for Elixir. One TEA module, four render targets.

## Current Version: v2.4.0

### What's Done

- **Phase 1: Core Runtime** -- TEA architecture, TTY detection, ANSI input/output, render pipeline end-to-end
- **Phase 2: Widget Library** -- 23 widgets with tests and examples (exceeds original 15-widget target)
- **Phase 3: Framework Polish** -- Focus management, W3C-style event capture/bubble, style inheritance, terminal compatibility (color downsampling, Unicode width, synchronized output)
- **Phase 4: OTP Differentiators** -- Process-per-component crash isolation, hot code reload, LiveView bridge, SSH app serving
- **Phase 5: Ecosystem Tooling** -- Hex package, Phoenix optional, `mix raxol.new` generator, documentation, tech debt cleanup, showcase, session recording
- **Phase 6: Playground + Charts** -- 30 demos across 8 categories, 7 chart modules (braille-resolution), web refactor, SSH playground
- **Time-Travel Debugging** -- Snapshot every update/2 cycle, cursor navigation, restore, export/import. Zero cost when disabled
- **Agent Framework** -- TEA-based AI agents, coordinator/worker teams, 7 agent harness gaps closed (compaction, hooks, permissions, MCP client, streams, LSP, SSE)
- **Sensor Fusion HUD** -- Sensor behaviour, polling feeds, weighted averaging, threshold alerts
- **Distributed Swarm** -- CRDTs, node monitoring, topology election, libcluster + Tailscale strategy
- **Self-Evolving Interface** -- Behavior tracking, layout recommendations, animated transitions
- **AI Cockpit + Streaming** -- Multi-pane terminal dashboard, SSE streaming for 8 AI backends
- **Virtual File System** -- Pure functional in-memory VFS, REPL helpers, 7 agent actions
- **Phase 8: raxol_mcp** -- Extracted MCP package (server, client, registry, stdio/SSE transports)
- **Phase 9: ToolProvider** -- Auto-derive MCP tools from widget tree (15 widgets), focus lens, tree walker
- **Phase 10: MCP Protocol Hardening** -- Full MCP spec coverage (prompts, logging, completion), notifications, circuit breaker, chart ToolProviders, agent bridge, Tidewave removed
- **Phase 11: MCP Resources + Context Tree** -- ResourceProvider behaviour, ResourceRouter, ContextTree, StructuredScreenshot, model projection diffs, resource subscriptions
- **Phase 12: MCP Widget + Agent Coverage** -- `@mcp_exclude` attribute, FocusLens hover mode, ToolSynchronizer focus/hover tracking, HoverHighlight effect
- **Phase 13: MCP Test Harness** -- Pipe-friendly test API (`click`, `type_into`, `assert_widget`, `assert_tool_available`), session lifecycle, functor law property tests (10 properties)
- **Agent Payments (Phase A)** -- x402/MPP auto-pay, wallets (env + 1Password), spending controls, 5 agent actions
- **Phase 14B: Xochi Integration** -- Xochi as default agent protocol for cross-chain (cash-positive, tier fees 0.10-0.30%). Riddler solves behind the scenes. Full intent flow: quote -> sign -> execute -> poll. Router prefers Xochi for cross-chain and privacy. 94 tests.
- **Phase 14C: PXE-Bridge Integration** -- Aztec Private eXecution Environment as settlement target for high-trust privacy tiers. PXE client (JSON-RPC 2.0), schemas, PrivacyTier (Glass Cube, 6 tiers), Router settlement routing. 51 tests.
- **Phase 14D: Stealth Settlement** -- Full ERC-5564/ERC-6538 in `Xochi.Stealth` (~300 LOC). ECDH derivation, view tag scanning (256x speedup), domain-separated key derivation, meta-address encode/decode. 44 tests (32 unit + 12 e2e).
- **Phase 14E: ZKSAR + Trust Tiers** -- ZKSAR attestation verification (6 ZK proof types), diminishing-returns trust score aggregation, attestation-gated privacy tiers, privacy depth routing. 52 tests.
- **Riddler Solver Wiring (ADR-0005)** -- Xochi adapter wired to Riddler's intent engine: 9 endpoints, fee policy (5 tiers + privacy premiums), stealth/ERC-4337 settlement, ZKSAR attestation, EIP-712 typed data, PropertyTable stores. 119 Riddler tests + 347 raxol_payments tests. Aztec shielded settlement deferred (sidecar deployment).
- **Phase 15A-E: Animation Hints** -- Declarative metadata flowing from `view/1` to all surfaces. `Animation.Helpers` DSL (`animate`, `stagger`, `sequence`), terminal frames computed server-side via `Animation.Framework`, LiveView CSS via `TerminalBridge.animation_css/1` with `prefers-reduced-motion`, MCP `StructuredScreenshot` JSON hints, `reduced_motion` in render context.
- **Phase 17: Telegram bridge** (`raxol_telegram`) -- Bot, per-chat session router (1000 max, 5s cooldown), inline keyboard navigation, message edit dedup, 10min idle timeout. 34 tests.
- **Phase 18: Speech interface** (`raxol_speech`) -- TTS (OsSay/espeak, accessibility subscription), STT (Whisper via Bumblebee), Listener (sox Port, bounded), 21 default voice commands. 28 tests.
- **Phase 19: Watch notifications** (`raxol_watch`) -- APNS/FCM push via `pigeon`, ETS-backed device registry, 1s debounce, 160-char glanceable summaries, tap-to-event actions. 34 tests.
- **Adaptive UI Overhaul** -- 8-rule LayoutRecommender (was 3), multi-recommendation, TrendDetector, NxModel expanded to 10 features with auto-retrain, Lifecycle integration (`adaptive: true`), 5 MCP tools. 67 tests.
- **BorderBeam Effect** -- Three-layer animated border glow (beam stroke, inner glow, outer bloom). Four variants (colorful/mono/ocean/sunset). Terminal exponential decay, LiveView conic-gradient + mask CSS, MCP hint serialization. Pipe + prop DSL. 99 effects tests.
- **`raxol_acp` v0.1 (engineering complete)** -- First Elixir/OTP-native Virtuals Agent Commerce Protocol implementation. Job lifecycle (`Job.{Server, StateMachine, Memo, Store}`), EIP-712 typed-data memos, on-chain client (Req JSON-RPC + EIP-1559 typed-tx + Yellow-Paper RLP + log decoder), Seller stack (`Backend.InMemory` + `Queue` + `Runtime` + `Supervisor`), DETS-optional persistence, `mix raxol_acp.bench` sandbox-graduation harness. 256 tests. Pre-alpha; external-blocked on real Virtuals ABIs + `Wallet.SCA` spec.
- **`raxol_symphony` Phases 0-14** -- Elixir/OTP port of OpenAI Symphony. Tracker-driven coding-agent orchestrator with two runner backends (`raxol_agent` default + `codex app-server` Port-based JSON-RPC), six surfaces (terminal/LiveView/MCP/Telegram/Watch/JSON API), workflow hot-reload, evidence framework (CI status + PR comments + cloc/SLOC + asciinema), in-run asciicast capture. 399 tests. Pre-alpha; path-dep.

---

## Next Up

### Ship It

| Task              | Description                                      | Effort |
| ----------------- | ------------------------------------------------ | ------ |
| Hex: raxol_sensor | Zero deps, 55 tests, standalone -- publish first | Small  |
| Hex: raxol_mcp    | Full MCP surface, test harness, 222+ tests       | Small  |
| Hex: raxol_agent  | Agent framework, depends on raxol + raxol_mcp    | Medium |
| Hex: raxol        | Main package, depends on all above               | Medium |

### AI Backend Providers

Supported now:

- **Mock** (default) -- instant offline demo, no API key
- **Proton Lumo** (`PROTON_UID=... PROTON_ACCESS_TOKEN=...`) -- zero-access encrypted AI, full U2L encryption via `Backend.Lumo`
- **Proton Lumo via lumo-tamer** (`LUMO_TAMER_URL=http://localhost:3000`) -- OpenAI-compatible proxy fallback
- **Kimi K2.5** (`KIMI_API_KEY=...`) -- Moonshot AI, $0.60/M input, 256K context, named `:kimi` provider
- **LLM7.io** (`FREE_AI=true`) -- free, OpenAI-compatible, no key needed, 40 req/min
- **Ollama** (`OLLAMA_MODEL=...`) -- free local inference, OpenAI-compatible
- **Groq** (`AI_API_KEY=... AI_BASE_URL=https://api.groq.com/openai`) -- fast free tier
- **OpenAI** (`AI_API_KEY=...`) -- GPT-4o-mini and up
- **Anthropic** (`ANTHROPIC_API_KEY=...`) -- Claude Haiku/Sonnet/Opus

### Longer Term

- Multi-node cockpit (swarm coordination across physical terminals)
- Plugin marketplace
- VS Code extension for component previews
- Burrito packaging (single standalone binary)
- FLAME integration (elastic compute for Nx training bursts)
- SSH session multiplexing (tmux-like panes)
- Collaborative sessions (multi-user terminal sharing)
- Documentation site (widget gallery, tutorials, examples)

---

## Contributing

Want to help? See [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## Versioning

- **Minor** (2.x.0): New features, framework additions
- **Patch** (2.0.x): Bug fixes, performance improvements
- **Major** (3.0.0): Breaking API changes, architectural shifts
