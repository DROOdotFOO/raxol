# Harness DX backlog

> **Closed out.** The epic shipped in PR #819 (merged, commit `4b1f20b7e`). Both
> sprint lines are done: items 1-6 above the line and items 7-13, 16, and 20
> below it. Items 14, 15, 17, 18, 19, and 21 are still open and stay listed
> here. Item 7 shipped its code half and the release binaries; the npm publish
> is still a deliberate manual act. Each item carries its status, verified
> against the tree at `4b1f20b7e`. The rejections stand, unchanged.

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

**Shipped.** `Raxol.Agent.Code.Launcher` and `Raxol.Agent.P` each carry a
`:help` switch, an `-h` alias, and a `@usage` block; a bad flag prints the same
usage to stderr and exits 64. `mix raxol.inspect` and
`Raxol.Agent.ClientProtocol.Serve` follow the same shape, so all four entry
points answer `--help` identically whether reached through `mix`, `bin/`, or the
packaged binary.

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

**Shipped.** `Backend.Cli.resolve_executor/2` is the one provider path, used by
`Code.Launcher`, `Agent.P`, and `ClientProtocol.Serve`; the lm_studio default is
gone and a no-provider run exits 1 with the message naming `mix raxol.setup`, the
provider env vars, and `--backend`. `Backend.Cli` passes `prog: nil` on the
headless path so a deprecation notice cannot corrupt the JSONL event stream.

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

**Shipped.** `Raxol.Agent.Code.Inspection.gather/1` collects the snapshot and
`render/1` formats it; `mix raxol.inspect` prints it (`--json` for machines) and
`/inspect` shows the same data in the TUI. `.mcp.json` servers list env variable
NAMES only, never values. The directory inspected is the agent workspace
(`Actions.Fs.working_dir/0`), the same resolution the agent itself uses, so the
snapshot describes the session you are about to start.

### 4. Token and cost visibility: `/usage`, and tokens in `/context` (parity)

Changelog: "`/usage` shows per-session token totals and estimated cost; `/context`
includes tokens. Headless runs already reported cost totals; the TUI now matches."

The plumbing is complete end-to-end (usage on every `turn_completed`, `contract.ex:810`;
`BenchmarkProfile.cost_usd`, `trajectory.ex:52`); only the fold and display are
missing (`app.ex:1457`). Effort S: fold usage out of `model.events`, render in a
`/usage` notice; show dollars only when rates are known (env rates today; a static
provider table is a follow-up, kept out of this item to stay honest about pricing
drift). Blast radius: terminal.

**Shipped, and the provider table came with it.** `/context` folds token totals
out of `turn_completed`; `/usage` adds turns and an estimated cost. Prices come
from `Raxol.Agent.LlmPrices` or from `RAXOL_COST_PER_MTOK_IN/OUT`, and the fold
prices against the model the provider says it BILLED rather than the one
configured, so a provider that silently substitutes a model cannot be billed at
the wrong rate. An unknown model prints "cost: unknown model" instead of $0.00.

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

**Shipped, with two residuals.** The banners went up during the epic and came
back down in the follow-up pass: with the shipped modules described directly,
`architecture.md` and `interaction.md` no longer name a module that does not
exist, so there is nothing left to mark staged. `CODING_AGENT.md` documents
`--backend`, `.raxol/config.json`, the `/model` picker, and three starter
prompts; CONTRIBUTING.md dropped the PostgreSQL prerequisite and widened the
Elixir pin; SECURITY.md exists; `docs/testing` covers all 17 packages; the dead
`mix raxol.lsp` wiring is gone from both editor plugins. Still open: the TUI
shows no first-run prompt suggestions, and `session_inbox.ex` and
`tool_executor.ex` still document a `--yolo` flag no CLI accepts.

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

**Shipped.** `Raxol.Agent.Harness.McpTools` registers `harness_start_session`,
`harness_send_prompt`, `harness_read_transcript`, and `harness_list_sessions`;
`Raxol.Application` registers them with `Raxol.MCP.Registry` at startup behind a
`Code.ensure_loaded?` guard, since main raxol does not depend on raxol_agent. The
tools share `Code.Store` with the TUI, so an MCP client and a terminal session
read the same sessions, which is why `Store.save/4` grew the `:expect_rev`
optimistic-concurrency option: a blind write from one surface would otherwise
discard the other's turn.

## Below the line: scheduled, in order

### 7. Publish the binary, and put the TUI in it (parity, human-gated)

Changelog: "`npm i -g raxol` works, and `raxol code` opens the full coding-agent TUI."

