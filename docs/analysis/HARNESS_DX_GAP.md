# Harness DX gap: the Raxol coding agent vs grok-build

Scored 2026-08-07 at commit `fce2465bb` (master). Reference target: xai-org/grok-build,
the Rust coding-agent harness (fullscreen TUI, Apache-2.0). Every HAVE and PARTIAL row
cites a file and line read at this commit. Rows marked runtime-verified were also
exercised, with real output recorded.

Commands run for ground truth:

- `mix raxol.check --quick` (after `mix deps.get`): 6 passed, 1 warning (credo).
  Before the deps sync the same command failed rate and test on a stale local
  `deps/postgrex`, and the docs step warned "Documentation drift detected".
- `mix help | grep raxol`: 35 tasks recorded; `raxol.code`/`raxol.p` are absent from
  the root task list because they are package-scoped to `raxol_agent`.
- `bin/raxol-code --help`: fails with `raxol.code: unknown options: [{"--help", nil}]`, exit 64.
- `bin/raxol-code --sessions`: works; lists `~/.raxol/code_sessions`.
- `mix raxol.p "<prompt>"` with no provider configured: JSONL contract events on stderr
  (`turn_started`, then `error` with `econnrefused` against localhost:1234).
- `npm view raxol`: E404. The npm package exists in-repo but has never been published.

## What the harness actually is today

The coding-agent product is two surfaces in `packages/raxol_agent`: `mix raxol.code`
(interactive TUI; boots `Raxol.Agent.Code.App`, a ~1730-line TEA app) and `mix raxol.p`
(headless one-shot twin: answer on stdout, one JSON contract event per line on stderr,
exit codes 0/1/2/64). `mix raxol.setup` is the non-TUI `/login` twin for CI. Repo-root
shims `bin/raxol-code` and `bin/raxol` run the tasks from the package with
`RAXOL_CLI_CWD` scoping tools to the caller's cwd. Main raxol does not depend on
raxol_agent, so neither task is reachable from the repo root without the shims.

The TUI is genuinely capable: provider auto-detect through `Backend.Resolver`
(explicit key, then 1Password `op://` reference, then provider env vars, then generic
`AI_API_KEY`), an onboarding wizard instead of a crash when nothing resolves, `/login`
with reference-first secret hygiene (raw keys are session-only unless explicitly saved
to 1Password), plan mode (Shift+Tab), a pure ALLOW/ASK/DENY `Authorization.Engine`
gating every mutating tool with a 300s deny-default timeout, per-session "always allow"
memory, `.raxol/hooks.json` lifecycle hooks with pre-hook veto, `.raxol/config.json`
per-repo provider pins, a read-only `task` subagent, session persistence with
`--continue`/`--resume`/`--sessions`, and ten slash commands
(`/help /login /clear /model /plan /compact /context /sessions /mcp /hooks`).

Around it sits substantial framework machinery that the coding surface does not use:
a durable append-only journal (`Raxol.Agent.Journal.FileStore`) with writerless
offset-based `Reattach`, a branch-aware event contract (`branch_id` on every event, no
writer ever mints a non-main branch), checkpoint write/restore, `SessionInbox` prompt
queueing, `Steer` mid-turn redirection, `SpendGate`/`BlastRadiusGate` (the latter a
skeleton), memory providers, self-improvement and skills curation loops, MCP tool
bridging (`McpBundle`, shipped on the Console runtime), an ACP `TurnRunner` bridge for
editors, a scrollback-capable harness `Surface` with a multiline `Composer`
(fixture-only), asciinema record/replay, and time-travel debugging. The TUI persists
sessions as JSON through `Code.Store`; the journal is never attached on this path.

Packaging is split three ways: `bin/raxol-code` (repo checkout required), a real 68MB
Burrito binary in `packages/raxol_cli` wrapped in an unpublished npm package named
`raxol` (its `agent` subcommand is a line-based chat loop, and the TUI harness is not
in the binary), and `packages/raxol_console` (a second Burrito+npm packaging for the
Virtuals Console runtime).

