# Harness DX backlog

Derived from [HARNESS_DX_GAP.md](HARNESS_DX_GAP.md) (2026-08-07, commit `fce2465bb`).
Each item leads with its changelog entry: the user-visible outcome, written as it would
ship. Effort is S/M/L with the modules actually touched. Blast radius names which of
the six surfaces (terminal, LiveView, MCP, SSH, Telegram, JSON API) change. Items are
sorted by impact over (effort times blast radius). The sprint line reflects that Raxol
is in maintenance mode while Xochi is the revenue focus: everything above the line is
S-effort, low blast radius, and either self-documenting or documentation itself.

## Above the line: this sprint

### 1. `--help` works on every coding-agent entry point (parity)

Changelog: "`mix raxol.code --help`, `mix raxol.p --help`, and `bin/raxol-code --help`
print usage and exit 0; unknown flags print usage plus the error."

The first command every new CLI user types is currently a guaranteed exit-64 error
(runtime-verified). Effort S: add `:help` to `@switches` and a usage printer in
`packages/raxol_agent/lib/mix/tasks/raxol.code.ex` and `raxol.p.ex` (the text already
exists as the moduledocs); `bin/raxol` already handles `-h` and is the template.
Blast radius: terminal + headless. No API change.

### 2. The headless twin fails like the TUI, helpfully (parity)

Changelog: "`mix raxol.p` resolves providers exactly like `mix raxol.code` (op://
references, provider env vars, `AI_API_KEY`); with nothing configured it exits with
'no provider configured; run mix raxol.setup or pass --backend', instead of
econnrefused against localhost:1234."

Fixes the runtime-verified worst first-touch failure and the documented-but-false
claim that all surfaces resolve through `Backend.Resolver` (`resolver.ex:24`). Effort
S: route `raxol.p.ex` through `Backend.Resolver` (drop the lm_studio hard default in
`backend/cli.ex:18`), emit a structured error event plus a human hint. While here,
make raxol.code use `Backend.Cli` so the shared-flag module's no-drift claim becomes
true. Blast radius: headless only (CI scripts that relied on the implicit lm_studio
default must pass `--backend lm_studio`; call it out in the changelog).

### 3. `mix raxol.inspect`: one command that shows everything the agent will use (parity)

Changelog: "`mix raxol.inspect` prints, for the current directory: the resolved
provider and why (flag, repo pin, op:// reference, env var), the `.raxol/config.json`
pin, hooks from `.raxol/hooks.json` (the actual matchers and commands), MCP servers
from `.mcp.json`, skills roots and counts, and the session store location and count."

The single highest-leverage parity item (grok-build's `inspect`), and the cheapest:
every data source already has a reader. Effort S-M: new task in
`packages/raxol_agent/lib/mix/tasks/raxol.inspect.ex` composing
`Backend.Resolver.diagnostics/0`, `Setup.status/0`, `Code.ProjectConfig.load/1`,
`Code.Hooks.load/1`, `Code.McpConfig.load/1`, `Skills.Store` paths, and
`Code.Store.default_dir/0` + `list/1`. Also surface it as `/inspect` in the TUI
(one more `apply_command` clause rendering the same data). Blast radius: none of the
six surfaces change shape; a new read-only task plus one slash command.

### 4. Token and cost visibility: `/usage`, and tokens in `/context` (parity)

Changelog: "`/usage` shows per-session token totals and estimated cost; `/context`
includes tokens. Headless runs already reported cost totals; the TUI now matches."

The plumbing is complete end-to-end (usage on every `turn_completed`, `contract.ex:810`;
`BenchmarkProfile.cost_usd`, `trajectory.ex:52`); only the fold and display are
missing (`app.ex:1457`). Effort S: fold usage out of `model.events`, render in a
`/usage` notice; show dollars only when rates are known (env rates today; a static
provider table is a follow-up, kept out of this item to stay honest about pricing
drift). Blast radius: terminal.

### 5. Docs truth pass (parity; docs are the product)

Changelog: "Coding-agent docs match the code: `--backend` is documented (with
`--harness` marked deprecated), `.raxol/config.json` and the `/model` picker are
documented, harness architecture/interaction docs mark staged modules as staged,
CODING_AGENT.md and the empty TUI gain literal starter prompts, README's agent section
leads with a command that actually runs from a fresh clone, CONTRIBUTING.md drops the
false PostgreSQL prerequisite, and SECURITY.md exists."

Every entry in the gap report's Discrepancies section is either fixed or explicitly
marked as staged design. This is the whole fix for the "documentation drift detected"
warning class and costs no code. Effort S (docs only, ~10 files). Blast radius: none.
The phantom-module sections of `docs/harness/architecture.md` and `interaction.md`
get a "staged, not shipped" banner rather than deletion, preserving the design record
while un-breaking reader trust.

### 6. The harness as MCP tools (overtake)

Changelog: "Agent sessions are drivable over MCP: `harness_start_session`,
`harness_send_prompt`, `harness_read_transcript`, and `harness_list_sessions` are
registered alongside the existing raxol_* tools, so any MCP client (including Claude
Code) can start, drive, and read Raxol agent sessions."

The cheapest overtake with every piece already shipped: `Registry.register_tools/2`
takes plain maps (`registry.ex:74`), `Headless.McpTools` is the template
(`mcp_tools.ex:14`), `Session.Supervisor.start_session/2`, `SessionStreamer.subscribe/2`,
and writerless `Reattach.attach/3` are the tool bodies. Effort S: one module in
raxol_agent (the dependency direction already runs raxol_agent -> raxol_mcp), plus a
tool-policy preset for unattended approval (reuse `ToolPolicy.allow_all/0` behind an
explicit opt-in, as `raxol.p --write` does). Blast radius: MCP surface only.

## Below the line: scheduled, in order

### 7. Publish the binary, and put the TUI in it (parity, human-gated)

Changelog: "`npm i -g raxol` works, and `raxol code` opens the full coding-agent TUI."

The Burrito pipeline, npm wrapper, and release workflow all exist; nothing has been
tagged or published (npm E404). The code half is S: a `raxol code` subcommand in
`Raxol.CLI.main` (`cli.ex:15`) replicating raxol.code's app_opts (the launch is
Mix-free: `Raxol.start_link(Code.App, opts)`). The rest is release engineering (CI
matrix builds for the two Linux targets, npm vendoring, NPM_TOKEN) and a publish
decision that is yours, not the sprint's. Blast radius: terminal + distribution.

