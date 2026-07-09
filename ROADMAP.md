# Raxol Roadmap

Multi-surface application runtime for Elixir. One TEA module, four render targets.

## Current Version: v2.5.0

### What's Done

- **Phase 1: Core Runtime**: TEA architecture, TTY detection, ANSI input/output, render pipeline end-to-end
- **Phase 2: Widget Library**: 23 widgets with tests and examples (exceeds original 15-widget target)
- **Phase 3: Framework Polish**: Focus management, W3C-style event capture/bubble, style inheritance, terminal compatibility (color downsampling, Unicode width, synchronized output)
- **Phase 4: OTP Differentiators**: Process-per-component crash isolation, hot code reload, LiveView bridge, SSH app serving
- **Phase 5: Ecosystem Tooling**: Hex package, Phoenix optional, `mix raxol.new` generator, documentation, tech debt cleanup, showcase, session recording
- **Phase 6: Playground + Charts**: 30 demos across 8 categories, 7 chart modules (braille-resolution), web refactor, SSH playground
- **Time-Travel Debugging**: Snapshot every update/2 cycle, cursor navigation, restore, export/import. Zero cost when disabled
- **Agent Framework**: TEA-based AI agents, coordinator/worker teams, 7 agent harness gaps closed (compaction, hooks, permissions, MCP client, streams, LSP, SSE)
- **Sensor Fusion HUD**: Sensor behaviour, polling feeds, weighted averaging, threshold alerts
- **Distributed Swarm**: CRDTs, node monitoring, topology election, libcluster + Tailscale strategy
- **Self-Evolving Interface**: Behavior tracking, layout recommendations, animated transitions
- **AI Cockpit + Streaming**: Multi-pane terminal dashboard, SSE streaming for 8 AI backends
- **Virtual File System**: Pure functional in-memory VFS, REPL helpers, 7 agent actions
- **Phase 8: raxol_mcp**: Extracted MCP package (server, client, registry, stdio/SSE transports)
- **Phase 9: ToolProvider**: Auto-derive MCP tools from widget tree (15 widgets), focus lens, tree walker
- **Phase 10: MCP Protocol Hardening**: Full MCP spec coverage (prompts, logging, completion), notifications, circuit breaker, chart ToolProviders, agent bridge, Tidewave removed
- **Phase 11: MCP Resources + Context Tree**: ResourceProvider behaviour, ResourceRouter, ContextTree, StructuredScreenshot, model projection diffs, resource subscriptions
- **Phase 12: MCP Widget + Agent Coverage**: `@mcp_exclude` attribute, FocusLens hover mode, ToolSynchronizer focus/hover tracking, HoverHighlight effect
- **Phase 13: MCP Test Harness**: Pipe-friendly test API (`click`, `type_into`, `assert_component`, `assert_tool_available`), session lifecycle, functor law property tests (10 properties)
- **Agent Payments (Phase A)**: x402/MPP auto-pay, wallets (env + 1Password), spending controls, 5 agent actions
- **Phase 14B: Xochi Integration**: Xochi as default agent protocol for cross-chain (cash-positive, tier fees 0.10-0.40%). Riddler solves behind the scenes. Full intent flow: quote -> sign -> execute -> poll. Router prefers Xochi for cross-chain and privacy. 94 tests.
- **Phase 14C: PXE-Bridge Integration**: Aztec Private eXecution Environment as settlement target for high-trust privacy tiers. PXE client (JSON-RPC 2.0), schemas, PrivacyTier (Glass Cube, 6 tiers), Router settlement routing. 51 tests.
- **Phase 14D: Stealth Settlement**: Full ERC-5564/ERC-6538 in `Xochi.Stealth` (~300 LOC). ECDH derivation, view tag scanning (256x speedup), domain-separated key derivation, meta-address encode/decode. 44 tests (32 unit + 12 e2e).
- **Phase 14E: ZKSAR + Trust Tiers**: ZKSAR attestation verification (6 ZK proof types), diminishing-returns trust score aggregation, attestation-gated privacy tiers, privacy depth routing. 52 tests.
- **Riddler Solver Wiring (ADR-0005)**: Xochi adapter wired to Riddler's intent engine: 9 endpoints, fee policy (5 tiers + privacy premiums), stealth/ERC-4337 settlement, ZKSAR attestation, EIP-712 typed data, PropertyTable stores. 119 Riddler tests + 347 raxol_payments tests. Aztec shielded settlement deferred (sidecar deployment).
- **Phase 15A-E: Animation Hints**: Declarative metadata flowing from `view/1` to all surfaces. `Animation.Helpers` DSL (`animate`, `stagger`, `sequence`), terminal frames computed server-side via `Animation.Framework`, LiveView CSS via `TerminalBridge.animation_css/1` with `prefers-reduced-motion`, MCP `StructuredScreenshot` JSON hints, `reduced_motion` in render context.
- **Phase 17: Telegram bridge** (`raxol_telegram`): Bot, per-chat session router (1000 max, 5s cooldown), inline keyboard navigation, message edit dedup, 10min idle timeout. 34 tests.
- **Phase 18: Speech interface** (`raxol_speech`): TTS (OsSay/espeak, accessibility subscription), STT (Whisper via Bumblebee), Listener (sox Port, bounded), 21 default voice commands. 28 tests.
- **Phase 19: Watch notifications** (`raxol_watch`): APNS/FCM push via `pigeon`, ETS-backed device registry, 1s debounce, 160-char glanceable summaries, tap-to-event actions. 34 tests.
- **Adaptive UI Overhaul**: 8-rule LayoutRecommender (was 3), multi-recommendation, TrendDetector, NxModel expanded to 10 features with auto-retrain, Lifecycle integration (`adaptive: true`), 5 MCP tools. 67 tests.
- **BorderBeam Effect**: Three-layer animated border glow (beam stroke, inner glow, outer bloom). Four variants (colorful/mono/ocean/sunset). Terminal exponential decay, LiveView conic-gradient + mask CSS, MCP hint serialization. Pipe + prop DSL. 99 effects tests.
- **`raxol_acp` v0.2 (pre-alpha, `0.2.0-rc.0`)**: First Elixir/OTP-native Virtuals Agent Commerce Protocol implementation, aligned to the deployed Base contracts and fork-validated. The v2 hook/event model is the active runtime (the v1 memo model was retired -- see `packages/raxol_acp/MIGRATION_V2.md`): `Raxol.ACP.JobSession` state machine (`:open -> :budget_set -> :funded -> :submitted -> :completed` plus `:rejected`/`:expired`), on-chain hook writes via `HookClient` -> `AgenticCommerceV3` through an injected `ProviderAdapter` (`SCA` sponsored UserOps / `JSONRPC` EOA with `NonceServer`-serialized nonces / `Mock`), full ERC-4337 SCA wallet (Alchemy Modular Account v2: sponsored UserOps, counterfactual deploy, session keys), Seller stack (`Backend.{InMemory, WebSocket}` over Socket.IO + `Queue` + `Runtime` driving `JobSession.Provider`), `mix raxol_acp.bench`. Real ABIs and verified Base addresses vendored. 509 tests. Pre-alpha until a single graduated offering on Base mainnet.
- **`raxol_symphony` Phases 0-14**: Elixir/OTP port of OpenAI Symphony. Tracker-driven coding-agent orchestrator with two runner backends (`raxol_agent` default + `codex app-server` Port-based JSON-RPC), six surfaces (terminal/LiveView/MCP/Telegram/Watch/JSON API), workflow hot-reload, evidence framework (CI status + PR comments + cloc/SLOC + asciinema), in-run asciicast capture. 399 tests. Pre-alpha; path-dep.
- **Video Render Target** (hermes-agent pickup): One TEA module to MP4/WebM/GIF. Frames computed server-side at a virtual animation clock (`Raxol.Animation.Clock`), themed HTML via `TerminalBridge` rasterized through headless Chrome, encoded with FFmpeg. `Raxol.Recording.Video` (`frame_html`/`render_frame`/`capture_frame`/`capture_clip`), a swappable `Rasterizer` (zero-dep HeadlessChrome plus warm-pool ChromicPDF, ~6x faster), `Headless.get_buffer/1`, and `mix raxol.render`.
- **Cross-Session Agent Memory** (hermes-agent pickup): Opt-in, per-agent persistent memory behind a pluggable `Raxol.Agent.Memory` behaviour. Default `Memory.Store.Ets` is a self-contained ETS+DETS store (no deps) with BM25-lite + recency + tag ranking over a token inverted index. Automatic pre-turn recall injected into the system prompt (`Manager.enrich_messages`) plus explicit `memory_remember`/`recall`/`forget` actions; wired into `Stream`/`ReAct` and exposed via `use Raxol.Agent` `memory_provider/0`. 25 tests. User model, auto-capture, and the recall-MCP bridge deferred.

