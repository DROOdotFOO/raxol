# Raxol Roadmap

Multi-surface application runtime for Elixir. One TEA module, four render targets.

## Current Version: v2.6.0

---

## What's Done

**Framework core (Phases 1-6):** TEA architecture, full render pipeline, 23 widgets, focus + W3C-style event capture/bubble, terminal compat (color downsampling, Unicode width, synchronized output), playground (30 demos / 8 categories), 7 braille-resolution charts, Hex packaging, `mix raxol.new`, session recording.

**OTP differentiators:** process-per-component crash isolation, hot code reload, LiveView bridge, SSH app serving, time-travel debugging (snapshot every `update/2`), distributed swarm (CRDTs, topology election, libcluster + Tailscale).

**Adaptive UI + effects:** 8-rule LayoutRecommender, TrendDetector, Nx auto-retrain, Lifecycle integration, 5 MCP tools. Animation hints (Phase 15): declarative `view/1` metadata to every surface (`animate`/`stagger`/`sequence`), terminal frames server-side, LiveView CSS with `prefers-reduced-motion`, MCP JSON hints. BorderBeam effect (three-layer glow, 4 variants, terminal + LiveView + MCP).

**MCP surface (Phases 8-13):** extracted `raxol_mcp` (server/client/registry, stdio + SSE). Auto-derives tools from the widget tree (15 widgets) with a focus/hover lens; `@mcp_exclude` opt-out. Full spec coverage (prompts, logging, completion, notifications, circuit breaker). Resources + ContextTree + StructuredScreenshot + model-projection diffs. Pipe-friendly test harness with functor-law property tests.

**Agent framework:** TEA-based agents, coordinator/worker teams, 7 harness gaps closed (compaction, hooks, permissions, MCP client, streams, LSP, SSE). AI cockpit with SSE streaming for 9 backends. Virtual File System (pure-functional in-memory VFS, REPL helpers, 7 agent actions).

**Agent memory + self-improving skills** (hermes-agent pickup): pluggable `Raxol.Agent.Memory` (`Store.Ets`, ETS+DETS, BM25-lite + recency + tags), pre-turn recall injection, `memory_remember`/`recall`/`forget`. Self-improving skill loop: `Curator` on an idle gate plus an isolated post-turn reviewer (`SelfImprove`) that authors/patches/consolidates `SKILL.md` skills (agentskills.io format). The same background pass does post-turn memory auto-capture and refreshes a dialectic per-user `UserModel` (both in `turn.ex`), and feeds a full-text `session_search` index. Config via `memory_provider/0` / `skills_provider/0` / `self_improve/0`. Remaining: recall-MCP bridge, hub client, paid skills.

**Video render target** (hermes-agent pickup): one TEA module to MP4/WebM/GIF, server-side frames at a virtual `Animation.Clock`, themed HTML via `TerminalBridge` rasterized through headless Chrome (zero-dep + warm-pool ChromicPDF), FFmpeg-encoded, `mix raxol.render`.

**Commerce rails:** agent payments with wallets (env + 1Password), ledger-enforced spending limits, and transparent HTTP-402 auto-pay across five protocols (x402, MPP, Xochi, Permit2, Riddler). Xochi is the cross-chain default (tier fees 0.10-0.40%, quote -> sign -> execute -> poll). PXE-bridge settlement (Glass Cube, 6 privacy tiers), ERC-5564/6538 stealth (`Xochi.Stealth`), ZKSAR attestation (6 proof types) + trust-tier routing. Riddler solver wired (ADR-0005, 9 endpoints, fee policy + privacy premiums). ~347 payments tests.

**`raxol_earn` v0.2 (pre-alpha):** first Elixir/OTP-native Virtuals Agent Commerce Protocol, v2 hook/event model on the deployed Base contracts (v1 memo model retired). `JobSession` state machine (`:open -> :budget_set -> :funded -> :submitted -> :completed` plus `:rejected`/`:expired`), on-chain writes via `HookClient` -> `AgenticCommerceV3` through an injected `ProviderAdapter` (SCA sponsored UserOps / JSONRPC EOA with `NonceServer` / Mock), full ERC-4337 SCA wallet (Alchemy Modular Account v2), Seller stack (`Backend.{InMemory, WebSocket}` + `Queue` + `Runtime`), `mix raxol_earn.bench`. 509 tests. Graduates on the first live Base-mainnet offering.

**Surfaces:** `raxol_telegram` (bot, per-chat router, inline keyboards; 34 tests), `raxol_speech` (TTS + Whisper STT + 21 voice commands; 28 tests), `raxol_watch` (APNS/FCM push, glanceable summaries, tap-to-event; 34 tests). `raxol_symphony` (0.2.0, pre-alpha): OTP port of OpenAI Symphony, a tracker-driven coding-agent orchestrator with two runners (`raxol_agent` + `codex`), three workflow modes (`default`/`graph`/`graph_parallel` batch fan-out), six surfaces, workflow hot-reload, evidence framework; 738 tests. Release-packaged; graduates on the first live run + Hex publish.

