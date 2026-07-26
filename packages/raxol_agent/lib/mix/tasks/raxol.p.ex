defmodule Mix.Tasks.Raxol.P do
  @shortdoc "One-shot headless agent run: prompt in, answer to stdout, events to stderr"

  @moduledoc """
  Run one agent turn headlessly — the `raxol -p` surface.

      mix raxol.p "what's inside my cwd"
      mix raxol.p --backend lm_studio --model qwen2.5-7b-instruct "summarize mix.exs"
      bin/raxol -p "what's inside my cwd"        # repo-root wrapper

  ## What it does

  Boots the agent runtime (no terminal UI), starts a `SessionStreamer`,
  subscribes to it, then pumps a `Raxol.Agent.Stream.react/2` run through
  `Raxol.Agent.Contract` — so this command is a real consumer of the
  harness contract, not a shortcut around it:

    * **stdout** — the answer only (streamed deltas when the backend
      streams; the final message otherwise). Pipe-safe.
    * **stderr** — every contract event as one JSON line: `turn_started`,
      `item_completed{tool_use/tool_result/message}`, `turn_completed`,
      `error`. `2>events.jsonl` captures a machine-readable trace.

  The agent gets read-only tools scoped under the current working
  directory: `list_dir`, `read_file`, `file_stat`, `grep`, `glob`. Pass
  `--write` to also expose the mutating coding tools (`write_file`,
  `edit_file`, `bash`) — these are `sensitive` and denied by default, so
  the flag installs an allow-all tool authorizer for this (unattended)
  run.

  ## Options

    * `--backend`  — LLM backend atom (default `lm_studio`; also
      `anthropic`, `openai`, `ollama`, ... see `Backend.Selector`).
      `--harness` is accepted as a deprecated alias.
    * `--model`    — model override (LM Studio uses its loaded model)
    * `--base-url` — override the backend base URL
    * `--system`   — system prompt override
    * `--timeout`  — per-run timeout in seconds (default 180)
    * `--write`    — expose write_file/edit_file/bash (opt-in; unattended)
    * `--no-tools` — plain completion, no tool loop

  ## Exit codes

  `0` success · `1` run error · `2` timeout · `64` usage error
  """

  use Mix.Task

  alias Raxol.Agent.Contract
  alias Raxol.Agent.SessionStreamer

  @default_timeout_s 180

  @switches [
    backend: :string,
    # `--harness` is a deprecated alias for `--backend`.
    harness: :string,
    model: :string,
    base_url: :string,
    system: :string,
    timeout: :integer,
    write: :boolean,
    tools: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    prompt = Enum.join(args, " ") |> String.trim()

    cond do
      invalid != [] ->
        usage_error("unknown options: #{inspect(invalid)}")

      prompt == "" ->
        usage_error("no prompt given. Usage: mix raxol.p [options] \"prompt\"")

      true ->
        run_prompt(prompt, opts)
    end
  end

  defp usage_error(message) do
    IO.puts(:stderr, "raxol.p: #{message}")
    exit({:shutdown, 64})
  end

  defp run_prompt(prompt, opts) do
    # Agent environment only — no terminal driver, no UI. stdout belongs to
    # the answer: boot without recompiling (bin/raxol precompiles silently)
    # and keep Logger quiet below :error.
    System.put_env("RAXOL_SKIP_TERMINAL_INIT", "true")
    Logger.configure(level: :error)

    Mix.Task.run("app.start", [
      "--no-compile",
      "--no-deps-check",
      "--no-archives-check",
      "--no-elixir-version-check"
    ])

    ensure_streamer!()

    session_id = "cli-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(session_id)

    stream_opts = build_stream_opts(prompt, opts)
    use_tools = Keyword.get(opts, :tools, true)

    runner =
      Task.async(fn ->
        stream =
          if use_tools do
            Raxol.Agent.Stream.react(prompt, stream_opts)
          else
            Raxol.Agent.Stream.run(prompt, stream_opts)
          end

        Contract.pump(session_id, stream, prompt: prompt)
      end)

    timeout_ms = Keyword.get(opts, :timeout, @default_timeout_s) * 1_000
    status = consume(session_id, runner, timeout_ms, %{wrote_stdout: false})
    exit({:shutdown, status})
  end

  # SessionStreamer is not in any package supervision tree yet (the CLI is
  # its first live consumer); start it idempotently.
  defp ensure_streamer! do
    case SessionStreamer.start_link([]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        raise "cannot start SessionStreamer: #{inspect(reason)}"
    end
  end

  defp build_stream_opts(_prompt, opts) do
    # raxol.p reserves stderr for the JSONL event stream, so pass prog: nil to
    # suppress the plain-text deprecation notice that would corrupt it.
    backend =
      case Raxol.Agent.Backend.Cli.resolve(opts, nil) do
        {:ok, backend} -> backend
        {:error, message} -> usage_error(message)
      end

    executor_attrs =
      [backend: backend]
      |> maybe_put(:model, Keyword.get(opts, :model))

    executor = Raxol.Agent.ExecutorConfig.new(executor_attrs)

    backend_opts =
      []
      |> maybe_put(:base_url, Keyword.get(opts, :base_url))

    system =
      Keyword.get(
        opts,
        :system,
        "You are a helpful assistant running in a terminal at the user's " <>
          "current working directory. Use the available tools to inspect " <>
          "files when the question is about them. Be concise."
      )

    write? = Keyword.get(opts, :write, false)

    [
      executor: executor,
      backend_opts: backend_opts,
      system_prompt: system,
      actions: actions_for(write?)
    ] ++ context_for(write?)
  end

  # Read-only by default (fs read tools + grep/glob). `--write` adds the
  # mutating coding tools (write_file/edit_file/bash), which are `sensitive`
  # and denied under the default policy — so it also installs an allow-all
  # authorizer to actually let them run in this unattended headless flow.
  defp actions_for(false),
    do: Raxol.Agent.Actions.Fs.all() ++ Raxol.Agent.Actions.Code.read_only()

  defp actions_for(true),
    do: Raxol.Agent.Actions.Fs.all() ++ Raxol.Agent.Actions.Code.all()

  defp context_for(false), do: []

  defp context_for(true),
    do: [context: %{tool_authorizer: Raxol.Agent.ToolPolicy.allow_all()}]

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  # -- Event consumption: contract events in, stdout/stderr out --------------

  defp consume(session_id, runner, timeout_ms, state) do
    receive do
      {:session_event, ^session_id, %Contract.Event{} = event} ->
        IO.write(:stderr, Contract.encode_line(event))
        state = render_stdout(event, state)

        case event do
          %{type: :turn_completed, payload: %{final: true}} ->
            Task.await(runner, 5_000)
            if state.wrote_stdout, do: IO.write("\n")
            0

          %{type: :error} ->
            Task.await(runner, 5_000)
            1

          _ ->
            consume(session_id, runner, timeout_ms, state)
        end
    after
      timeout_ms ->
        IO.puts(:stderr, ~s({"type":"error","payload":{"reason":"timeout"}}))
        Task.shutdown(runner, :brutal_kill)
        2
    end
  end

  # stdout carries the ANSWER only. Stream deltas as they arrive; if the
  # run produced no deltas (non-streaming react loop), print the final
  # message content once.
  defp render_stdout(%{type: :item_delta, payload: %{chunk: chunk}}, state) do
    IO.write(chunk)
    %{state | wrote_stdout: true}
  end

  defp render_stdout(
         %{
           type: :item_completed,
           payload: %{item_type: :message, content: content}
         },
         %{wrote_stdout: false} = state
       ) do
    IO.write(content)
    %{state | wrote_stdout: true}
  end

  defp render_stdout(_event, state), do: state
end