---

## Next Up

### Ship It

The twelve stable packages are published to Hex: the mature framework packages at v2.4.0 and the newer payment and surface packages (`raxol_payments`, `raxol_speech`, `raxol_telegram`, `raxol_watch`) at v0.1.0. `raxol_acp`, `raxol_symphony`, and `raxol_gateway` stay pre-alpha and unpublished until they graduate.

| Task                      | Description                                                            | Effort |
| ------------------------- | --------------------------------------------------------------------- | ------ |
| Graduate `raxol_acp`      | Live run on Base mainnet with one offering, then the first Hex release | Medium |
| Graduate `raxol_symphony` | Live workflow against a real Linear/GitHub repo, then Hex reservation  | Medium |

### Targeting Next: Agent & Creative

Capabilities identified by studying [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent). The BEAM gives several of these a more natural home than Hermes's single-process Python: real concurrency, crash isolation, and a native frame engine. **Shipped from this set:** the Video Render Target and Cross-Session Agent Memory (see What's Done). Remaining:

| Target | What | Status |
| ------ | ---- | ------ |
| Self-improving skill loop | `Curator` BaseManager plus a per-turn background review: agents author, patch, consolidate, and archive their own skills (agentskills.io format), built on the existing `PermissionHook` + `Agent.Session` primitives. | Planned |
| Agent cron scheduler | Per-agent natural-language scheduled automations that deliver to existing surfaces, generalizing Symphony's polling loop. | Planned |
| Agent Client Protocol adapter | Put `raxol_agent` inside Zed/VS Code/JetBrains agent panels. ACP here is the Agent *Client* Protocol, distinct from `raxol_acp` (Agent *Commerce* Protocol). | Planned |
| Creative-media agent actions | `image_generate`/`video_generate`/`tts`/`transcribe` as `raxol_agent` Actions behind a backend-agnostic provider behaviour. | Planned |
| Memory: user model + auto-capture + MCP bridge | Extend Cross-Session Memory with a dialectic user model, optional post-turn auto-capture, and a provider that bridges to the external recall MCP server. | Planned |