---

## Next Up

### Ship It

The twelve published Hex packages track two version lines: the framework packages (`raxol` + `raxol_core`/`raxol_terminal`/`raxol_agent`/`raxol_mcp`/`raxol_liveview`/`raxol_plugin`/`raxol_sensor`) at v2.6.0, and the independent payment/surface packages (`raxol_payments`, `raxol_speech`, `raxol_telegram`, `raxol_watch`) at v0.2.0. `raxol_earn` (0.2.0), `raxol_symphony` (0.2.0), and `raxol_gateway` stay pre-alpha and unpublished until they graduate.

| Task                      | Description                                                            | Effort |
| ------------------------- | --------------------------------------------------------------------- | ------ |
| Graduate `raxol_earn`      | Live run on Base mainnet with one offering, then the first Hex release | Medium |
| Graduate `raxol_symphony` | Parallel dispatch + 0.2.0 packaging landed; remaining: a live run against a real repo (see the package `RUNBOOK.md`), then `mix hex.publish` | Medium |

### Fast-Follow: Hermes Parity

Distilled from a fast-follow gap analysis vs [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent). Moat tags: **RAILS** = routes agent spend through the commerce rails · **SURFACE** = another projection of the one TEA module · **CATCH-UP** = table-stakes to stop losing users at the door. Guard: nothing here may compromise the single-module invariant or the frame budget.

**P0: funnel & reach**

| Item | What | Effort | Tag |
| ---- | ---- | ------ | --- |
| Install funnel | `flake.nix` (first PR) -> Burrito `curl \| bash` self-contained release (BEAM bundled, per-target termbox2 NIF, pure-Elixir driver on Windows) -> `raxol doctor`/`setup`/`update` -> Windows PowerShell installer | M | CATCH-UP |
| Gateway breadth | Graduate `raxol_gateway`: freeze the `Gateway.Adapter` behaviour, port Telegram behind it, then Discord + Email; wire `raxol_speech` STT as a shared pipeline stage so every adapter gets voice memos | M | SURFACE |
| Cron scheduler | `Raxol.Agent.Cron`: parse-once crontab / NL schedule, one lightweight GenServer per agent, deliver to any surface or gateway. Generalizes Symphony's polling loop | M | SURFACE |
| Memory remainder | The `UserModel` + post-turn auto-capture already ship; finish the `Provider.RecallMcp` bridge, optionally back `session_search` with SQLite FTS5, and extract `raxol_memory`/`raxol_skills` | S/M | RAILS-adjacent |

**P1: differentiation**

| Item | What | Effort | Tag |
| ---- | ---- | ------ | --- |
| Desktop app | Tauri shell over the LiveView surface with a Burrito'd BEAM sidecar (zero new UI); defaults the harness to `:openrouter` for the attribution funnel | L | SURFACE |
| Metered tool gateway | Creative-media actions (`image`/`video`/`tts`/`transcribe`) behind an axol-hosted service that answers HTTP 402; any 402-speaking agent auto-pays per call via x402/Xochi (the commerce wedge) | M | RAILS |
| Paid skills market | agentskills.io-format serializer + hub pull client + tradeable skills (a `SKILL.md` bundle with an ACP offering, settled on Base) | M | RAILS |
| Migration on-ramp | `mix raxol.import --from hermes/openclaw`: SOUL.md -> persona, memories -> `Memory.Store`, skills, allowlists -> PermissionHook | S | CATCH-UP |
| Windows first-class | Tune the pure-Elixir driver + Windows CI + the PowerShell installer path | M | CATCH-UP |
| OpenRouter funnel | Run the #414 live smoke with a real key, confirm the `openrouter.ai/apps?url=https://raxol.io` listing, bump site copy to v2.6 / 14 packages | S | Funnel |

**P2: deliberate laggards** (do when pulled, not pushed)

- **FLAME** elastic exec on Fly Machines (BEAM-native idle hibernation, replaces Modal/Daytona).
- More gateway adapters: Slack (Socket Mode), then WhatsApp / Signal on demand.
- i18n: wire the present `gettext` through surface rendering, extract locale files.
- Agent Client Protocol adapter (`raxol_agent` inside Zed/VS Code/JetBrains panels; distinct from `raxol_earn`).
- Expose the sandboxed REPL as an agent action for scripted single-turn tool pipelines.

