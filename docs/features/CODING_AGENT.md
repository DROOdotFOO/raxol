# Coding Agent (`mix raxol.code`)

An interactive, multi-turn coding assistant that runs in the terminal, wearing the axol
face `≡··≡`. It is Raxol's answer to a terminal coding CLI: type a prompt, watch the agent
stream its reasoning, read files, and (with your per-call approval) write files and run
shell commands scoped to the current working directory. Every mutating tool call is gated
by the [Authorization engine](AGENT_FRAMEWORK.md#authorization-allowaskdeny), so a write or
a shell command never runs unattended.

It boots `Raxol.Agent.Code.App`, a thin Lifecycle TEA app that owns the coding loop over
the harness contract and reuses the same transcript and streaming machinery as the rest of
the agent stack.

## Running it

`mix raxol.code` lives in the `raxol_agent` package. Main `raxol` does not depend on
`raxol_agent` (the dependency runs the other way), so the task is package-scoped. Run it
from inside the package, or use the launcher shim from anywhere:

```bash
# from inside the package
cd packages/raxol_agent
mix deps.get            # once
mix raxol.code

# or from any directory, via the shim (keeps YOUR cwd as the agent's workspace)
bin/raxol-code
```

The `bin/raxol-code` shim runs the task from the package while keeping the caller's working
directory as the agent's workspace (the file and shell tools are scoped to it via
`RAXOL_CLI_CWD`). It `exec`s `mix` so the full-screen UI inherits the real terminal.

The Burrito-packaged `raxol` binary (`packages/raxol_cli`, unpublished until this
subcommand ships in a release) carries the same TUI as `raxol code`: every entry
point shares one launch path, `Raxol.Agent.Code.Launcher`, so flags, provider
resolution, and the session store cannot drift between them.

Not sure what to try first? These all work on this repo from a cold start:

```
summarize mix.exs
what are the three largest files under lib?
find every module that starts a GenServer
```

## Connecting a provider

With no `--backend`, the agent auto-detects a provider through the shared
`Raxol.Agent.Backend.Resolver`, in this precedence order:

1. an explicit `--api-key` (or an `:api_key` opt),
2. a 1Password reference stored by `/login` (resolved through the `op` CLI),
3. a provider env var (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `KIMI_API_KEY`, `OPENROUTER_API_KEY`, `LONGCAT_API_KEY`, ...),
4. the generic `AI_API_KEY` (plus optional `AI_BASE_URL` / `AI_MODEL`) for any OpenAI-compatible endpoint.

If nothing resolves, the TUI opens on an interactive setup wizard instead of
failing against a placeholder endpoint:

- a selectable provider list (`↑`/`↓` to move, `Enter` to connect, `Esc` to
  dismiss), each row marked connected (`●`) or not (`○`) with an actionable
  note when detection has a problem (a stored reference that needs
  `op signin`, or an env var that is set but empty);
- picking a keyed provider opens a masked credential entry: paste an `op://`
  reference (shown in the clear, stored) or an API key (masked). After a raw
  key connects, the wizard offers to save it to 1Password so no plaintext
  persists;
- picking a local provider (`lm_studio`, `ollama`) connects with no key.

The `/login` text command remains for scripted/power use (it works alongside
the wizard):

```
/login                                          # open the wizard
/login anthropic op://Vault/Anthropic/key       # store a 1Password reference (persisted)
/login openai sk-...                             # a session-only key (never written)
/login lm_studio                                 # a local server, no key
```

On connect (and once at launch for an auto-detected provider), the agent fires
a cheap, async validation ping and reports the outcome in the status line:
`validated`, `key rejected (HTTP 401)`, or `endpoint unreachable`. It prefers
the provider's token-free model-list endpoint (`GET /v1/models`), falling back
to a single-token completion only when that is unavailable. The check runs off
the UI process, so a slow or offline endpoint never blocks the TUI, and the
connection is usable immediately regardless.

Stored references live in `~/.raxol/providers.json` (override with
`$RAXOL_PROVIDERS`), owner-readable only. That file holds `op://` references,
models, and base URLs, never raw keys. Zero-config env usage still works: set
`ANTHROPIC_API_KEY` (or another provider var) and launch.