### AI Backend Providers

Supported now:

- **Mock** (default): instant offline demo, no API key
- **Proton Lumo** (`PROTON_UID=... PROTON_ACCESS_TOKEN=...`): zero-access encrypted AI, full U2L encryption via `Backend.Lumo`
- **Proton Lumo via lumo-tamer** (`LUMO_TAMER_URL=http://localhost:3000`): OpenAI-compatible proxy fallback
- **Kimi K2.5** (`KIMI_API_KEY=...`): Moonshot AI, $0.60/M input, 256K context, named `:kimi` provider
- **LLM7.io** (`FREE_AI=true`): free, OpenAI-compatible, no key needed, 40 req/min
- **Ollama** (`OLLAMA_MODEL=...`): free local inference, OpenAI-compatible
- **Groq** (`AI_API_KEY=... AI_BASE_URL=https://api.groq.com/openai`): fast free tier
- **OpenAI** (`AI_API_KEY=...`): GPT-4o-mini and up
- **Anthropic** (`ANTHROPIC_API_KEY=...`): Claude Haiku/Sonnet/Opus
- **OpenRouter** (`:openrouter` harness, key via `ExecutorConfig` auth): OpenAI-compatible aggregator that sends app-attribution headers (HTTP-Referer, X-OpenRouter-Title, X-OpenRouter-Categories) so Raxol appears on openrouter.ai/rankings

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
