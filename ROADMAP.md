# Raxol Roadmap

Multi-surface application runtime for Elixir. One TEA module, four render targets.

## Current Version: v2.6.1

---

## What's Done

**Framework core (Phases 1-6):** TEA architecture, full render pipeline, 16 first-class widget types (`Raxol.UI.Registry`), focus + W3C-style event capture/bubble, terminal compat (color downsampling, Unicode width, synchronized output), playground (42 demos / 8 categories), 7 braille-resolution charts, Hex packaging, `mix raxol.new`, session recording.

**OTP differentiators:** process-per-component crash isolation, hot code reload, LiveView bridge, SSH app serving, time-travel debugging (snapshot every `update/2`), distributed swarm (CRDTs, topology election, libcluster + Tailscale).

**Adaptive UI + effects:** 8-rule LayoutRecommender, TrendDetector, Nx auto-retrain, Lifecycle integration, 5 MCP tools. Animation hints (Phase 15): declarative `view/1` metadata to every surface (`animate`/`stagger`/`sequence`), terminal frames server-side, LiveView CSS with `prefers-reduced-motion`, MCP JSON hints. BorderBeam effect (three-layer glow, 4 variants, terminal + LiveView + MCP).

**MCP surface (Phases 8-13):** extracted `raxol_mcp` (server/client/registry, stdio + SSE). Auto-derives tools from the widget tree (16 Component modules implement `ToolProvider`) with a focus/hover lens; `@mcp_exclude` opt-out. Full spec coverage (prompts, logging, completion, notifications, circuit breaker). Resources + ContextTree + StructuredScreenshot + model-projection diffs. Pipe-friendly test harness with functor-law property tests.

**Agent packages:** the agent framework, payments, commerce, and the editor protocol live in [raxol-agent](https://github.com/DROOdotFOO/raxol-agent) and build on this runtime from Hex (ADR-0043).

**Video render target** (hermes-agent pickup): one TEA module to MP4/WebM/GIF, server-side frames at a virtual `Animation.Clock`, themed HTML via `TerminalBridge` rasterized through headless Chrome (zero-dep + warm-pool ChromicPDF), FFmpeg-encoded, `mix raxol.render`.

**Surfaces:** `raxol_telegram` (bot, per-chat router, inline keyboards), `raxol_speech` (TTS + Whisper STT + 21 voice commands), `raxol_watch` (APNS/FCM push, glanceable summaries, tap-to-event), `raxol_gateway` (one frozen adapter contract with Telegram, Discord and Email behind it, voice memos through `raxol_speech` STT).

---

## Next Up

### Ship It

The Hex packages this repository releases track two version lines: the framework packages (`raxol` + `raxol_core`/`raxol_terminal`/`raxol_mcp`/`raxol_liveview`/`raxol_plugin`/`raxol_sensor`/`raxol_journal`) move in lockstep on the 2.9.x line, and the independent surface packages (`raxol_speech`, `raxol_telegram`, `raxol_watch`, `raxol_gateway`) have their own 0.x line. The agent packages release from raxol-agent. Exact versions live in each `mix.exs` and are enforced by `scripts/check-lockstep-deps.sh`; do not restate them here, where nothing validates them.

### Surfaces and reach

Guard: nothing here may compromise the single-module invariant or the frame budget.

| Item | What | Effort |
| ---- | ---- | ------ |
| Desktop app | Tauri shell over the LiveView surface with a Burrito'd BEAM sidecar (zero new UI) | L |
| Windows first-class | Tune the pure-Elixir driver and add Windows CI | M |

Do when pulled, not pushed:

- More gateway adapters: Slack (Socket Mode), then WhatsApp / Signal on demand.
- i18n: wire the present `gettext` through surface rendering, extract locale files.

### MCP

| Item | What | Effort | Status |
| ---- | ---- | ------ | ------ |
| `Raxol.MCP.Aggregator` | The one missing conversion direction: upstream MCP server -> `Raxol.MCP.Registry` tool defs, over the existing `MCP.Client`, with a janitor lifecycle and `admit/1` bounds | S | Planned |

### RATE: Cross-Platform Test Bench

RATE (Raxol Automated Testing Environment). Model: FFmpeg's FATE (end-to-end reference-hash suite over a distributed runner network) plus checkasm (a pure reference *oracle* that an optimized path must match byte-for-byte), adapted to Nix-pinned self-hosted runners spanning x86_64 and aarch64 (Linux + Darwin) over a Tailscale mesh. The flake *is* the bench: `checks.<system>`, `packages.raxol-burrito-<triple>`, and a NixOS runner config are all flake outputs, so every runner is reproducible and architecture is the only variable, not environment drift. Closes three current gaps: the `termbox2` NIF is skipped in all CI today (`SKIP_TERMBOX2_TESTS=true`), there is no aarch64-linux tier, and the swarm/CRDT paths never run against a real multi-node cluster. All four layers are planned.

| Layer | What | FATE analogue |
| ----- | ---- | ------------- |
| Multi-arch checks | Run the full suite with the `termbox2` NIF actually built and exercised on x86_64-linux, aarch64-linux, and aarch64-darwin (plus the Windows pure-Elixir driver). Drop `SKIP_TERMBOX2_TESTS` on real hardware. | breadth matrix |
| Oracle + golden render | `IOTerminal` (pure-Elixir reference) vs the `termbox2` NIF, byte-exact for the same op stream; plus `mix raxol.rate`: a deterministic corpus of TEA apps -> ScreenBuffer/ANSI hash, references committed (`--gen`), compared per architecture. | checkasm oracle + reference md5 |
| Real-cluster swarm | Declaratively deploy the BEAM app across the mesh over Tailscale; orchestrate partition and heal; assert CRDT (`ORSet`/`LWWRegister`) convergence and topology re-election across real nodes. | (beyond FATE) |
| Burrito release matrix | Per-target self-contained binaries (aarch64/x86_64 Linux, Darwin, Windows) cross-compiled via zig; each smoke-tested on its actual silicon over the mesh before it is trusted. | reference run on real hardware |

Substrate: the Nix flake. `nix run` exposes both the interactive playground and a headless golden-render entrypoint (`Raxol.Release.golden/0`) reused as the per-arch smoke test.

Determinism discipline (the FATE rule, "flaky is deterministic, dig in"): render output must hash-stably. The virtual `Animation.Clock` is already frame-deterministic; the remaining guards are map-ordering leaks, locale-dependent Unicode width, and concurrent-render process ordering. A flaky golden hash is a real bug, not noise.

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