**Do not build:** trajectory/training tooling, Singularity HPC backend, a 300-model subscription portal (that is Hermes's business; ours is settlement), or a `SOUL.md` personality system beyond what the import tool needs.

### Console runtime (Virtuals ACP)

Make Raxol a selectable runtime in the Virtuals ACP Console (`app.virtuals.io/acp/new`), beside Hermes and OpenClaw, with web3 native to the runtime (native `raxol_earn` plus the payment rails) rather than a bolted-on skill. Design in ADR-0031. It is the inverse of the `custom_console_agent` offering that already generates deployment packages for the other two runtimes.

| Item | What | Effort | Status |
| ---- | ---- | ------ | ------ |
| `:raxol` package target | Generator emits a raxol-targeted `soul.md`/`AGENTS.md`/`tasks.json`/`skills/`; `Console.Package` parses it back (round-trip tested) | S | DONE |
| Stage-3 seam | A scheduled task runs under the soul.md persona and delivers to a gateway channel (`Fire.runner` + `Scheduler.Delivery.gateway`), proven end-to-end | S | DONE |
| `raxol_console` loader | DONE. `RuntimeConfig` + `Scheduler.Wiring` + `Boot`/`Supervisor`/`Reconciler` (persona-wired scheduler + idempotent job convergence) + gateway channel subtree (per-chat sessions run the persona handler; MCP/dynamic tools dispatch via ReAct) + `Console.Bench.Adapter` (native bench: boots the runtime, runs boot/prompt/task-dry-run checks) + `Console.Application` (container entrypoint: plan from config/env -> load package -> boot; no-op when unconfigured, self-starts outside `:test`). 27 tests | M | DONE |
| Tool breadth to 40+ | DONE: dynamic-dispatch seam (`Action.Dynamic`) + `Agent.McpBundle` (default server set, fail-open, wraps each server's tools). `raxol_console` `Boot` loads the bundle and joins its tools into the chat handler's `:actions` (dispatched via ReAct). 25 built-ins + bundled filesystem/fetch/git/... -> ~50 callable tools | S | Done |
| Native ACP registration | Scaffolded: `Chain` registry-address field + `require_service_registry/1` fail-closed gate; `JobApi.register_agent/2` optional callback (Mock impl); idempotent `Seller.Registration.ensure_registered/3`. Blocked on Virtuals: registry address, HTTP register endpoint, identity standard (ERC-8004/8183), and the on-chain `HookClient.register_agent` variant | M | Scaffolded / partner-blocked |
| TEA app_module handler | Optional `Handler.Lifecycle` runtime mode for a stateful per-chat UI (issue #763) | M | Deferred |

The load-bearing unknown is external: the Console's third-party runtime-registration and container contract is undocumented, escalated to Virtuals (`~/Desktop/virtuals-console-runtime-questions.md`).

### RATE: Cross-Platform Test Bench

RATE (Raxol Automated Testing Environment). Model: FFmpeg's FATE (end-to-end reference-hash suite over a distributed runner network) plus checkasm (a pure reference *oracle* that an optimized path must match byte-for-byte), adapted to Nix-pinned self-hosted runners spanning x86_64 and aarch64 (Linux + Darwin) over a Tailscale mesh. The flake *is* the bench: `checks.<system>`, `packages.raxol-burrito-<triple>`, and a NixOS runner config are all flake outputs, so every runner is reproducible and architecture is the only variable, not environment drift. Closes three current gaps: the `termbox2` NIF is skipped in all CI today (`SKIP_TERMBOX2_TESTS=true`), there is no aarch64-linux tier, and the swarm/CRDT paths never run against a real multi-node cluster. All four layers are planned.

| Layer | What | FATE analogue |
| ----- | ---- | ------------- |
| Multi-arch checks | Run the full suite with the `termbox2` NIF actually built and exercised on x86_64-linux, aarch64-linux, and aarch64-darwin (plus the Windows pure-Elixir driver). Drop `SKIP_TERMBOX2_TESTS` on real hardware. | breadth matrix |
| Oracle + golden render | `IOTerminal` (pure-Elixir reference) vs the `termbox2` NIF, byte-exact for the same op stream; plus `mix raxol.rate`: a deterministic corpus of TEA apps -> ScreenBuffer/ANSI hash, references committed (`--gen`), compared per architecture. | checkasm oracle + reference md5 |
| Real-cluster swarm | Declaratively deploy the BEAM app across the mesh over Tailscale; orchestrate partition and heal; assert CRDT (`ORSet`/`LWWRegister`) convergence and topology re-election across real nodes. | (beyond FATE) |
| Burrito release matrix | Per-target self-contained binaries (aarch64/x86_64 Linux, Darwin, Windows) cross-compiled via zig; each smoke-tested on its actual silicon over the mesh before it is trusted. | reference run on real hardware |

Substrate: builds on the PR #441 flake. `nix run` / `bin/raxol` exposes both the interactive playground and a headless golden-render entrypoint (`Raxol.Release.golden/0`) reused as the per-arch smoke test.

Determinism discipline (the FATE rule, "flaky is deterministic, dig in"): render output must hash-stably. The virtual `Animation.Clock` is already frame-deterministic; the remaining guards are map-ordering leaks, locale-dependent Unicode width, and concurrent-render process ordering. A flaky golden hash is a real bug, not noise.

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