### 8. Bridge `.mcp.json` servers into the live toolset (parity). Effort M.
`McpBundle` + `Action.Dynamic` ship on the Console runtime (`mcp_bundle.ex:9`,
`console/boot.ex:135`); wire them into Code.App's toolset behind the existing
authorizer and hooks, upgrade `/mcp` to show connection state. Terminal + MCP.

### 9. In-TUI `/resume` with a session picker (parity). Effort S-M.
`/sessions` becomes selectable using the `/model` picker precedent (`app.ex:1367`);
enrich the listing with age and cwd from the Store. Terminal.

### 10. `/fork` as a copy-fork (parity now, overtake later). Effort S.
Store.load, save under a new id, note the parent in the session file. The
journal-native fork (replay to offset, non-main `branch_id`) waits for item 11.
Terminal.

### 11. Journal-backed TUI sessions plus `--replay` (overtake). Effort M.
Point Code.App persistence at EmitBridge/FileStore so TUI sessions land in the
offset-addressed journal, then `mix raxol.code --replay <session> [--to-offset N]`
folding the journal through `Harness.Projection`. This makes `tier: durable` true,
unlocks real `/rewind` (checkpoint restore) and journal-native `/fork`, and collapses
the three disconnected replay systems to one. Terminal + headless.

### 12. Serve the coding agent over SSH, single-tenant (overtake; gated on open question 1). Effort S-M.
`Raxol.SSH.Server.serve(Code.App, authorized_keys_dir: ...)` works with no framework
changes (fail-closed auth, per-connection Lifecycle; the playground already runs this
in production over fly.io). Single-tenant "my box, my key" is the S version;
multi-tenant hosting (per-user cwd jails, session dirs, spend caps) is real work and
a hosting commitment. SSH surface.

### 13. `/share`: a read-only LiveView transcript URL (overtake; needs the web app). Effort M.
An attach-mode LiveView that Reattach-replays history and follows
`SessionStreamer.subscribe/2` live, rendered as transcript blocks, behind a signed
URL. Multiplayer (shared input, approval arbitration) is L and not scheduled.
LiveView surface.

### 14. Type-ahead: queue a prompt while a turn runs (parity). Effort M.
Either wire `Harness.SessionInbox` under the TUI or buffer submits in Code.App state
and dispatch at turn end. Terminal.

### 15. Scheduler reach: `cronjob` in the TUI toolset plus `/tasks` (parity). Effort S-M.
Provide `context[:scheduler]` and the Cronjob action in raxol.code (the Console
runtime is the wiring precedent, `console/boot.ex:24`), and a `/tasks` command listing
scheduler jobs and the running turn. Terminal.

### 16. Session niceties: `/export`, `/transcript`, `/copy`, `/rename`, `/logout`, `/find` (parity). Effort S each.
Print the session file path and a markdown export; dump transcript to `$PAGER`; copy
the last answer via the existing `Raxol.System.Clipboard`; a title field in the Store;
`/logout` calling `Setup.remove/1`; substring search over transcript blocks. Batch
these when touching Code.App anyway; individually none justifies a solo PR in
maintenance mode. Terminal.

### 17. `/effort` and request-side model parameters (parity). Effort M.
ExecutorConfig gains optional reasoning/thinking-budget params mapped per provider in
`Backend.HTTP` request builders. Worth doing when a supported provider's default is
wrong for coding; until then the value is low. Terminal + headless.

