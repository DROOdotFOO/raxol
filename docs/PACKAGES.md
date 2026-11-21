# Packages

Raxol ships as a main package plus focused subsystems. Use the main `raxol` package for the full framework, or take individual packages for narrower needs.

## Main

| Package                                            | Hex                       | What                                  |
| -------------------------------------------------- | ------------------------- | ------------------------------------- |
| [`raxol`](https://hex.pm/packages/raxol)           | `{:raxol, "~> 2.9"}`      | Full framework: runtime, UI, examples |

## Core

| Package                                                    | Hex                           | What                                       |
| ---------------------------------------------------------- | ----------------------------- | ------------------------------------------ |
| [`raxol_core`](https://hex.pm/packages/raxol_core)         | `{:raxol_core, "~> 2.9"}`     | Behaviours, events, config, plugins        |
| [`raxol_terminal`](https://hex.pm/packages/raxol_terminal) | `{:raxol_terminal, "~> 2.9"}` | Terminal emulation, termbox2 NIF           |
| [`raxol_mcp`](https://hex.pm/packages/raxol_mcp)           | `{:raxol_mcp, "~> 2.9"}`      | MCP server, client, registry, test harness |
| [`raxol_liveview`](https://hex.pm/packages/raxol_liveview) | `{:raxol_liveview, "~> 2.9"}` | Phoenix LiveView bridge, themes, CSS       |
| [`raxol_plugin`](https://hex.pm/packages/raxol_plugin)     | `{:raxol_plugin, "~> 2.9"}`   | Plugin SDK, testing, generator             |
| [`raxol_sensor`](https://hex.pm/packages/raxol_sensor)     | `{:raxol_sensor, "~> 2.9"}`   | Sensor fusion (zero deps)                  |
| [`raxol_journal`](https://hex.pm/packages/raxol_journal)   | `{:raxol_journal, "~> 2.9"}`  | Session journal, event contract            |

`raxol_agent` 3.x takes its journal from `raxol_journal`. `raxol_agent` 2.7.0 defines the same modules itself; do not add it and `raxol_journal` to one project.

## Agents

The agent packages live in [raxol-agent](https://github.com/DROOdotFOO/raxol-agent) and take the packages above from Hex.

| Package                                                                              | Hex                                        | What                                       |
| ------------------------------------------------------------------------------------ | ------------------------------------------ | ------------------------------------------ |
| [`raxol_agent`](https://hex.pm/packages/raxol_agent)                                 | `{:raxol_agent, "~> 3.1"}`                 | AI agent framework                         |
| [`raxol_payments`](https://hex.pm/packages/raxol_payments)                           | `{:raxol_payments, "~> 0.3"}`              | Agent payments, Xochi cross-chain, stealth |
| [`raxol_agent_client_protocol`](https://hex.pm/packages/raxol_agent_client_protocol) | `{:raxol_agent_client_protocol, "~> 0.1"}` | Editor<->agent Agent Client Protocol       |

`raxol_earn`, `raxol_cli`, `raxol_console`, `raxol_web3` and `raxol_broker` are pre-alpha and unpublished.

The **Harness** is the agent-session engine: the event contract `Raxol.Agent.Contract` and the durable journal `Raxol.Agent.Journal` in `raxol_journal`, the session processes in `raxol_agent`, the projections and surface widgets `Raxol.Harness.*` in main `raxol`. The `mix raxol.harness.*.bless` tasks only regenerate its golden/fixture test snapshots.

`raxol_symphony`, the tracker-driven coding-agent orchestrator, left this repository on 2026-10-27 (ADR-0043). It is frozen at [DROOdotFOO/raxol-symphony](https://github.com/DROOdotFOO/raxol-symphony): archived, unpublished, its raxol dependencies pinned to `ce40937c4`.

## Surfaces

| Package                                                    | Hex                           | What                                        |
| ---------------------------------------------------------- | ----------------------------- | ------------------------------------------- |
| [`raxol_speech`](https://hex.pm/packages/raxol_speech)     | `{:raxol_speech, "~> 0.3"}`   | TTS (say/espeak), STT (Whisper), voice cmds |
| [`raxol_telegram`](https://hex.pm/packages/raxol_telegram) | `{:raxol_telegram, "~> 0.3"}` | Telegram bot, per-chat sessions, keyboards  |
| [`raxol_gateway`](https://hex.pm/packages/raxol_gateway)   | `{:raxol_gateway, "~> 0.2"}`  | Unified messaging gateway (multi-platform)  |
| [`raxol_watch`](https://hex.pm/packages/raxol_watch)       | `{:raxol_watch, "~> 0.3"}`    | APNS/FCM push, glanceable summaries         |

## Dependency graph

```
raxol --> raxol_core, raxol_terminal, raxol_sensor, raxol_mcp,
          raxol_liveview, raxol_plugin

raxol_terminal --> raxol_core
raxol_mcp      --> raxol_core
raxol_liveview --> raxol_core (+ phoenix_live_view optional)
raxol_plugin   --> raxol_core

raxol_speech   --> raxol_core (+ bumblebee/nx/exla optional for STT)
raxol_telegram --> raxol_core (+ raxol/telegex/raxol_gateway optional)
raxol_watch    --> raxol_core (+ pigeon optional for APNS/FCM)
raxol_gateway  --> raxol_core (+ raxol/raxol_speech optional)

raxol_core     --> telemetry (only external dep)
raxol_sensor   --> (none)
raxol_journal  --> jason, telemetry (zero raxol deps)
```

The main `raxol` package does not depend on `raxol_journal`, `raxol_gateway`, the surface packages, or any agent package. You opt into those.

### Boundary rule

The arrows are the only direction code may call. A package reaches modules in its own tree and in the trees of the packages its `mix.exs` declares (transitively), never in main `raxol` or in a sibling it does not list: `raxol_core` cannot name `Raxol.Terminal.*`, and `raxol_terminal` cannot name anything that lives under the root `lib/`. Each package compiles standalone in CI with `--warnings-as-errors`, so such a call is a compile error there unless the file hides it behind `@compile {:no_warn_undefined, Mod}`, which is how `Raxol.Terminal.Config.Capabilities.optimized_config/0` and `Raxol.Terminal.Theme.Manager.load_from_registry/2` came to raise `UndefinedFunctionError` whenever `raxol_terminal` ran without main `raxol`. `elixir scripts/check_package_boundaries.exs` (the `Check package boundaries` step of CI) parses every file under `packages/*/lib`, resolves each module it names (remote calls and captures, `apply/3`, every form of `no_warn_undefined`, `:"Elixir.X"` atoms, `use`/`import`/`@behaviour`, typespecs, module and process names used as values) to the tree that defines it, and fails on one the package does not declare. Declared means listed in the package's `mix.exs` `deps` without an `only:` that leaves out `:prod`; a dependency named in a comment does not count. The grandfathered sites are in `scripts/.package-boundaries-allowlist`, which only shrinks: a stale entry fails the check, and on a pull request so does an entry the base commit's list does not have. Fix a report by moving the module into the package that owns the concept (`Raxol.Core.Theming.ThemeRegistry` now lives in `raxol_core`), by reading the implementation from application config with an in-package default (`Raxol.Core.UserPreferences` reads its terminal defaults from `:default_terminal_preferences`, which `raxol_terminal` ships in its application env as `{Raxol.Terminal.Config.Defaults, :generate_default_config, []}` and `config :raxol_core, :default_terminal_preferences, ...` overrides), or by deleting the dead call. `Code.ensure_loaded?/1` is not a fix: it is the guard that hid the originals.

The same check draws a second line, between the runtime side (main `raxol`, `raxol_core`, `raxol_terminal`, `raxol_liveview`, `raxol_mcp`, `raxol_plugin`, `raxol_sensor`, `raxol_speech`, `raxol_telegram`, `raxol_watch`, `raxol_gateway`, `raxol_journal`) and the agent side (`raxol_agent`, `raxol_payments`, `raxol_broker`, `raxol_earn`, `raxol_web3`, `raxol_console`, `raxol_cli`, `raxol_agent_client_protocol`). No runtime-side `lib/`, `config/` or `mix.exs`, and no template (`*.eex`, `*.heex`, `*.leex`) under a runtime tree's `config/`, `lib/`, `priv/`, `rel/` or `src/`, or Erlang source under its `src/`, names agent-side code: a module under `Raxol.Agent.*`, `Raxol.Payments.*`, `Raxol.Broker.*`, `Raxol.Earn.*`, `Raxol.Web3.*`, `Raxol.Console.*`, `Raxol.CLI.*` or `Raxol.AgentClientProtocol.*`, an agent-side module outside those namespaces, listed by exact name (`Raxol.Gateway.Handler.Agent`, `Raxol.MCP.AgentBridge` and three Mix tasks), a module whose name ends in one of those (a protocol implementation, a Mix task), or an agent application's name, as an atom or as a whole word in a string. In a `mix.exs` that means a dependency of any kind, and after `packages/` or `../` a path into the agent tree. The rule goes by name alone, so it holds with the agent packages in another repository. Calls, `apply/3`, atoms, process names, `alias` targets, the literal start of a `Module.concat` and strings that carry a module name all count; comments and the text of `@moduledoc`, `@doc`, `@typedoc`, `@shortdoc` and `@deprecated` do not. Tests, scripts and `bin/` are not read. The modules `raxol_journal` defines under `Raxol.Agent.Journal` and `Raxol.Agent.Contract`, and the four the root defines under `Raxol.CLI`, are exempt by exact name. This line has no allowlist, and an allowlist entry whose file and owning tree are on different sides fails. The agent side may depend on the runtime side through declared dependencies; where one application needs both, the code that joins them lives on the agent side (`raxol_console` holds the gateway's agent handler and passes the scheduler its delivery closure).

## Publishing

See the [Release checklist](https://github.com/DROOdotFOO/raxol/blob/master/docs/development/RELEASE_CHECKLIST.md#publish-the-public-hex-train) for the publish order. `HEX_BUILD=1` strips local path deps so `mix hex.build` sees only Hex packages.

Run `mix raxol.release.check` before publishing anything. It walks the public train in dependency order and, per package, validates the metadata, confirms every file the tarball would carry is tracked by git, and runs `mix hex.build --unpack` without publishing. `--metadata-only` skips the builds; `mix raxol.check` runs that faster half for you.

Two failures are worth recognising on sight:

- `packaged file X is not tracked by git`: `mix hex.build` packages the working tree, not the commit, so an untracked file under a packaged directory really would ship. Dotfiles count: `.env`, `.env.*` and `.secrets` are gitignored, which makes them untracked by construction and exactly what this catches. Commit it, ignore it via `:exclude_patterns`, or narrow the `:files` entry. `--allow-untracked` downgrades this to a warning, which is what `mix raxol.check` passes so an unstaged new module does not fail the interactive gate; CI runs without it.
- `published tarball omits release dependency X`: a `HEX_BUILD` conditional in that package's `mix.exs` removed a dependency on a package of the train, so Hex consumers would not get it. Declare the requirement in the published form too.
