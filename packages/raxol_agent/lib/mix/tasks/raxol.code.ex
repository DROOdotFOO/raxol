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
  `/compact` · `/context` · `/sessions` · `/mcp` · `/hooks`

  ## Delegation, hooks, external config

  The agent can delegate a focused subtask to a read-only sub-agent via the
  `task` tool. A `.raxol/hooks.json` in the working directory declares
  shell commands to run before/after tool calls and at turn end (a
  non-zero pre-tool hook vetoes the tool). A `.mcp.json` declares external
  MCP servers, surfaced by `/mcp` (live tool-bridging is a follow-up). A
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
    * `--ascii`    — ASCII-only face (no `≡`/`·`)
    * `-h`/`--help` — print usage and exit
  """

  use Mix.Task

  alias Raxol.Agent.Backend.Cli
  alias Raxol.Agent.Code.Store

  @switches [
    backend: :string,
    # `--harness` is a deprecated alias for `--backend`.
    harness: :string,
    model: :string,
    api_key: :string,
    base_url: :string,
    system: :string,
    continue: :boolean,
    resume: :string,
    sessions: :boolean,
    ascii: :boolean,
    help: :boolean
  ]

  @aliases [h: :help]

  @usage """
  Usage: mix raxol.code [options]

  Interactive coding agent TUI (the axol face). Package-scoped: run from
  packages/raxol_agent, or from anywhere via bin/raxol-code.

  Options:
    --backend NAME   LLM backend (auto-detected if omitted; --harness is a
                     deprecated alias)
    --model NAME     model override
    --api-key KEY    API key for the selected backend (else op/env)
    --base-url URL   override the backend base URL
    --system TEXT    system prompt override
    --continue       resume the most recently updated session
    --resume ID      resume a specific session by id
    --sessions       print saved sessions and exit
    --ascii          ASCII-only face for terminals without a UTF-8 font
    -h, --help       print this help

  Full docs: mix help raxol.code
  """

  @impl Mix.Task
  def run(argv) do
    {opts, _args, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      Keyword.get(opts, :help, false) -> IO.puts(@usage)
      invalid != [] -> usage_error("unknown options: #{inspect(invalid)}")
      Keyword.get(opts, :sessions, false) -> print_sessions()
      true -> launch(opts)
    end
  end

  defp print_sessions do
    dir = Store.default_dir()

    case Store.list(dir) do
      [] ->
        IO.puts("no saved sessions in #{dir}")

      sessions ->
        IO.puts("saved sessions in #{dir}:")

        Enum.each(sessions, fn s ->
          IO.puts("  #{s.id}  (#{s.message_count} msgs)")
        end)
    end
  end

  defp launch(opts) do
    # Resolve flags and the provider before booting: an unknown backend
    # errors fast, without starting the app.
    app_opts = app_opts(opts)

    Mix.Task.run("app.start")

    {:ok, pid} = Raxol.start_link(Raxol.Agent.Code.App, app_opts)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp app_opts(opts) do
    project = Raxol.Agent.Code.ProjectConfig.load(File.cwd!())

    resolution =
      Raxol.Agent.Backend.Resolver.resolve(resolver_opts(opts, project))

    []
    |> put_if(:system, Keyword.get(opts, :system))
    |> put_if(:model, Keyword.get(opts, :model) || Map.get(project, :model))
    |> put_if(:session_key, resolve_session(opts))
    |> Keyword.put(:ascii, Keyword.get(opts, :ascii, false))
    |> apply_resolution(resolution)
  end

  # The resolver inputs, in precedence order explicit flag > `.raxol/config.json`
  # pin > env auto-detect: a `--backend`/`--model`/`--base-url` wins, else the
  # per-repo pin, else the resolver auto-detects. The resolver's own input key
  # stays `:harness` (its internal provider vocabulary); only the user-facing
  # flag is renamed.
  defp resolver_opts(opts, project) do
    []
    |> maybe_put(
      :harness,
      backend_flag(opts) || Map.get(project, :provider)
    )
    |> maybe_put(:model, Keyword.get(opts, :model) || Map.get(project, :model))
    |> maybe_put(:api_key, Keyword.get(opts, :api_key))
    |> maybe_put(
      :base_url,
      Keyword.get(opts, :base_url) || Map.get(project, :base_url)
    )
  end

  # `{:ok, executor, source}` wires the executor and records how it was found;
  # `{:no_key, harness}` and `:no_provider` open the App on its setup panel
  # (no executor) so the user can `/login` rather than hit a crash.
  defp apply_resolution(app_opts, {:ok, executor, source}) do
    app_opts
    |> Keyword.put(:executor, executor)
    |> Keyword.put(:provider_status, {:ready, executor.backend, source})
  end

  defp apply_resolution(app_opts, {:no_key, harness}) do
    Keyword.put(app_opts, :provider_status, {:no_key, harness})
  end

  defp apply_resolution(app_opts, :no_provider) do
    Keyword.put(app_opts, :provider_status, :no_provider)
  end

  defp resolve_session(opts) do
    cond do
      key = Keyword.get(opts, :resume) -> key
      Keyword.get(opts, :continue, false) -> Store.latest(Store.default_dir())
      true -> nil
    end
  end

  # Shared `--backend`/`--harness` normalization + validation (deprecation
  # notices, supported-name check) through `Backend.Cli`, so this task and
  # `raxol.p` cannot drift. Returns the backend atom, or `nil` when neither
  # flag is given (which asks the resolver to auto-detect).
  defp backend_flag(opts) do
    case Cli.flag(opts, "raxol.code") do
      {:ok, backend} -> backend
      {:error, message} -> usage_error(message)
    end
  end

  defp usage_error(message) do
    IO.puts(:stderr, "raxol.code: #{message}\n\n#{@usage}")
    exit({:shutdown, 64})
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp put_if(kw, _key, nil), do: kw
  defp put_if(kw, key, value), do: Keyword.put(kw, key, value)
end