### 18. Custom provider registry entries (parity). Effort S-M.
Let `providers.json`/`.raxol/config.json` declare a provider with its own `base_url`
and `env_key` instead of the single generic `AI_API_KEY` slot (`resolver.ex:37`).
All surfaces via the Resolver.

### 19. Plan artifacts: a written plan the user approves (parity). Effort M.
Plan mode today is read-only chat. A plan-file carve-out (the one writable path in
plan mode) plus an approve-to-execute transition closes the actual grok-build row.
Terminal.

### 20. LLM cost into the spending ledger (overtake; scope depends on open question 4). Effort M.
Feed per-turn cost into `Payments.Ledger`/`SpendingPolicy` so LLM spend and payment
spend share one budget. True per-call x402 settlement of LLM calls is L, has no
existing foundation, and is not scheduled.

### 21. Not scheduled, tracked for honesty: hot-reload `/reload` (M, dev-grade; journal
resume already covers restart continuity), resume-on-another-node (M-L; the journal
dir is rsync-able by design and the `:global` writer lock already prevents
double-writes, but there is no cluster session index), cluster-wide `/sessions` and
`/tasks` (L; the swarm modules are node plumbing, none of it touches agent sessions),
auto-approve via `BlastRadiusGate` (L; the module is a skeleton that raises), and TUI
scrollback/mouse/multiline via the harness `Surface` (L; the substrate is fixture-only
and this is the one genuinely large TUI rebuild).

## Rejected, in writing

- `/vim-mode`, `/timestamps`, `/compact-mode`: comfort toggles that exist in
  grok-build partly to compensate for its input model. Niche value, permanent
  maintenance surface. Revisit only on user demand.
- `/terminal-setup`: the harness Composer's backslash continuation was designed so
  terminal reconfiguration is unnecessary (`composer.ex:27`). The fix is wiring the
  Composer (item 21's TUI rebuild), never a setup wizard for escape codes.
- `/marketplace`: skills are directories of SKILL.md; git is the distribution
  mechanism. A marketplace is a service commitment Raxol should not take on in
  maintenance mode.
- `/privacy`, `/feedback`, `/release-notes` as TUI commands: repo artifacts
  (SECURITY.md, CHANGELOG.md, the issue tracker) serve these. In-TUI viewers are
  chrome with a docs-freshness liability.
- `/btw` in grok-build's shape: a side-question channel requires the mid-turn steer
  runtime (`session_lane.ex:78` documents that no shipped runtime owns a live turn's
  TurnState). The Raxol-shaped answer is type-ahead queueing (item 14) now and Steer
  when the harness session runtime ships; a lookalike built on neither would be fake.
- `/import-claude`: compat by consumption already exists (`.mcp.json` is read
  natively; the `claude` CLI can be driven as a native harness). Chasing a
  competitor's config format is a moving target with no payoff for existing users.
- `/dream` as a user command: consolidation is the SelfImprove/Curator loop's job,
  config-driven by design (ADR-0021/0022). A manual trigger adds a second entry point
  to a loop the coding surface does not even wire yet; revisit if/when memory lands
  in raxol.code at all.

## Decisions (2026-08-07)

The five open questions were answered; the plan of record is SPECS.md "Harness DX"
(phases DX1-DX4) and the TODO.md "Harness DX" checklist.

1. SSH-as-onboarding: NECESSARY, hosted multi-tenant is the target. Item 12 ships as
   the single-tenant flag in DX2; multi-tenant hosting (per-user jails, per-user
   session stores, spend caps) is committed as DX4, building on decision 4.
2. Package boundary: recommendation adopted, the harness stays in `raxol_agent` this
   quarter. Revisit a `raxol_code` split only after journal unification (item 11,
   DX3) and the `raxol code` subcommand (item 7, DX2) ship, because those two
   determine the real seam; a split now churns Hex, CI, and both Burrito packagings
   for zero user-visible gain.
3. ACP embedding: IN SCOPE. A new item joins DX2: `mix raxol.acp`, a stdio launcher
   wiring the existing `TurnRunner` over `Transport.Stdio` `:self` mode. Dep risk:
   raxol_agent_client_protocol is unpublished, so the task guards via
   `Code.ensure_loaded?` with a helpful error, or the ACP package publishes a Hex
   pre-release first.
4. Payments surface: PUBLIC. Item 20 (LLM cost into Ledger/SpendingPolicy) is in
   scope as a headline feature (DX3); per-call x402 settlement of LLM calls stays
   unscheduled.
5. Publishing: WAIT. Item 7's publish half is gated on the `raxol code` subcommand
   shipping the real TUI, so the first published impression is the harness, not the
   line-chat loop.

Revised order after decisions: DX1 is the sprint slice above the line, unchanged.
DX2 = item 7 (code half, then publish), the new ACP launcher, item 12 single-tenant,
item 8. DX3 = items 11, 9, 10, 16 batched, 20. DX4 = multi-tenant SSH hosting and
item 13. The rejections stand.
