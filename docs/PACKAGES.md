# Packages

Raxol ships as a main package plus 18 focused subsystems. Use the main `raxol` package for the full framework, or take individual packages for narrower needs.

## Main

| Package                                            | Hex                       | What                                  |
| -------------------------------------------------- | ------------------------- | ------------------------------------- |
| [`raxol`](https://hex.pm/packages/raxol)           | `{:raxol, "~> 2.7"}`      | Full framework: runtime, UI, examples |

## Core

| Package                                                    | Hex                           | What                                       |
| ---------------------------------------------------------- | ----------------------------- | ------------------------------------------ |
| [`raxol_core`](https://hex.pm/packages/raxol_core)         | `{:raxol_core, "~> 2.8"}`     | Behaviours, events, config, plugins        |
| [`raxol_terminal`](https://hex.pm/packages/raxol_terminal) | `{:raxol_terminal, "~> 2.7"}` | Terminal emulation, termbox2 NIF           |
| [`raxol_mcp`](https://hex.pm/packages/raxol_mcp)           | `{:raxol_mcp, "~> 2.7"}`      | MCP server, client, registry, test harness |
| [`raxol_liveview`](https://hex.pm/packages/raxol_liveview) | `{:raxol_liveview, "~> 2.7"}` | Phoenix LiveView bridge, themes, CSS       |
| [`raxol_plugin`](https://hex.pm/packages/raxol_plugin)     | `{:raxol_plugin, "~> 2.7"}`   | Plugin SDK, testing, generator             |
| [`raxol_sensor`](https://hex.pm/packages/raxol_sensor)     | `{:raxol_sensor, "~> 2.7"}`   | Sensor fusion (zero deps)                  |

## Agents

| Package                                                    | Hex                           | What                                        |
| ---------------------------------------------------------- | ----------------------------- | ------------------------------------------- |
| [`raxol_agent`](https://hex.pm/packages/raxol_agent)       | `{:raxol_agent, "~> 2.7"}`    | AI agent framework                          |
| [`raxol_payments`](https://hex.pm/packages/raxol_payments) | `{:raxol_payments, "~> 0.3"}` | Agent payments, Xochi cross-chain, stealth  |
| `raxol_earn` (pre-alpha)                                    | `path: "packages/raxol_earn"`  | Virtuals Agent Commerce Protocol (seller)   |
| `raxol_agent_client_protocol` (pre-alpha)                  | `path: "packages/raxol_agent_client_protocol"` | Editor<->agent Agent Client Protocol (agentclientprotocol.com) |
| `raxol_gateway` (pre-alpha)                                | `path: "packages/raxol_gateway"`  | Unified messaging gateway (multi-platform) |
| `raxol_cli` (pre-alpha)                                    | `path: "packages/raxol_cli"`      | The `raxol` command (`code`, `p`, `acp`, `agent`, `playground`, `new`), packaged as a self-contained Burrito binary |
| `raxol_console` (pre-alpha)                                | `path: "packages/raxol_console"`  | Boots a Virtuals ACP Console agent package onto the gateway stack |
| `raxol_web3` (pre-alpha)                                   | `path: "packages/raxol_web3"`     | Guarded outbound client, six chain backends, indexer-agnostic reads (ADR-0033, ADR-0038, ADR-0039) |
| `raxol_broker` (pre-alpha)                                 | `path: "packages/raxol_broker"`   | Fail-closed brokerage policy parsing and initialization |

The **coding agent** layers as: `Backend.Selector` (LLM backend adapter) -> the **Harness** engine (the event/command contract `Raxol.Agent.Contract` and the durable journal `Raxol.Agent.Journal` in `raxol_agent`, the projections and surface widgets `Raxol.Harness.*` in main `raxol`) -> the product surfaces `mix raxol.code` (interactive TUI, also over SSH), `mix raxol.p` (headless one-shot), and `mix raxol.acp` (ACP on stdio, for editors), all three in `raxol_agent`. The Harness is the engine; the `mix raxol.harness.*.bless` tasks only regenerate its golden/fixture test snapshots.

`raxol_symphony`, the tracker-driven coding-agent orchestrator, left this repository on 2026-10-27 (ADR-0043). It is frozen at [DROOdotFOO/raxol-symphony](https://github.com/DROOdotFOO/raxol-symphony): archived, unpublished, its raxol dependencies pinned to `ce40937c4`.

## Surfaces

| Package                                                    | Hex                           | What                                        |
| ---------------------------------------------------------- | ----------------------------- | ------------------------------------------- |
| [`raxol_speech`](https://hex.pm/packages/raxol_speech)     | `{:raxol_speech, "~> 0.2"}`   | TTS (say/espeak), STT (Whisper), voice cmds |
| [`raxol_telegram`](https://hex.pm/packages/raxol_telegram) | `{:raxol_telegram, "~> 0.2"}` | Telegram bot, per-chat sessions, keyboards  |
| [`raxol_watch`](https://hex.pm/packages/raxol_watch)       | `{:raxol_watch, "~> 0.2"}`    | APNS/FCM push, glanceable summaries         |

## Dependency graph

```
raxol --> raxol_core, raxol_terminal, raxol_sensor, raxol_mcp,
          raxol_liveview, raxol_plugin

raxol_terminal --> raxol_core
raxol_mcp      --> raxol_core
raxol_liveview --> raxol_core (+ phoenix_live_view optional)
raxol_plugin   --> raxol_core

raxol_agent    --> raxol + raxol_mcp (+ raxol_web3 optional, for the `web3` tool)
raxol_payments --> raxol_agent (compile-time only)
raxol_earn      --> raxol_payments (runtime), raxol_mcp + raxol_agent (compile-time only)
raxol_agent_client_protocol --> (none; jason only, zero raxol deps)
raxol_cli      --> raxol, raxol_agent (+ raxol_agent_client_protocol for `raxol acp`)
raxol_console  --> raxol_agent, raxol_gateway, raxol_earn
raxol_web3     --> raxol_core, raxol_mcp (+ mint, castore)
raxol_broker   --> raxol_agent (+ decimal)

raxol_speech   --> raxol_core (+ bumblebee/nx/exla optional for STT)
raxol_telegram --> raxol_core (+ raxol/telegex/raxol_gateway optional)
raxol_watch    --> raxol_core (+ pigeon optional for APNS/FCM)
raxol_gateway  --> raxol_core (+ raxol_agent optional)

raxol_core     --> telemetry (only external dep)
raxol_sensor   --> (none)
```

The main `raxol` package does not depend on `raxol_agent`, `raxol_broker`, `raxol_earn`, `raxol_agent_client_protocol`, `raxol_gateway`, or any of the surface packages. You opt into those.

### Boundary rule

The arrows are the only direction code may call. A package reaches modules in its own tree and in the trees of the packages its `mix.exs` declares (transitively), never in main `raxol` or in a sibling it does not list: `raxol_core` cannot name `Raxol.Terminal.*`, and `raxol_terminal` cannot name anything that lives under the root `lib/`. Each package compiles standalone in CI with `--warnings-as-errors`, so such a call is a compile error there unless the file hides it behind `@compile {:no_warn_undefined, Mod}`, which is how `Raxol.Terminal.Config.Capabilities.optimized_config/0` and `Raxol.Terminal.Theme.Manager.load_from_registry/2` came to raise `UndefinedFunctionError` whenever `raxol_terminal` ran without main `raxol`. `elixir scripts/check_package_boundaries.exs` (the `Check package boundaries` step of CI) parses every file under `packages/*/lib`, resolves each module it names (remote calls and captures, `apply/3`, every form of `no_warn_undefined`, `:"Elixir.X"` atoms, `use`/`import`/`@behaviour`, typespecs, module and process names used as values) to the tree that defines it, and fails on one the package does not declare. Declared means listed in the package's `mix.exs` `deps` without an `only:` that leaves out `:prod`; a dependency named in a comment does not count. The grandfathered sites are in `scripts/.package-boundaries-allowlist`, which only shrinks: a stale entry fails the check, and on a pull request so does an entry the base commit's list does not have. Fix a report by moving the module into the package that owns the concept (`Raxol.Core.Theming.ThemeRegistry` now lives in `raxol_core`), by reading the implementation from application config with an in-package default (`Raxol.Core.UserPreferences` reads its terminal defaults from `:default_terminal_preferences`, which `raxol_terminal` ships in its application env as `{Raxol.Terminal.Config.Defaults, :generate_default_config, []}` and `config :raxol_core, :default_terminal_preferences, ...` overrides), or by deleting the dead call. `Code.ensure_loaded?/1` is not a fix: it is the guard that hid the originals.

## Publishing

See the [Release checklist](https://github.com/DROOdotFOO/raxol/blob/master/docs/development/RELEASE_CHECKLIST.md#publish-the-public-hex-train) for the publish order. `HEX_BUILD=1` strips local path deps so `mix hex.build` sees only Hex packages.

Run `mix raxol.release.check` before publishing anything. It walks the public train in dependency order and, per package, validates the metadata, confirms every file the tarball would carry is tracked by git, and runs `mix hex.build --unpack` without publishing. `--metadata-only` skips the builds; `mix raxol.check` runs that faster half for you.

Two failures are worth recognising on sight:

- `packaged file X is not tracked by git`: `mix hex.build` packages the working tree, not the commit, so an untracked file under a packaged directory really would ship. Dotfiles count: `.env`, `.env.*` and `.secrets` are gitignored, which makes them untracked by construction and exactly what this catches. Commit it, ignore it via `:exclude_patterns`, or narrow the `:files` entry. `--allow-untracked` downgrades this to a warning, which is what `mix raxol.check` passes so an unstaged new module does not fail the interactive gate; CI runs without it.
- `release dependency X is dropped from the published tarball`: a `HEX_BUILD` conditional in that package's `mix.exs` removed a dependency. Intended for pre-alpha packages that are not on the train yet, and reported as a warning so the choice stays visible rather than silent.