## Score key

- HAVE: shipping, with the module/task/command that provides it.
- PARTIAL: exists behind a worse ergonomic (wrong entry point, undocumented,
  config required, or one surface only).
- MISSING: not present.
- N/A-BETTER: solved differently and better; justified, with a falsifier.

Totals over 65 rows: 9 HAVE, 38 PARTIAL, 18 MISSING, 0 N/A-BETTER. The shape of the
result: Raxol has the hard parts (authorization engine, plan mode, durable persistence,
typed headless contract, credential hygiene) and lacks cheap surface conveniences. Most
PARTIAL rows are framework machinery that exists and is not wired into `mix raxol.code`.
No row scored N/A-BETTER: where Raxol solves something differently (reference-first
login, backslash multiline continuation), the different solution is either unwired from
the coding surface or not clearly better for a new user's first ten minutes. The places
the BEAM genuinely goes past grok-build are covered as overtake items in
[HARNESS_DX_BACKLOG.md](HARNESS_DX_BACKLOG.md).

## Gap matrix

### Onboarding

| grok-build row | Score | Raxol reality |
|---|---|---|
| One-line installer, prebuilt macOS/Linux/Windows binaries | PARTIAL | Full pipeline exists unpublished: Burrito release (`packages/raxol_cli/mix.exs:42`, targets linux x86_64/aarch64 + macos aarch64, no Windows), built 68MB binary (`packages/raxol_cli/burrito_out/raxol_cli_macos`), npm wrapper (`packages/raxol_cli/npm/package.json:6`), tag-gated release workflow (`.github/workflows/release-raxol-cli.yml:14`). `npm view raxol` 404s; no `raxol-cli-v*` tag exists. README install section (`README.md:58`) offers hex, `mix raxol.new`, and nix only. |
| First run: `cd project && grok`, browser OAuth, env-key fallback | PARTIAL | No OAuth, but the resolver chain is strong: `raxol.code.ex:132` resolves via `Backend.Resolver` (`resolver.ex:20`: key > op:// ref > env vars; `resolver.ex:281`: generic `AI_API_KEY`); no-provider opens the wizard (`raxol.code.ex:174`, `app.ex:101`); `mix raxol.setup` covers CI (`raxol.setup.ex:2`). Deltas: package-scoped entry point; `raxol.p` bypasses the Resolver and dies econnrefused against lm_studio localhost (`backend/cli.ex:18`, runtime-verified); `--help` errors (`raxol.code.ex:76`). |
| First prompt: docs hand you literal starter prompts | PARTIAL | Starter prompts exist only on the headless surface (`raxol.p.ex:7`) and one API example (`BUILD_AN_AGENT.md:93`). `docs/features/CODING_AGENT.md` contains zero example prompts and the TUI shows no first-run suggestions. |
| Build from source: pinned toolchain, vendored tools, few documented commands | HAVE | `.tool-versions:1` pins erlang 29.0.3 / elixir 1.20.2-otp-29; termbox2 NIF source vendored (`packages/raxol_terminal/lib/termbox2_nif/c_src/Makefile:1`); README documents the full headless from-source block (`README.md:152`); `nix develop` matches the pins and is CI-checked (`flake.nix:26`, `.github/workflows/nix.yml:33`). Caveats: no committed flake.lock; the coding agent needs an extra `cd packages/raxol_agent && mix deps.get`. |
| Discoverability: `grok inspect` dumps every config source, skill, plugin, hook, MCP server | PARTIAL | The pieces exist scattered: `mix raxol.setup --status` (`raxol.setup.ex:181`), `Resolver.diagnostics/0` (`resolver.ex:164`), `/mcp` server list (`app.ex:868`), `/hooks` counts only (`app.ex:876`), `.raxol/config.json` silently applied (`project_config.ex:3`). No single inspect command; no instruction-file discovery at all (zero references to AGENTS.md or CLAUDE.md in `packages/raxol_agent`); skills have no user-facing listing (`raxol.p.ex:189`). |

### Runtime modes

| grok-build row | Score | Raxol reality |
|---|---|---|
| Interactive fullscreen mouse TUI (scrollback, prompt, modals, themes) | PARTIAL | Fullscreen yes: alt-screen + hidden cursor (`driver.ex:186`) and SGR mouse enabled at the terminal (`driver.ex:192`). But mouse events normalize to `:other` and are dropped (`input_event.ex:69`, `app.ex:255`); the transcript is an unscrollable column (`app.ex:1629`); theme is hard-pinned (`app.ex:1631`). The scrollback-preserving DECSTBM `Surface` exists fixture-only (`lib/raxol/harness/surface.ex:31`, `:106`); `LiveSessionDriver` has zero non-test consumers (`live_session_driver.ex:1`). Modals (wizard, approval footer) are real (`app.ex:343`, `:1683`). |
| Headless `-p` with streaming JSON for scripting/CI | HAVE | Runtime-verified: `mix raxol.p` streams the answer to stdout and one JSON contract event per line to stderr (`raxol.p.ex:19`, `:221`, `:248`), deterministic exit codes (`raxol.p.ex:45`), `--write`/`--no-tools`/`--timeout`. Deltas: no `--output-format` selector (JSON is always on, on stderr), and the no-provider default is lm_studio localhost (`raxol.p.ex:33`), so a fresh machine gets econnrefused rather than a setup hint. |
| Embedded: ACP for editors | PARTIAL | The protocol package is complete (schema, JSON-RPC, stdio transport with `:self` mode: `transport/stdio.ex:3`) and the harness is bridged both directions (`turn_runner.ex:3`, `acp_stream_adapter.ex:1`). But no shipped launcher exists: ACP is a dev/test-only path dep of raxol_agent (`packages/raxol_agent/mix.exs:51`), no non-test module uses the Agent behaviour, and an editor would have to write the README quickstart wiring itself. `editors/` is LSP/treesitter tooling, pointing at a nonexistent `mix raxol.lsp`. |
| Entry points: leader / stdio / headless split | PARTIAL | Four launchers, uneven: TUI (`raxol.code.ex:91`), headless (`raxol.p.ex:68`), MCP stdio (`mcp.server.ex:44`; MCP, not ACP, and does not expose the coding loop), packaged binary (`cli.ex:15`) whose `agent` is a deliberately line-based loop (`cli.ex:30`), not the TUI. Only `bin/raxol` handles `-h/--help` (`bin/raxol:27`); the TUI entry does not (runtime-verified). |

### Session lifecycle

| grok-build row | Score | Raxol reality |
|---|---|---|
| /new | HAVE | `/clear` mints a fresh session non-destructively (`app.ex:1333`, comment at `:1331`); flag-less launch does the same (`raxol.code.ex:178`). Named differently; no new-with-different-cwd. |
| /resume | PARTIAL | Launch flags only: `--continue`/`--resume` rebuild both context and scrollback (`raxol.code.ex:178`, `app.ex:185`; runtime-verified). No in-TUI resume or picker; `raxol.p` has no persistence at all (`raxol.p.ex:106`). |
| /sessions | HAVE | Both `--sessions` (`raxol.code.ex:101`; runtime-verified) and in-TUI `/sessions` (`app.ex:856`, `:1463`). Output is `id (N msgs)` only: no title, age, cwd, or picker. |
| /fork | MISSING | Slash set is closed (`app.ex:842`). The contract is branch-aware by design (`contract.ex:185`, `journal/tip.ex:91`, `emit_bridge.ex:197`) but no code path mints a non-main branch, and the TUI does not attach the journal (`app.ex:499`). Schema ready, feature absent. |
| /rename | MISSING | Sessions have no name field (`store.ex:22`); ids are minted timestamps (`app.ex:205`). |
| /share (URL) | MISSING | Only local JSON persistence (`store.ex:43`); no upload, no URL, no command. |
| /session-info | PARTIAL | Subsumed by `/context` (`app.ex:1457`): counts, plan, model, session key. Persisted cwd/updated_at never shown (`store.ex:47`); no token totals despite usage in the event stream. |

### Session context

| grok-build row | Score | Raxol reality |
|---|---|---|
| /context (usage meter) | PARTIAL | Command exists (`app.ex:851`) but reports element counts, no tokens/percentage/cost (`app.ex:1457`). The data flows end-to-end already: `turn_completed` carries usage (`contract.ex:39`), the SSE decoder extracts it (`backend/http.ex:458`), `ContextCompactor.estimate_tokens/1` exists (`context_compactor.ex:70`). Meter UI absent. |
| /compact | PARTIAL | Exists and persists, but is a self-described "honest size reducer": keep last 6, one marker (`app.ex:1438`, `:1436`). Two stronger compactors ship unwired: `ContextCompactor` (token-budgeted) and journal `Compaction` (lossless, checkpoint-based). |
| /rewind | PARTIAL | No command, but the capability exists twice unreached: `Debug.TimeTravel` (`time_travel.ex:13`) is never enabled by the launcher (`raxol.code.ex:120`), and journal checkpoint restore (`records/checkpoint.ex:121`) requires a journal the TUI never attaches. Note: journal checkpoints restore conversation state, never workspace files (see hygiene row 2). |
| /export | PARTIAL | No command, but two machine-readable artifacts fall out of operation: the continuously-persisted session JSON (`store.ex:43`, `app.ex:701`) and `raxol.p`'s stderr JSONL trace (`raxol.p.ex:20`; runtime-verified). No human-readable export; the TUI never reveals the session file path. |
| /copy [N] | MISSING | No command, no message addressing (`app.ex:842`). `Raxol.System.Clipboard.copy/1` exists unused (`clipboard.ex:22`). |
| /find | MISSING | No transcript search of any kind (`app.ex:842`, `:1629`). |
| /transcript (into $PAGER) | MISSING | No pager integration in raxol_agent; the transcript exists only as in-TUI scrollback and raw session JSON (`app.ex:714`). |

### Model

| grok-build row | Score | Raxol reality |
|---|---|---|
| /model | HAVE | `/model <name>` overrides; bare `/model` fetches the provider's live model list and opens a picker (`app.ex:1348`, `:1385`); `--model` flag and per-repo pin (`project_config.ex:21`). Delta: the override is not persisted with the session (`store.ex:44`). |
| /effort (reasoning effort) | MISSING | No effort/thinking-budget/temperature parameter anywhere on the request side (`executor_config.ex:36`, `backend/http.ex:448` decodes thinking deltas inbound only). |
| Custom providers via config with base_url + env_key | PARTIAL | Per-repo `.raxol/config.json` (`project_config.ex:17`) and per-user `providers.json` (`credentials.ex:22`) pin provider/model/base_url, plus one generic `AI_API_KEY`/`AI_BASE_URL` slot (`resolver.ex:278`). But the provider must be one of 10 hardcoded registry atoms with fixed env keys (`resolver.ex:37`); you cannot declare provider N with its own env-var name, and two custom endpoints cannot coexist by env. |

### Approval modes

| grok-build row | Score | Raxol reality |
|---|---|---|
| Plan mode (only the plan file writable until approved) | PARTIAL | Real and enforced: Shift+Tab/Ctrl+P//plan toggle (`app.ex:382`, `:354`), engine denies every mutation (`app.ex:797`), planning directive appended (`app.ex:587`). The defining grok-build trait is absent: no plan file carve-out, no persisted plan artifact, no approve-the-plan transition; the plan exists only as chat text. |
| Auto mode (classifier auto-approves safe tools) | PARTIAL | Read-only tools always run unprompted (`app.ex:766`); `Harness.ToolClassifier` is a fail-closed name classifier (`tool_classifier.ex:26`). Not a selectable mode, and the risk classifier built for widening approvals (`BlastRadiusGate`) is a skeleton whose functions raise (`blast_radius_gate.ex:6`, `:68`). |
| Always-approve mode | PARTIAL | Three partial flavors: per-tool "always" via `s` (`app.ex:811`), `raxol.p --write` installs allow-all (`raxol.p.ex:264`), and the unwired SessionInbox documents `gate?: false` (`session_inbox.ex:69`). No TUI-selectable approve-everything mode. |
| Single-keystroke mode cycling (Shift+Tab) | PARTIAL | Shift+Tab exists (`app.ex:382`) but only toggles plan mode; there is no approval-mode set to cycle. |

### Concurrency

| grok-build row | Score | Raxol reality |
|---|---|---|
| /btw (side question mid-turn) | MISSING | Input is dropped while running (`app.ex:375`); the mid-turn seam (`Steer`) has no shipped runtime (`steer.ex:2`, `session_lane.ex:78`). |
| /queue | PARTIAL | `Harness.SessionInbox` queues mid-turn submits and dequeues at turn end (`session_inbox.ex:176`, `:235`) but no shipped surface starts it; the TUI silently drops keystrokes mid-turn (`app.ex:375`, `:385`). |
| /loop [interval] | PARTIAL | `Raxol.Agent.Scheduler` + `Schedule` (interval/cron/ISO) + the `cronjob` action all ship (`scheduler.ex:3`, `schedule.ex:9`, `actions/cronjob.ex:76`) but raxol.code neither includes the action nor provides `context[:scheduler]` (`app.ex:1715`); only the Console runtime wires it (`console/boot.ex:24`). |
| /tasks (background, subagents, scheduled) | PARTIAL | The `task` subagent tool is live in the TUI toolset (`app.ex:1718`, `actions/task.ex:28`) but synchronous and agent-invoked only (`actions/task.ex:11`); no user-facing task list; `Agent.Team` and Scheduler jobs unreachable from the TUI. |
| /dashboard | PARTIAL | The only agent dashboard is Symphony's orchestrator LiveView (`dashboard_live.ex:4`), a different product surface; the coding agent has only `/context` (`app.ex:1457`). |

### Extensibility

| grok-build row | Score | Raxol reality |
|---|---|---|
| /hooks | HAVE | Full lifecycle hooks: `.raxol/hooks.json` pre (veto on non-zero exit)/post/stop (`hooks.ex:8`, `:14`), executed on the `ToolCall.Hook` chokepoint (`tool_call/hook.ex:5`), wired at `app.ex:568`. Delta: `/hooks` displays counts only (`app.ex:862`); rules are edited only in the file; matchers are exact-name or `*`. |
| /plugins | PARTIAL | `raxol_plugin` is a TUI-app plugin SDK (`plugin.ex:3`), the wrong layer: raxol_agent references it nowhere and the coding agent loads no plugins. Agent extensibility routes through hooks + MCP instead. |
| /marketplace | MISSING | No extension marketplace anywhere (raxol_earn's ACP commerce is agents selling labor, unrelated). |
| /skills | PARTIAL | Skills wire into the toolset when `skills_provider` is configured (`app.ex:1719`, `skills.ex:42`, `skills/store.ex:5`) but are agent-facing only: no user `/skills` command, no browser, disabled by default. |
| /mcps | PARTIAL | `.mcp.json` (Claude Code format) is read and listed by `/mcp` (`app.ex:859`) but servers are never started; the loader calls bridging "a deliberate follow-up" (`mcp_config.ex:22`). The full bridge ships elsewhere: `MCP.Client` + `McpBundle` (namespaced `mcp__<server>__<tool>`, dispatched through authorizer + hooks, `mcp_bundle.ex:9`), consumed by the Console runtime (`console/boot.ex:135`). |
| Skills as first-class slash commands, namespaced | MISSING | The slash dispatcher is a closed set of ten clauses with a catch-all (`app.ex:865`). |

### Memory

| grok-build row | Score | Raxol reality |
|---|---|---|
| /memory | PARTIAL | A full pluggable memory subsystem exists (`memory.ex:14`, injection seam `stream.ex:677`, `MemoryPanel` widget) but raxol.code wires none of it: no `:memory` in run_context (`app.ex:542`), no memory actions in the toolset (`app.ex:1715`), no command. |
| /flush | PARTIAL | Context flushing covered by `/clear` + `/compact` (`app.ex:844`, `:1438`); nothing flushes a memory store because none is wired. |
| /dream (consolidation) | PARTIAL | Two consolidation loops exist (`self_improve.ex:13` via `turn.ex:94`; `curator.ex:18`) but `Turn.run` has no production callers and Curator starts only under a `:curator` config; unreachable from the TUI. Model-driven dedup is explicitly not implemented (`curator.ex:22`). |
| /remember | PARTIAL | `memory_remember` action exists (`actions/memory/remember.ex:5`) but enters no toolset without a configured provider; no slash command (`app.ex:865`). |

### Comfort

| grok-build row | Score | Raxol reality |
|---|---|---|
| /theme | PARTIAL | Framework theming exists (`theme.ex:183`, `:243`) but the TUI hardcodes `default_theme()` (`app.ex:1631`) and `priv/themes/` holds one nearly-empty JSON. |
| /compact-mode (density) | MISSING | No density/verbosity toggle; `--ascii` is a glyph fallback (`raxol.code.ex:69`). |
| /multiline | PARTIAL | The harness `Composer` implements Shift/Alt+Enter, backslash continuation, bracketed paste (`composer.ex:14`, `:27`) but is fixture-only; the TUI input is a single-line buffer where Enter always submits (`app.ex:378`, `:398`). |
| /vim-mode | MISSING | No vim editing anywhere in the input layer. |
| /timestamps | MISSING | Events carry `:ts` (used for durations, `block.ex:1067`) but nothing renders clock times. |
| /terminal-setup | MISSING | No keybinding configurator; the Composer design sidesteps the need (backslash continuation) but is unwired. `mix raxol.setup` is provider setup, a different concern. |
| /help | HAVE | In-TUI `/help` lists all ten commands (`app.ex:1475`); unknown commands point at it (`app.ex:866`). Delta: CLI-level `--help` errors (runtime-verified; no `:help` switch at `raxol.code.ex:76`). |
| /settings | PARTIAL | Config is layered but file-only (`project_config.ex:3`, `credentials.ex:37`, `store.ex:30`); no in-TUI viewer beyond the 5-field `/context`. |

### Meta

| grok-build row | Score | Raxol reality |
|---|---|---|
| /usage (credits/billing) | PARTIAL | Usage plumbing is end-to-end (provider usage frames parsed, `backend/http.ex:458`, `:531`; on `turn_completed`, `contract.ex:810`; headless runs already total cost, `trajectory.ex:52`) and the Block renderer can show `$X.XX` (`block.ex:1035`). The TUI displays none of it; `cost_usd` needs env-supplied rates (`benchmark_profile.ex:141`); no billing concept; payments Ledger is unrelated to LLM cost (`ledger.ex:94`). |
| /privacy | MISSING | No privacy surface. |
| /feedback | MISSING | No feedback/issue command. |
| /release-notes | MISSING | CHANGELOG.md exists as a file only. |
| /login | HAVE | First-class: wizard with connected-state marks, text forms, op:// persistence, session-only raw keys with offered 1Password save, async validation ping (`app.ex:843`, `:890`, `:921`, `:1250`); headless twin `mix raxol.setup`. Arguably stronger secret hygiene than grok-build's OAuth; no browser flow. |
| /logout | PARTIAL | Headless only: `mix raxol.setup --remove` (`raxol.setup.ex:26`, `credentials.ex:123`); no in-TUI command (`app.ex:865`). |
| /import-claude | PARTIAL | Compat by consumption: reads Claude Code's `.mcp.json` (`mcp_config.ex:3`) and can drive the `claude` CLI as a native harness (`harness/claude_code.ex:3`). Nothing imports CLAUDE.md/settings/keybindings. |

### Safety and repo hygiene

| grok-build row | Score | Raxol reality |
|---|---|---|
| Permissions + allow/deny + hooks + sandbox as one coherent model | PARTIAL | All four ingredients ship and the approval path is cross-linked (`CODING_AGENT.md:154`, `:201`; `AGENT_FRAMEWORK.md:219`; `TOOL_CATALOG.md:11`; `engine.ex:3`). But the picture spans four parallel mechanisms (`PermissionHook` modes in a moduledoc only, `permission_hook.ex:9`; `ToolPolicy` whose unification is "a follow-up", `tool_policy.ex:19`; `Authorization.Engine`; the `Sandbox` protocol documented only in docs/adr/0020) plus the separate REPL sandbox (`REPL.md:47`). No single safety-model page. |
| Workspace-level checkpoints, VCS-aware | MISSING | No file-tree snapshots and no git integration in the tool layer (`.git` appears only as a grep-pruned dir, `actions/code.ex:52`). The two things named checkpoint are different concepts: journal checkpoints restore the agent's conversation model (`records/checkpoint.ex:5`), and payments `require_checkpoint` is a spend gate. Hence PARTIAL for /rewind above but MISSING here. |
| Per-package check/test guidance with never-build-the-workspace advice | PARTIAL | Per-package commands are documented human-facing (`docs/testing/README.md:23`) and agent-facing (CLAUDE.md), but the guide recommends the opposite of scoping (full `mix raxol.check` before push, `docs/testing/README.md:39`) and the package list covers 14 of 17 packages. |
| In-tree guide + hosted docs + llms.txt | HAVE | Deep docs/ tree indexed from README (`README.md:110`); hexdocs (`README.md:131`, `mix.exs:438`); first-class llms.txt + llms-full.txt with a deterministic generator and routes at raxol.io (`web/priv/static/llms.txt:1`, `web/lib/mix/tasks/raxol.docs.llms.ex:13`, `router.ex:17`). Deltas: llms.txt is not at repo root and README never mentions it; no CI freshness gate. |
| SECURITY.md, CONTRIBUTING.md, THIRD-PARTY-NOTICES, SOURCE_REV, generated markers | PARTIAL | CONTRIBUTING.md yes (`.github/CONTRIBUTING.md:1`, shipped to hexdocs via `mix.exs:447`). Generated markers yes for goldens (`golden.ex:469`) and TOOL_CATALOG (`TOOL_CATALOG.md:4`), missing on `priv/rate/golden.refs` and llms.txt. Third-party notices package-level only (`raxol_agent_client_protocol/NOTICE.md:1`, vendored termbox2 LICENSE); no repo-level aggregation. SECURITY.md missing everywhere (only a scanning workflow, `security.yml:66`). SOURCE_REV missing. |

## Discrepancies: docs that overstate the code

Phantom modules (docs describe architecture that does not exist):

1. `docs/harness/architecture.md:165-179` names `Raxol.Harness.Live`, `SessionPump`,
   `DeliveryShim`, `HarnessApp`, and `Directive.Lane`; none exist. The shipped driver
   is `Raxol.Harness.LiveSessionDriver` (`live_session_driver.ex:1`). The code itself
   admits the gap (`viewport_authority.ex:13`).
2. `docs/harness/interaction.md:21-69` names `CommandRegistry`, `CommandAutocomplete`,
   `ChoicePrompt`, `Indication`, `TranscriptView`; none exist. Slash dispatch is plain
   function clauses (`app.ex:842`). The same doc's "^C is always a double-press" is
   false for raxol.code, which quits on one Ctrl+C (`app.ex:349`).
3. `editors/nvim` and `editors/vscode` ship pointing at `mix raxol.lsp`
   (`editors/nvim/README.md:77`, `editors/vscode/src/extension.ts:89`); no such task
   or server exists anywhere.

Stale flags and defaults:

4. `docs/features/CODING_AGENT.md:87` documents the deprecated `--harness` flag,
   never mentions the canonical `--backend` or `.raxol/config.json`, and describes the
   old bare-`/model` behavior (now a live picker, `app.ex:1348`). This matches the
   runtime-verified `mix raxol.check` docs WARN.
5. `ROADMAP.md:113` claims Mock is the default backend; `raxol.p` hard-defaults to
   lm_studio (`raxol.p.ex:33`) and dies econnrefused with no provider
   (runtime-verified). `Backend.Resolver`'s moduledoc claims every surface resolves
   through it (`resolver.ex:24`); raxol.p bypasses it entirely.
6. `Backend.Cli`'s moduledoc says it exists so raxol.code and raxol.p "cannot drift"
   (`backend/cli.ex:3`); only raxol.p uses it, and the two have drifted (different
   no-provider behavior).

Unshipped claims:

7. `packages/raxol_cli/README.md:4` and `docs/PACKAGES.md:32` present `npm i -g raxol`
   as an install path; the package has never been published (npm E404, no release tag)
   and `ROADMAP.md:52` still lists the install funnel as not-done P0.
8. The npm/raxol_cli description ("interactive AI agent in your terminal") oversells:
   the binary's `agent` is a line-based chat loop with no tools, approvals, sessions,
   or the Code.App TUI (`cli.ex:29`).
9. `mcp_config.ex:22` claims tool bridging is blocked on a missing dynamic-dispatch
   seam; `Action.Dynamic` + `McpBundle` exist and ship on the Console runtime
   (`mcp_bundle.ex:9`, `console/boot.ex:135`). The blocker statement is stale.
10. `session_inbox.ex:43` and `tool_executor.ex:69` document a `--yolo` flag no
    shipped CLI accepts; nothing outside tests starts a SessionInbox.
11. `README.md:43` says "every tool call gated by an ALLOW/ASK/DENY engine"; only
    sensitive tools reach the engine (`app.ex:766`). `README.md:45` states it
    correctly.

Stale statuses (code ahead of docs):

12. docs/adr/0025 (scheduler) and docs/adr/0030 (ACP delivery ordering) say
    proposed/unlanded; `scheduler.ex:1` and `delivery.ex:5` ship.
13. docs/adr/0027 is marked implemented with a Session-based, fan-out `delegate_task`;
    the shipped action is `task`, single-prompt, synchronous, nested `Stream.react`,
    no list input (`actions/task.ex:11`, `:38`, `:69`).
14. `records/checkpoint.ex:16` says checkpoints return `:not_implemented` "until U9
    lands"; the default FileBackend is landed in the same file (`:156-198`).
15. `packages/raxol_gateway/README.md:45` says email is outbound-only; inbound
    normalize_event + Inbox + ThreadStore are implemented (`adapter/email.ex:9`).

Contributor-facing staleness:

16. `.github/CONTRIBUTING.md:17` requires PostgreSQL 15+; the test suite runs on
    MockDB with the database disabled (`config/test.exs:13`, `:129`). Its Elixir
    1.17.3 pin (`:14`) is narrower than mix.exs's `~> 1.17 or ... ~> 1.20`.
17. `docs/testing/README.md:25` covers 14 of 17 packages (omits
    raxol_agent_client_protocol, raxol_cli, raxol_console).
18. Contract events are stamped `tier: "durable"` on raxol.code/raxol.p paths where no
    journal sink is attached (`contract.ex:46`; the TUI persists via Store JSON,
    `app.ex:701`). Misleading to event-stream consumers, not to end users.