Supported providers: `anthropic`, `openai`, `kimi`, `openrouter`, `longcat`,
`lumo`, `ollama`, `lm_studio`, `llm7`, `mock`.

A repo can also pin its default provider and model in `.raxol/config.json`
(read from the working directory, references only, raw keys deliberately
ignored):

```json
{ "provider": "anthropic", "model": "claude-sonnet-5" }
```

Precedence is explicit flag, then the repo pin, then environment
auto-detection. `mix raxol.inspect` (or `/inspect` in the TUI) shows exactly
what would resolve in the current directory and why.

## Flags

| Flag | Effect |
|------|--------|
| `--backend NAME` | Pin an LLM backend (auto-detected if omitted). Validated against `Backend.Selector.supported_backends/0`. `--harness` is a deprecated alias. |
| `--model NAME` | Model override. |
| `--api-key KEY` | API key for the selected backend (else resolved from op/env). |
| `--base-url URL` | Override the backend base URL. |
| `--system TEXT` | System-prompt override. |
| `--continue` | Resume the most recently updated session. |
| `--resume ID` | Resume a specific session by id. |
| `--sessions` | Print saved sessions and exit (no TUI). |
| `--replay ID` | Print a session's transcript from its durable journal and exit (no TUI). |
| `--to-offset N` | With `--replay`: stop at journal offset N. Alone it is a usage error. |
| `--ascii` | ASCII-only face for terminals without a UTF-8 font. |
| `-h`, `--help` | Print usage and exit. |

