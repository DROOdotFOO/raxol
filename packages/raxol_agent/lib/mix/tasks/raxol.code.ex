defmodule Mix.Tasks.Raxol.Code do
  @shortdoc "Interactive coding agent TUI (the axol face ≡··≡)"

  @moduledoc """
  An interactive, multi-turn coding assistant in the terminal — the
  `mix raxol.code` surface, wearing the axol face `≡··≡`.

      mix raxol.code
      mix raxol.code --backend anthropic --model claude-sonnet-5
      mix raxol.code --continue          # resume the most recent session
      mix raxol.code --resume sess-123-4  # resume a specific session
      mix raxol.code --sessions          # list saved sessions and exit
      mix raxol.code --replay sess-123-4  # print a session transcript and exit
      mix raxol.code --ascii             # ASCII-only face for legacy terminals

  It boots `Raxol.Agent.Code.App`, a TEA app that owns a coding loop over
  the harness contract: type a prompt, watch the agent stream reasoning,
  read files, and (with your per-call approval) write files and run shell
  commands scoped to the current working directory. The conversation and
  its transcript are persisted per session, so `--continue`/`--resume`
  restore both the model context and the scrollback.

  ## Keys

    * type + Enter — send a prompt (or a `/command`)
    * `a` / `s` / `d` — answer a tool-approval prompt (once / always / deny)
    * Shift+Tab / Ctrl+P — toggle plan mode
    * Esc           — deny a pending approval, else interrupt the turn
    * Ctrl+C        — quit

  ## Slash commands

  `/help` · `/login [provider]` · `/clear` · `/model [name]` · `/plan` ·
  `/compact` · `/rewind` · `/context` · `/usage` · `/sessions` ·
  `/resume [id]` · `/fork [title]` · `/rename <title>` · `/export [path]` ·
  `/transcript` · `/copy` · `/find <text>` · `/logout [provider]` ·
  `/mcp` · `/hooks` · `/inspect`

  ## Delegation, hooks, external config

  The agent can delegate a focused subtask to a read-only sub-agent via the
  `task` tool. A `.raxol/hooks.json` in the working directory declares
  shell commands to run before/after tool calls and at turn end (a
  non-zero pre-tool hook vetoes the tool). A `.mcp.json` declares external
  MCP servers whose tools join the toolset as `mcp__<server>__<tool>`
  (approval-gated; `/mcp` shows connection state). A
  `.raxol/config.json` pins a default `provider`/`model` for the repo
  (references only, never a raw key), used when no `--backend`/`--model` flag
  is given — see `Raxol.Agent.Code.ProjectConfig`.

  ## Providers

  With no `--backend`, the agent auto-detects a provider from your
  environment via `Raxol.Agent.Backend.Resolver`: a 1Password reference
  stored by `/login` (read through the `op` CLI), then a provider env var
  (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, ...), then the generic
  `AI_API_KEY`/`AI_BASE_URL` pair. If nothing resolves, the TUI opens on a
  setup panel — run `/login` to connect a provider instead of failing
  against a placeholder endpoint. `--backend NAME` pins a provider and
  resolves that one's credential; `--api-key` supplies a key inline.

  ## Options

    * `--backend`  — LLM backend (auto-detected if omitted; also
      `anthropic`, `openai`, `kimi`, `ollama`, `lm_studio`, ... see
      `Backend.Resolver`). `--harness` is accepted as a deprecated alias.
    * `--model`    — model override
    * `--api-key`  — API key for the selected backend (else op/env)
    * `--base-url` — override the backend base URL
    * `--system`   — system prompt override
    * `--continue` — resume the most recently updated session
    * `--resume ID`— resume a specific session by id
    * `--sessions` — print saved sessions and exit
    * `--replay ID` — print a session's transcript from its durable
      journal and exit (falls back to the saved session file); with
      `--to-offset N` stops at journal offset N
    * `--ascii`    — ASCII-only face (no `≡`/`·`)
    * `--ssh` — serve the TUI over SSH; with `--authorized-keys DIR`
      single-tenant (one keyring, one principal), with `--ssh-tenants DIR`
      multi-tenant (per-user keys at `DIR/<user>/ssh/authorized_keys`,
      per-user cwd jail + session store + spending identity under
      `DIR/<user>/`)
    * `-h`/`--help` — print usage and exit
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    # A thin shell over the shared launcher — `Raxol.Agent.Code.Launcher`
    # contains no Mix calls, so the same code path serves the
    # Burrito-packaged `raxol code` where Mix does not exist. Flag/provider
    # resolution happens before the injected boot step, so an unknown
    # backend errors fast without starting the app.
    code =
      Raxol.Agent.Code.Launcher.main(argv,
        boot: fn ->
          Mix.Task.run("app.start")
          :ok
        end
      )

    exit({:shutdown, code})
  end
end