The Burrito pipeline, npm wrapper, and release workflow all exist; nothing has been
tagged or published (npm E404). The code half is S: a `raxol code` subcommand in
`Raxol.CLI.main` (`cli.ex:15`) replicating raxol.code's app_opts (the launch is
Mix-free: `Raxol.start_link(Code.App, opts)`). The rest is release engineering (CI
matrix builds for the two Linux targets, npm vendoring, NPM_TOKEN) and a publish
decision that is yours, not the sprint's. Blast radius: terminal + distribution.

**Code half shipped; the publish is still open.** `raxol code` runs
`Code.Launcher.main/2`, the same path as `mix raxol.code`, and `raxol p` and
`raxol acp` came with it. The `raxol-cli-v0.1.0` tag attaches per-arch binaries
to a GitHub Release, but that tag points at `f7aa14a6d`, the commit before #819,
so the published assets predate `code` and `acp`; the first release that carries
them needs a new tag. npm publish is deliberately not wired to the tag either: it
needs a manual `gh workflow run release-raxol-cli.yml -f publish=true` with
`NPM_TOKEN` set, and the step fails loudly rather than silently when the token is
missing. `npm i -g raxol` does not work until someone runs it.

### 8. Bridge `.mcp.json` servers into the live toolset (parity). Effort M.
`McpBundle` + `Action.Dynamic` ship on the Console runtime (`mcp_bundle.ex:9`,
`console/boot.ex:135`); wire them into Code.App's toolset behind the existing
authorizer and hooks, upgrade `/mcp` to show connection state. Terminal + MCP.

**Shipped** as `Raxol.Agent.Code.McpLoader`. Ownership is tied to the session
rather than to a cleanup call: `load/2` spawns a janitor that starts each client
linked to itself and monitors the session, so Ctrl+C, an SSH disconnect, or a
crash all take the clients and their OS subprocesses with them. `/mcp` marks each
server connected, failed, or idle. Servers are capped at 16 with a conservative
name charset (each accepted name interns an atom), and a jailed session refuses
to read the file at all.

### 9. In-TUI `/resume` with a session picker (parity). Effort S-M.
`/sessions` becomes selectable using the `/model` picker precedent (`app.ex:1367`);
enrich the listing with age and cwd from the Store. Terminal.

**Shipped.** `/resume` with an id switches in place; bare `/resume` opens the
picker. Listings carry title, message count, age, and cwd. The id is validated as
a session id before use, because it reaches `Path.join` as a filename in
`/transcript` and names the journal directory: an unvalidated id would let one
tenant write into another's workspace.

### 10. `/fork` as a copy-fork (parity now, overtake later). Effort S.
Store.load, save under a new id, note the parent in the session file. The
journal-native fork (replay to offset, non-main `branch_id`) waits for item 11.
Terminal.

**Shipped** as the copy-fork. `/fork [title]` saves under a new id with `parent`
recorded and continues there. Journal-native branching is still unminted: no code
path produces a non-main `branch_id`.

### 11. Journal-backed TUI sessions plus `--replay` (overtake). Effort M.
Point Code.App persistence at EmitBridge/FileStore so TUI sessions land in the
offset-addressed journal, then `mix raxol.code --replay <session> [--to-offset N]`
folding the journal through `Harness.Projection`. This makes `tier: durable` true,
unlocks real `/rewind` (checkpoint restore) and journal-native `/fork`, and collapses
the three disconnected replay systems to one. Terminal + headless.

**Shipped, partly.** `Code.App` opens a `Journal.FileStore` lazily on the first
durable event (an idle session spawns no Writer) and appends every durable event
to it, so `tier: :durable` is true on this path. `mix raxol.code --replay <id>
[--to-offset N]` prints the transcript through `Raxol.Agent.Code.Replay` and
exits without opening the TUI, falling back to the saved session file when no
journal exists. `/rewind` shipped as last-turn removal with a journal marker,
which is what the TUI needs; checkpoint-based restore and journal-native `/fork`
did not ship. `raxol.p` still has no journal sink.

The journal itself was hardened for this: a read never heals a torn tail. Only
the owning `Writer` truncates a damaged segment (`Reader.resume_scan/1`), because
a read-side heal on a LIVE segment truncates records the writer is still
appending and permanently damages the session.

### 12. Serve the coding agent over SSH, single-tenant (overtake; gated on open question 1). Effort S-M.
`Raxol.SSH.Server.serve(Code.App, authorized_keys_dir: ...)` works with no framework
changes (fail-closed auth, per-connection Lifecycle; the playground already runs this
in production over fly.io). Single-tenant "my box, my key" is the S version;
multi-tenant hosting (per-user cwd jails, session dirs, spend caps) is real work and
a hosting commitment. SSH surface.

