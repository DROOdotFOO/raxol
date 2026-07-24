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

  `/help` · `/clear` · `/model <name>` · `/plan` · `/compact` · `/context`
  · `/sessions` · `/mcp` · `/hooks`

  ## Delegation, hooks, external config

  The agent can delegate a focused subtask to a read-only sub-agent via the
  `task` tool. A `.raxol/hooks.json` in the working directory declares
  shell commands to run before/after tool calls and at turn end (a
  non-zero pre-tool hook vetoes the tool). A `.mcp.json` declares external
  MCP servers, surfaced by `/mcp` (live tool-bridging is a follow-up).

  ## Options

    * `--backend`  — LLM backend atom (default `lm_studio`; also
      `anthropic`, `openai`, `ollama`, ... see `Backend.Selector`).
      `--harness` is accepted as a deprecated alias.
    * `--model`    — model override
    * `--base-url` — override the backend base URL
    * `--system`   — system prompt override
    * `--continue` — resume the most recently updated session
    * `--resume ID`— resume a specific session by id
    * `--sessions` — print saved sessions and exit
    * `--ascii`    — ASCII-only face (no `≡`/`·`)
  """

  use Mix.Task

  alias Raxol.Agent.Code.Store

  @switches [
    backend: :string,
    # `--harness` is a deprecated alias for `--backend`.
    harness: :string,
    model: :string,
    base_url: :string,
    system: :string,
    continue: :boolean,
    resume: :string,
    sessions: :boolean,
    ascii: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)

    cond do
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
        Enum.each(sessions, fn s -> IO.puts("  #{s.id}  (#{s.message_count} msgs)") end)
    end
  end

  defp launch(opts) do
    Mix.Task.run("app.start")

    {:ok, pid} = Raxol.start_link(Raxol.Agent.Code.App, app_opts(opts))
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp app_opts(opts) do
    executor = build_executor(opts)

    backend_opts =
      []
      |> maybe_put(:base_url, Keyword.get(opts, :base_url))

    []
    |> put_if(:executor, executor)
    |> Keyword.put(:backend_opts, backend_opts)
    |> put_if(:system, Keyword.get(opts, :system))
    |> put_if(:model, Keyword.get(opts, :model))
    |> put_if(:session_key, resolve_session(opts))
    |> Keyword.put(:ascii, Keyword.get(opts, :ascii, false))
  end

  defp resolve_session(opts) do
    cond do
      key = Keyword.get(opts, :resume) -> key
      Keyword.get(opts, :continue, false) -> Store.latest(Store.default_dir())
      true -> nil
    end
  end

  defp build_executor(opts) do
    backend_name = backend_opt(opts)
    supported = Raxol.Agent.Backend.Selector.supported_backends()

    backend =
      Enum.find(supported, &(Atom.to_string(&1) == backend_name)) ||
        usage_error(
          "unknown backend #{inspect(backend_name)}; supported: " <>
            Enum.map_join(supported, ", ", &Atom.to_string/1)
        )

    attrs =
      [backend: backend]
      |> maybe_put(:model, Keyword.get(opts, :model))

    Raxol.Agent.ExecutorConfig.new(attrs)
  end

  # `--backend` is canonical; `--harness` is the deprecated alias.
  defp backend_opt(opts) do
    case {Keyword.get(opts, :backend), Keyword.get(opts, :harness)} do
      {nil, nil} ->
        "lm_studio"

      {nil, legacy} ->
        IO.puts(:stderr, "raxol.code: --harness is deprecated; use --backend")
        legacy

      {name, _} ->
        name
    end
  end

  defp usage_error(message) do
    IO.puts(:stderr, "raxol.code: #{message}")
    exit({:shutdown, 64})
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp put_if(kw, _key, nil), do: kw
  defp put_if(kw, key, value), do: Keyword.put(kw, key, value)
end