The SSH flags (`--ssh`, `--ssh-port`, `--authorized-keys`, `--ssh-tenants`) are
described under [Serving over SSH](#serving-over-ssh).

```bash
mix raxol.code --backend anthropic --model claude-sonnet-5
mix raxol.code --continue
mix raxol.code --resume sess-1234-5
mix raxol.code --sessions
mix raxol.code --replay sess-1234-5
```

`--resume` wins over `--continue`; with neither, a fresh session is minted.
`--replay` refuses to combine with `--ssh`, `--sessions`, `--continue`, or
`--resume`.

## Keys

| Key | Action |
|-----|--------|
| type + Enter | Send a prompt (or a `/command`) |
| `a` / `y` | Approve the pending tool call once |
| `s` | Approve always (remembers the tool for this session) |
| `d` / `n` | Deny the pending approval |
| Shift+Tab / Ctrl+P | Toggle plan mode |
| Esc | Deny a pending approval, else interrupt the running turn |
| Ctrl+C | Quit |

Typing, Enter, plan-mode toggles, and backspace are accepted only when the agent is idle
(not mid-turn and not waiting on an approval).

## Slash commands

| Command | What it does |
|---------|--------------|
| `/help` | Show help |
| `/login [provider]` | Connect an LLM provider (1Password reference, session key, or local server) |
| `/clear` | Start a new session (the old file stays on disk) |
| `/model <name>` | Switch model for the next turns (bare `/model` on a connected provider opens a live model picker) |
| `/plan` | Toggle plan mode |
| `/compact` | Shrink history: keep the last 6 messages, replace older ones with a compaction marker, then persist |
| `/rewind` | Drop the last turn from the transcript and the conversation (and write a rewind marker to the journal, so a replay drops it too) |
| `/context` | Session stats (message, event, and token counts, plan on/off, model, session key) |
| `/usage` | Session token totals per direction, an estimated cost (env rates, else the `Raxol.Agent.LlmPrices` table), and the shared-ledger totals when a ledger is wired |
| `/sessions` | List up to 10 saved sessions |
| `/resume [id]` | Switch session in place; bare `/resume` opens a picker over the 20 most recent |
| `/fork [title]` | Branch a copy of this session under a new id and continue there |
| `/rename <title>` | Title this session (shown by `/sessions`) |
| `/export [path]` | Write the transcript to a file (default `<session>.txt` in the cwd) |
| `/transcript` | Write the transcript to a fresh 0600 file (a temp file, or the workspace in a jailed session) and print a pager hint |
| `/copy` | Copy the last assistant reply to the clipboard |
| `/find <text>` | Case-insensitive search over the transcript blocks (first 8 matches) |
| `/logout [provider]` | Disconnect the session's provider; with a name, also forget its stored credential reference |
| `/share` | Mint a read-only share link for this session |
| `/mcp` | List MCP servers configured in `.mcp.json` |
| `/hooks` | Show pre/post/stop hook counts |
| `/inspect` | Show every config source in use: provider resolution and why, the repo pin, hook rules, MCP servers, skills roots, session store (same output as `mix raxol.inspect`) |

A jailed session (multi-tenant SSH, see below) refuses `/login`, `/logout`, and
`/copy`: the keyboard principal there is a tenant, and all three reach host-global
state (the credential store, the host clipboard). `/rewind`, `/resume`, and `/fork`
refuse while a turn is running.

## Tools

The default toolset is read-only file inspection plus gated mutation and a read-only
sub-agent. Read-only tools run without a prompt; sensitive tools gate through approval.

| Tool | Sensitive? | Notes |
|------|:---:|-------|
| `list_dir`, `read_file`, `file_stat` | No | `read_file` supports `offset`/`limit` line ranges, caps at 256KB |
| `grep`, `glob` | No | `grep` uses ripgrep when available, else a bounded pure-Elixir walk; `glob` is cwd-relative |
| `write_file` | Yes | Refuses to clobber unless `overwrite: true`; returns a diff-shaped result |
| `edit_file` | Yes | `old_string` must match once unless `replace_all` |
| `bash` | Yes | `/bin/sh -c`, combined stdout+stderr, output truncated past 64KB |
| `task` | (delegating) | Delegates to a fresh read-only sub-agent that cannot write, run bash, or recurse |
| `lsp` | No | Language-server queries: diagnostics, symbols, definition, references, hover |
| `lsp_rename` | Yes | Renames a symbol through the language server and writes the edits |

Skills tools (`skills_list`, `skill_view`, `skill_manage`) join the toolset when a
skills provider is configured.

## Language server

The agent asks a language server about code rather than inferring it from text. `lsp`
answers what the IDE would: `diagnostics` (whether an edit actually compiles), `symbols`
(a file's outline), `definition`, `references` (before changing a signature), and `hover`.
`lsp_rename` renames a symbol everywhere it appears using the server's own understanding
of scope, and writes the result.

That last one is the difference between a rename and a find-and-replace: it will not touch
a same-named symbol in another scope, and it follows re-exports.

Positions crossing the tool boundary are **1-based** `line` and `column`, matching the line
numbers `read_file` prints. LSP itself is 0-based and counts columns in UTF-16 code units;
both conversions happen inside the tool, so a rename on a line containing an emoji or CJK
text lands on the right characters instead of one column early.

### Which server

Built-in defaults cover elixir (`elixir-ls`), rust (`rust-analyzer`), typescript
(`typescript-language-server`), python (`pyright-langserver`), and go (`gopls`), matched on
file extension. A repo overrides or extends them in `.raxol/lsp.json`:

```json
{
  "servers": {
    "elixir": { "command": "lexical" },
    "zig": { "command": "zls", "extensions": [".zig"] }
  }
}
```

Overriding a built-in by name keeps its extensions, so pointing `elixir` at a different
binary does not mean restating the file list. A server whose command is not on `PATH` is
reported as such rather than silently doing nothing, and a malformed file falls back to the
defaults rather than blocking boot. `mix raxol.inspect` (or `/inspect`) lists every server
that would serve the directory and whether it is installed.

### Lifecycle

Servers start on first use, not at boot, and one per language is kept for the session:
starting `rust-analyzer` per turn would mean indexing the crate per turn. Each is owned by
a `Raxol.Agent.Lsp.Pool` that monitors the session process, so when the session ends by any
path (a clean quit, an SSH disconnect, a crash) the pool stops every server it owns before
going down. No teardown path has to remember them. A server that crashes is dropped; the
next request for that language starts a fresh one.

The pool stops them explicitly rather than relying on the process link. A pool that exits
`:normal` does not take a linked, non-trapping process with it, so the clients, and the OS
subprocesses behind them, would otherwise outlive the session. Waiting for a cold server
to finish `initialize` also happens off the pool's own process, so a session that ends
during a start is noticed immediately instead of after the start timeout.

### Containment

Paths in go through the same cwd resolution as every other file tool. Results coming back
are the server's, and a language server indexes whatever it likes: a definition can land in
a dependency or the standard library. Those are reported as absolute paths in a normal
session and dropped in a jailed one. A rename's edits are each re-checked against the
workspace root before anything is written, so a server cannot direct a write outside it.

A rename is also bounded in width. Approval is asked before the server has answered, so
the approver sees a position and a new name and cannot see how many files the rename
reaches; a rename touching more than `max_files` (default 50) is refused with the count
instead of performed. Retrying with an explicit `max_files` is a fresh call, and therefore
a fresh approval that does carry the number. All the edits are composed before any of them
is written, so an edit that cannot apply fails with nothing changed rather than partway
through; if a write itself fails, the error names the files that already landed.

**A jailed (multi-tenant) session gets no language server at all.** A server is arbitrary
code execution on the workspace twice over: `.raxol/lsp.json` names the binary, and the
binary runs project code to answer anything. `rust-analyzer` executes `build.rs`, and
`elixir-ls` compiles the project. In a jail the workspace is tenant-written, which makes
this the same refusal hooks and MCP servers already get.

### Not yet

Diagnostics are surfaced when the model asks for them, not automatically after every write.
Post-write diagnostics are tracked in the parity epic.

Every path expands relative to the working directory: the tool context's `:cwd`
when the surface sets one (an ACP session root, a tenant jail), else
`RAXOL_CLI_CWD`, else the BEAM cwd. The result must stay under that root, and
containment is decided on the REAL path: `Raxol.Agent.Actions.Fs.resolve/2`
canonicalizes both sides component by component (`realpath`), so a symlink cannot
lexically hide an escape. A `../` escape, an outside-cwd absolute path, or a
symlink cycle is rejected with `:outside_cwd`.

`grep` and `glob` run that check on every path they WALK, entry by entry through
the recursive scan. `File.regular?/1` and `File.dir?/1` follow symlinks, so the
native grep walk tests each symlinked entry for containment, skips the ones that
escape, and re-tests at the read itself; `glob` rejects every wildcard match whose
realpath lands outside the root, so an out-of-workspace name stays undisclosed.

In a jailed session the `bash` tool is refused entirely
(`Raxol.Agent.Actions.Code.shell_jail_allow/1` returns
`{:error, :shell_disabled_in_jail}`) unless the context carries a
`Raxol.Agent.Sandbox.Shell`. A `/bin/sh -c` command line is not a path, so
`{:cd, cwd}` is a starting directory rather than a boundary and the fs
containment above does not apply to it.

## Approval UX

When the agent proposes a sensitive tool, the authorizer runs inside the reasoning loop and
blocks until you answer, with a 300-second timeout that defaults to deny. Nothing writes or
shells out on its own. The decision routes through `Raxol.Agent.Authorization.Engine`:

- **ALLOW**: the tool is already in this session's remembered set, so it runs with no prompt.
- **DENY**: plan mode plus a mutating tool is refused (`plan_mode_read_only`).
- **ASK**: otherwise a footer prompt opens: `[a]llow once` / `[s]always` / `[d]eny`, Esc denies.

"Allow always" remembers the tool for the rest of the session (per-tool memory held in the
app, not the engine), so you approve a class of action once.

## Plan mode

Toggle plan mode (Shift+Tab, Ctrl+P, or `/plan`) to investigate without touching anything.
Plan mode appends a read-only directive to the system prompt and has the Authorization
engine deny every mutating tool, with a `PLAN` chip in the status strip. Toggle it off to
execute.

## Spending limits

LLM spend is metered into the same `Raxol.Payments.Ledger` agent payments draw on,
through `Raxol.Agent.Code.CostLedger`. Wire it with the app options `:ledger`
(a Ledger server ref), `:spending_policy` (a `Raxol.Payments.SpendingPolicy`), and
optionally `:agent_id` (the ledger scope key, default `"raxol-code"` so a `/clear`
cannot mint its way out of a cap). Without raxol_payments in the host, or without
both a ledger and a policy, every call here degrades to a no-op and nothing changes.

Each provider call's cost is recorded as its `turn_completed` event folds, priced
from `RAXOL_COST_PER_MTOK_IN`/`RAXOL_COST_PER_MTOK_OUT` when both are set, else from
the `Raxol.Agent.LlmPrices` table. Sub-agent rounds from the `task` tool run in a
nested stream whose usage never reaches the parent fold, so they report through a
`:usage_sink` and are metered the same way. The gate then runs twice:

- at submit, so an exhausted budget refuses the NEXT prompt with a notice naming
  what clears it (`frozen`, `ledger_unreachable`, or the limit that tripped);
- inside the running turn, so a turn that blows the cap mid-loop is interrupted
  rather than allowed to keep looping through more provider calls.

A wired-but-dead ledger fails closed: an unanswerable `check_budget` reads as
`{:over, :ledger_unreachable}`.

With a ledger AND a policy wired, a model with no price fails closed too. An
unpriced model bills real tokens while the ledger records $0.00, so the first
response that reports billed tokens at $0.00 halts the running turn and blocks
the next prompt. The notice names the two fixes: set
`RAXOL_COST_PER_MTOK_IN`/`RAXOL_COST_PER_MTOK_OUT`, or `/model` a priced one.
Naming a model with `/model` clears the halt. The first round of a session
cannot be prevented (the billed model is only knowable from a response), so
this stops the second.

## Sessions

Conversation memory persists across turns and across runs, one JSON file per session.
`--continue` resumes the most recent; `--resume ID` a specific one. The default directory is
`$RAXOL_CODE_SESSIONS` if set, otherwise `~/.raxol/code_sessions`. A saved session stores the
messages and the durable transcript events, so a resume rebuilds both the model context and
the visual scrollback. Session ids are validated where they enter (`--resume`, `/resume`,
`--replay`) against the charset `[A-Za-z0-9._-]+`, excluding `.` and `..`, and the store
additionally passes the id through `Path.basename`, so a crafted id cannot escape the
sessions directory.

Alongside the JSON store, each session appends its durable-tier events to an
offset-addressed journal (`Raxol.Agent.Journal.FileStore`, one directory per session
under `$RAXOL_SESSIONS_DIR` or `~/.raxol/sessions`), through a single owning Writer, as
they fold. The JSON store only persists on turn boundaries, so the journal is what
survives a process death mid-turn; it opens lazily on the first durable event, and an
append failure lands on the status line without blocking the fold.

That journal is what `--replay ID` reads: it folds the records through
`Raxol.Harness.Projection` and prints the transcript without starting a TUI, with
`--to-offset N` replaying only the prefix at or below offset N. A session recorded
before the journal existed (or whose journal is gone) falls back to the JSON store.
Replay is read-only: a crash-torn tail is tolerated on read and healed only by the
owning Writer (`Reader.resume_scan/1`), so replaying a live session cannot disturb it.

`/rewind` drops the last turn from the transcript and the conversation and writes a
rewind marker into the journal, so `--replay` and the shared viewer drop it too. Turn
ids are only unique within one VM run, so a rewind removes the contiguous trailing run
of the last turn's events rather than every event with that id.

## The axol face

The status face `≡··≡` is a single source of truth in
`Raxol.UI.Components.Harness.AxolFace` (main `raxol` package). The gills `≡` stay constant
and the eyes carry state. `--ascii` swaps the gills for `=`.

| State | Unicode | ASCII | Color |
|-------|---------|-------|-------|
| `:boot` | `≡··≡` cycling | `=..=` cycling | cyan |
| `:idle` | `≡··≡` | `=..=` | none |
| `:thinking` | `≡''≡` | `=''=` | cyan |
| `:working` | `≡oo≡` `≡OO≡` | `=oo=` `=OO=` | cyan |
| `:done` | `≡^^≡` | `=^^=` | green |
| `:error` | `≡xx≡` | `=xx=` | red |

Contract events drive the face: a started turn is `:thinking`, a running tool is
`:working`, a finished turn is `:done`, and a failure is `:error`.

## Hooks and MCP config

Two optional per-project files, both read from `<cwd>/`:

- `.raxol/hooks.json` declares `pre_tool_use` / `post_tool_use` matchers (each
  `{"match": ..., "command": ...}`, `match` is an exact tool name or `"*"` and defaults to
  `"*"`) plus `stop` commands. A pre-hook that exits non-zero vetoes the tool (30-second
  timeout, `RAXOL_TOOL_NAME` in the environment); post-hooks are advisory; stop commands
  run at turn end.
- `.mcp.json` uses the standard `{"mcpServers": {name: {command, args, env}}}` format.
  Configured servers are started (supervised, off the boot path) and their tools join the
  live toolset as `mcp__<server>__<tool>`, sensitive by default: each call is
  approval-gated like any mutating tool, and plan mode denies them outright since an
  external tool's effects are unknown. `/mcp` shows per-server connection state
  (`●` connected, `✗` failed, `…` loading); a server that fails to start is skipped with
  a note, never fatal. At most 16 servers load per config, and server names are held to
  `[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}` (each one interns an atom and spawns a subprocess);
  refusals show up in `/mcp` alongside connection failures.

Both files name a command to execute, so both are read only when the session owns its
workspace. A jailed session (multi-tenant SSH, see below) loads NEITHER: its workspace is
writable by a tenant whose own `write_file` can author these files, and running them would
be arbitrary execution as the server uid: around the cwd jail, the `:jail` shell gate,
and the approval chain alike. `/mcp` and the status line say so rather than reporting an
empty config.

## Editors over ACP

`mix raxol.acp` serves the agent loop over the
[Agent Client Protocol](https://agentclientprotocol.com) on stdio, so an
ACP-speaking editor (Zed and its ecosystem) can spawn and drive it: each
`session/new` gets a real `Raxol.AgentClientProtocol.Session` running
`Raxol.Agent.ClientProtocol.TurnRunner` over the same provider resolution
as every other entrypoint. Turns are read-only on this surface until ACP's
permission flow is bridged to the authorization engine. Each session's file
tools scope to the `cwd` the editor names in `session/new`, so one server
handles projects in different directories and every tool call is contained
under its own session root. Point
the editor at the `bin/raxol-acp` shim rather than `mix` directly, so Mix
compile output never reaches the NDJSON wire; `mix help raxol.acp` has the
Zed `agent_servers` snippet. This is a repo-checkout feature: the protocol
package is a dev/test path dependency, so a Hex install of raxol_agent is
built without it and the task exits 1 with an explanation.

`Raxol.Agent.ClientProtocol.Serve` owns every exit code, so `mix raxol.acp`,
the packaged `raxol acp`, and the shim agree. A clean peer disconnect exits 0:
the transport reports the close, the connection stops, and the process answers
with a code instead of dying of the linked exit. The non-zero paths are a usage
error (64), a build with no ACP support (1), an unresolved provider (1), and a
connection that ended abnormally (1).

## Serving over SSH

`mix raxol.code --ssh --authorized-keys ~/.ssh/agent_keys` serves the same
TUI over SSH (default port 2222, `--ssh-port` to change): each connection
gets its own app instance and a fresh session, with the provider resolved
once, server-side, at launch. Auth is publickey only; this surface reaches
write and shell tools, so anonymous serving is not offered at all, and
`--continue`/`--resume` are rejected in this mode. Single-tenant by design:
every connection shares the server's filesystem, credentials, and session
store, so serve it only to keys you would hand a shell.

### Multi-tenant hosting

`mix raxol.code --ssh --ssh-tenants /srv/tenants` hosts many users from one
daemon. Each tenant is a directory under the root:

    /srv/tenants/<user>/
    ├── ssh/authorized_keys   # that user's keys: a key only authenticates
    │                         # the username it is filed under
    ├── work/                 # the cwd jail: every fs tool, /export, and
    │                         # /transcript confine here (bash is refused)
    ├── code_sessions/        # that user's session store (/sessions, /resume)
    └── sessions/             # that user's durable journal (/share, --replay)

The AUTHENTICATED username decides everything: usernames are restricted to
a conservative charset (anything else fails auth outright), the same
normalization maps the key lookup and the workspace so they can never
disagree, and a connection whose tenant options cannot be derived is
refused rather than started unjailed. A jailed session also loads no
`.raxol/hooks.json` and no `.mcp.json`: both name a command to run and both
live in the tenant's own writable workspace.

Spending identity is `ssh:<user>` (the tenant's `:agent_id`), so a shared
`Raxol.Payments.Ledger` + policy on the server-level app options gives each
tenant their own budget, enforced as described in
[Spending limits](#spending-limits): the running turn halts and the next
prompt is refused.

What the jail is NOT: separate OS uids. This is one BEAM under one uid, so
the confinement is the fs tools' path resolution, the refusal of the `bash`
tool, and the refusal to load workspace-configured commands. Untrusted
tenants want separate uids or containers on top.

Hosted deployment: set `RAXOL_SSH_CODE=true` with
`RAXOL_SSH_CODE_TENANTS=/data/tenants` and
`RAXOL_SSH_CODE_BUDGET_USD=<cap>` (and optionally `RAXOL_SSH_CODE_PORT`,
default 2223) and the main application serves the coding agent beside the
SSH playground. It refuses to start without BOTH: there is no anonymous or
single-tenant hosted mode, and no unmetered one either. A hosted tenant
spends the host's provider credential, so an unset or unparseable cap
refuses to serve rather than serving unbounded. The cap is per tenant
(lifetime and session), enforced through a `Raxol.SSH.CodeLedger` the
supervisor starts alongside the server, so the build needs raxol_payments.

Three dependencies have to be on the release code path, and boot refuses
without any of them: raxol_agent for the agent itself, raxol_payments for
the ledger, and `req` for the HTTP client every remote provider resolves
to. `req` is easy to miss because raxol_agent declares it optional and
optional dependencies do not propagate: a release could pass every other
check and still answer `{:error, :req_not_available}` on every turn. The
deploy app (`web/mix.exs`) declares all three.

Onboarding a user is `mkdir -p /data/tenants/<user>/ssh` plus writing
their `authorized_keys`; then `ssh <user>@host -p 2223` is the whole
client.

## Sharing a session read-only

`/share` mints a signed, expiring token (24h) for the current session and
ensures its journal exists for a viewer to replay. Configuration is one
secret: set `RAXOL_SHARE_SECRET` (or the `:share_secret` app option), at
least 32 bytes, on both the TUI host and the web host, and mount the viewer
in any Phoenix app:

    live "/share/:token", Raxol.Agent.Code.ShareLive

The view verifies the token offline (`Raxol.Agent.Code.ShareToken`, HMAC,
no server state), replays the session's durable journal with the same
rewind-marker-aware fold `--replay` uses, and follows new records live
from the journal high-watermark. Transcript only: the surface has no
input path.

A token grants read access to exactly one session until it expires, and
it FOLLOWS that session: the viewer keeps receiving new records for the
full 24h, so sharing is "watch me work", not "here is a snapshot". There
is no revocation short of rotating the secret.

The token also carries the scope its session id is meaningful in, because
ids are unique per journal base rather than per host. An unjailed session
signs the empty scope (the host's own base); a tenant session signs its
tenant name, and the viewer resolves
`<tenants_root>/<scope>/sessions` from `:share_tenants_root` or
`RAXOL_SSH_CODE_TENANTS`. A scoped token on a host with no tenants root
configured is refused rather than resolved against the host's own tree.

A blank or under-length secret reads as unconfigured, so `/share` says so
rather than minting a forgeable token, and a session whose id is not of the
shareable shape is refused with a message pointing at `/fork` or `/resume`
under a plain id.

`RAXOL_SHARE_BASE_URL` turns the `/share` notice into a pasteable link.
`phoenix_live_view` is an optional dependency; without it the viewer
module simply is not compiled and `/share` still mints tokens.
Multiplayer (shared input) is not scheduled.

## Driving the harness over MCP

`Raxol.Agent.Harness.McpTools` exposes the harness itself as MCP tools:
`harness_start_session`, `harness_send_prompt`, `harness_read_transcript`,
and `harness_list_sessions`. They share the TUI's session store, so a
session driven by an MCP client resumes in the TUI with `--resume` and vice
versa. Turns are read-only on the workspace (read/grep/glob; no
`write_file`, `edit_file`, or `bash` on this surface): there is no human
here to answer an approval prompt, so write capability waits on the MCP
authorizer wiring rather than shipping behind an allow-all flag. Run
`mix mcp.server` from `packages/raxol_agent` to serve them.

## See also

- [Agent Framework](AGENT_FRAMEWORK.md): the Turn driver, native harnesses, and the
  Authorization engine that `mix raxol.code` builds on.
- [Self-Improvement](SELF_IMPROVEMENT.md) and [Memory](MEMORY.md): the learning and recall
  layers an agent can opt into.