**Shipped, both tenancies.** `--ssh --authorized-keys DIR` is the single-tenant
form; `--ssh-tenants DIR` is multi-tenant, with `Raxol.Agent.Code.Tenant` deriving
per-user options from `DIR/<user>/`: `ssh/authorized_keys`, a `work/` cwd jail, a
`code_sessions/` store, a `sessions/` journal base, and the spending identity
`"ssh:<user>"`. `Tenant.app_opts/2` re-applies the same username normalization
the key lookup used, so the identity that authenticated and the workspace that
opens cannot diverge. The jail confines the fs tools, which resolve every path
through `Actions.Fs.resolve/2`. A `/bin/sh -c` command line can `cd` or name an
absolute path, so `jail: true` disables the shell tool outright, and a jailed
session declines to load workspace-configured commands (`.raxol/hooks.json`,
`.mcp.json`).

The boundary is one BEAM under one uid, stated as such in SECURITY.md.
`Raxol.Application` serves this behind `RAXOL_SSH_CODE` and refuses to boot
without both `RAXOL_SSH_CODE_TENANTS` and a positive
`RAXOL_SSH_CODE_BUDGET_USD`, since a hosted tenant spends the host's provider
credential. The fly.toml block is present and commented out: nothing is hosted
until someone flips it on with a tenants volume.

This also forced a framework fix: per-session Lifecycle environments (`:ssh`,
`:telegram`, `:agent`, `:liveview`, `:gateway`) own no plugin manager, because
the PluginManager is a VM singleton and one disconnect was killing every
concurrent session. `Raxol.SSH.Session.lifecycle_opts/4` is the opts merge seam.

### 13. `/share`: a read-only LiveView transcript URL (overtake; needs the web app). Effort M.
An attach-mode LiveView that Reattach-replays history and follows
`SessionStreamer.subscribe/2` live, rendered as transcript blocks, behind a signed
URL. Multiplayer (shared input, approval arbitration) is L and not scheduled.
LiveView surface.

**Shipped.** `Raxol.Agent.Code.ShareToken` signs a scoped, expiring HMAC token
over the session id and `ShareLive` serves the read-only transcript. `/share`
refuses to mint a token for a session id that could never verify, and says so,
instead of printing a dead link. The host must set `RAXOL_SHARE_SECRET` (32 bytes
or more) and mount the LiveView. Multiplayer remains unscheduled.

`SessionStreamer` was corrected along the way: its history is a live replay
buffer for a session's subscribers, dropped when the last one releases,
unsubscribes, or dies. It had been keeping a turn's prompts, assistant text, and
tool results resident on a node-global singleton past `/clear`, disconnect, and
session end. The journal is the durable log.

### 14. Type-ahead: queue a prompt while a turn runs (parity). Effort M.
Either wire `Harness.SessionInbox` under the TUI or buffer submits in Code.App state
and dispatch at turn end. Terminal.

**Open.** Keystrokes are still dropped while a turn runs (`app.ex:610`, `:620`),
and nothing outside tests starts a `SessionInbox`.

### 15. Scheduler reach: `cronjob` in the TUI toolset plus `/tasks` (parity). Effort S-M.
Provide `context[:scheduler]` and the Cronjob action in raxol.code (the Console
runtime is the wiring precedent, `console/boot.ex:24`), and a `/tasks` command listing
scheduler jobs and the running turn. Terminal.

**Open.** The default toolset is still Fs + Code + Task + enabled skills
(`app.ex:3151`); there is no `context[:scheduler]` and no `/tasks` command.

### 16. Session niceties: `/export`, `/transcript`, `/copy`, `/rename`, `/logout`, `/find` (parity). Effort S each.
Print the session file path and a markdown export; dump transcript to `$PAGER`; copy
the last answer via the existing `Raxol.System.Clipboard`; a title field in the Store;
`/logout` calling `Setup.remove/1`; substring search over transcript blocks. Batch
these when touching Code.App anyway; individually none justifies a solo PR in
maintenance mode. Terminal.

**Shipped, all six.** `/export [path]` and `/transcript` both containment-check
their destination against the session's workspace and refuse a path that escapes
it; `/transcript` writes a private temp file and prints the `${PAGER:-less}` line
to run rather than spawning a pager, because the TUI owns the tty, and a jailed
session writes into its own workspace where the tenant can reach it. `/copy` is
refused in a jailed session.

### 17. `/effort` and request-side model parameters (parity). Effort M.
ExecutorConfig gains optional reasoning/thinking-budget params mapped per provider in
`Backend.HTTP` request builders. Worth doing when a supported provider's default is
wrong for coding; until then the value is low. Terminal + headless.

