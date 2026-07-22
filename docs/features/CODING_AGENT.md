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

## Connecting a provider

With no `--harness`, the agent auto-detects a provider through the shared
`Raxol.Agent.Backend.Resolver`, in this precedence order:

1. an explicit `--api-key` (or an `:api_key` opt),
2. a 1Password reference stored by `/login` (resolved through the `op` CLI),
3. a provider env var (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `KIMI_API_KEY`, `OPENROUTER_API_KEY`, `LONGCAT_API_KEY`, ...),
4. the generic `AI_API_KEY` (plus optional `AI_BASE_URL` / `AI_MODEL`) for any OpenAI-compatible endpoint.

If nothing resolves, the TUI opens on a setup panel instead of failing against
a placeholder endpoint. Run `/login` to connect one live. The preferred path
is a 1Password reference (no plaintext key on disk):

```
/login                                          # show connection status
/login anthropic op://Vault/Anthropic/key       # store a 1Password reference (persisted)
/login openai sk-...                             # a session-only key (never written)
/login lm_studio                                 # a local server, no key
```

On connect, `/login` fires a cheap, async validation ping (a single-token
completion) against the resolved backend and reports the outcome in the status
line: `validated`, `key rejected (HTTP 401)`, or `endpoint unreachable`. The
check runs off the UI process, so a slow or offline endpoint never blocks the
TUI, and the connection is usable immediately regardless.

Stored references live in `~/.raxol/providers.json` (override with
`$RAXOL_PROVIDERS`), owner-readable only. That file holds `op://` references,
models, and base URLs, never raw keys. Zero-config env usage still works: set
`ANTHROPIC_API_KEY` (or another provider var) and launch.

Supported providers: `anthropic`, `openai`, `kimi`, `openrouter`, `longcat`,
`lumo`, `ollama`, `lm_studio`, `llm7`, `mock`.

## Flags

| Flag | Effect |
|------|--------|
| `--harness NAME` | Pin a backend harness (auto-detected if omitted). Validated against `Backend.Selector.supported_harnesses/0`. |
| `--model NAME` | Model override. |
| `--api-key KEY` | API key for the selected harness (else resolved from op/env). |
| `--base-url URL` | Override the backend base URL. |
| `--system TEXT` | System-prompt override. |
| `--continue` | Resume the most recently updated session. |
| `--resume ID` | Resume a specific session by id. |
| `--sessions` | Print saved sessions and exit (no TUI). |
| `--ascii` | ASCII-only face for terminals without a UTF-8 font. |

```bash
mix raxol.code --harness anthropic --model claude-sonnet-5
mix raxol.code --continue
mix raxol.code --resume sess-1234-5
mix raxol.code --sessions
```

`--resume` wins over `--continue`; with neither, a fresh session is minted.

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
| `/model <name>` | Switch model for the next turns (bare `/model` shows current) |
| `/plan` | Toggle plan mode |
| `/compact` | Shrink history: keep the last 6 messages, replace older ones with a compaction marker, then persist |
| `/context` | Session stats (message and event counts, plan on/off, model, session key) |
| `/sessions` | List up to 10 saved sessions |
| `/mcp` | List MCP servers configured in `.mcp.json` |
| `/hooks` | Show pre/post/stop hook counts |

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

Every path expands relative to the working directory (`RAXOL_CLI_CWD` or the BEAM cwd) and
must stay under it. A `../` escape or an outside-cwd absolute path is rejected with
`:outside_cwd`.

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

## Sessions

Conversation memory persists across turns and across runs, one JSON file per session.
`--continue` resumes the most recent; `--resume ID` a specific one. The default directory is
`$RAXOL_CODE_SESSIONS` if set, otherwise `~/.raxol/code_sessions`. A saved session stores the
messages and the durable transcript events, so a resume rebuilds both the model context and
the visual scrollback. The session id is passed through `Path.basename`, so a crafted id
cannot escape the sessions directory.

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

- `.raxol/hooks.json` declares `pre_tool_use` / `post_tool_use` matchers (each `[match, command]`,
  `match` is an exact tool name or `"*"`) plus `stop` commands. A pre-hook that exits non-zero
  vetoes the tool (30-second timeout, `RAXOL_TOOL_NAME` in the environment); post-hooks are
  advisory; stop commands run at turn end.
- `.mcp.json` uses the standard `{"mcpServers": {name: {command, args, env}}}` format. Today
  this is discovery only (surfaced by `/mcp`); bridging those servers' tools into the live
  toolset is a follow-up.

## See also

- [Agent Framework](AGENT_FRAMEWORK.md): the Turn driver, native harnesses, and the
  Authorization engine that `mix raxol.code` builds on.
- [Self-Improvement](SELF_IMPROVEMENT.md) and [Memory](MEMORY.md): the learning and recall
  layers an agent can opt into.