**Open.** No reasoning-effort, thinking-budget, or temperature parameter on the
request side.

### 18. Custom provider registry entries (parity). Effort S-M.
Let `providers.json`/`.raxol/config.json` declare a provider with its own `base_url`
and `env_key` instead of the single generic `AI_API_KEY` slot (`resolver.ex:37`).
All surfaces via the Resolver.

**Open.** The Resolver registry is still a fixed list of provider specs with
fixed `env_keys` (`resolver.ex:37`), plus the one generic `AI_API_KEY` slot.

### 19. Plan artifacts: a written plan the user approves (parity). Effort M.
Plan mode today is read-only chat. A plan-file carve-out (the one writable path in
plan mode) plus an approve-to-execute transition closes the actual grok-build row.
Terminal.

**Open.** Plan mode is still a directive that forbids the mutating tools
(`app.ex:884`); there is no writable plan path, no persisted plan artifact, and
no approve-the-plan transition.

### 20. LLM cost into the spending ledger (overtake; scope depends on open question 4). Effort M.
Feed per-turn cost into `Payments.Ledger`/`SpendingPolicy` so LLM spend and payment
spend share one budget. True per-call x402 settlement of LLM calls is L, has no
existing foundation, and is not scheduled.

**Shipped** as `Raxol.Agent.Code.CostLedger`, guarded on `Payments.Ledger` being
loadable in the host (the dependency runs the other way, so every call degrades
to a no-op without raxol_payments). The host passes `:ledger`,
`:spending_policy`, and optionally `:agent_id`, which defaults to `"raxol-code"`
so `/clear` cannot mint its way out of a budget. An exhausted budget halts the
turn already in flight, sub-agent turns are metered like top-level ones, and a
model with no known price fails closed when a ledger and policy are wired.
Per-call x402 settlement stays unscheduled.

### 21. Not scheduled, tracked for honesty: hot-reload `/reload` (M, dev-grade; journal
resume already covers restart continuity), resume-on-another-node (M-L; the journal
dir is rsync-able by design and the `:global` writer lock already prevents
double-writes, but there is no cluster session index), cluster-wide `/sessions` and
`/tasks` (L; the swarm modules are node plumbing, none of it touches agent sessions),
auto-approve via `BlastRadiusGate` (L; the module is a skeleton that raises), and TUI
scrollback/mouse/multiline via the harness `Surface` (L; the substrate is fixture-only
and this is the one genuinely large TUI rebuild).

**All five still open, unchanged.** The `BlastRadiusGate` line above is stale on
one point: the gate is implemented (`new/0`, `escalate?/1`, `evaluate/2`,
`authorize/3`, `apply_decision/3`, `rebuild/1`), its red suite has graduated, and
only its own moduledoc still calls it a skeleton. What is open is the wiring: no
non-test module calls it, so auto-approve is unreachable from the coding TUI.
`Harness.Surface` still has no consumer outside `LiveSessionDriver`, which itself
has none outside its test, so the TUI transcript is still an unscrollable column
with a hardcoded theme, a single-line input, and mouse events normalized away.

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

## How the decisions landed

1. SSH: both tenancies shipped in one pass rather than single-tenant first.
   `--ssh --authorized-keys` and `--ssh-tenants` are the two forms, and
   `RAXOL_SSH_CODE` is the hosted wiring, still switched off in fly.toml.
2. Package boundary: the harness is still in `raxol_agent`. Item 11 and item 7's
   code half both shipped, so the seam a `raxol_code` split would follow is now
   visible; no split was made.
3. ACP: shipped as `Raxol.Agent.ClientProtocol.Serve` over
   `Transport.Stdio.start_self/0` with `ClientProtocol.StdioAgent` implementing
   the Agent behaviour on `ClientProtocol.TurnRunner`, reached from
   `mix raxol.acp`, `bin/raxol-acp`, and `raxol acp`. The dep risk was answered
   the guarded way: `Serve` checks `Code.ensure_loaded?` on the TurnRunner and
   StdioAgent and errors helpfully, and `raxol_agent/mix.exs` drops the
   unpublished path dep under `HEX_BUILD`. Serve exits 0 on a clean peer
   disconnect, so an editor session leaves no resident BEAM behind.
4. Payments: shipped as item 20 describes.
5. Publishing: the gate held. `raxol code` ships the real TUI on master, and the
   `raxol-cli-v0.1.0` tag attached per-arch binaries to a GitHub Release. That
   tag predates the subcommand, so a re-tag is what puts the TUI in a downloaded
   binary; the npm publish is still a manual workflow run, and still a human
   decision.
