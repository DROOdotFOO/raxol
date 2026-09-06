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

    * `--backend`  — LLM backend atom (`anthropic`, `openai`, `ollama`,
      `lm_studio`, ... see `Backend.Selector`). Auto-detected through
      `Raxol.Agent.Backend.Resolver` when omitted (stored `op://` reference,
      then provider env vars, then generic `AI_API_KEY`); with nothing
      configured the task exits 1 with a setup hint. `--harness` is accepted
      as a deprecated alias.
    * `--model`    — model override (LM Studio uses its loaded model)
    * `--base-url` — override the backend base URL
    * `--system`   — system prompt override
    * `--timeout`  — per-run timeout in seconds (default 180)
    * `--write`    — expose write_file/edit_file/bash (opt-in; unattended)
    * `--no-tools` — plain completion, no tool loop
    * `-h`/`--help` — print usage and exit

  ## Benchmark / harness env contract

  Unattended callers (benchmark harnesses, CI) configure the run via env
  instead of flags -- see `Raxol.Agent.BenchmarkProfile`:

      RAXOL_MODEL            provider/model (e.g. anthropic/claude-sonnet-4-6)
      RAXOL_PROFILE          "benchmark" (allow-all tools, skills off)
      RAXOL_MAX_TURNS        hard turn cap -> exit 2
      RAXOL_MAX_COST_USD     hard spend cap -> exit 2 (needs RAXOL_COST_PER_MTOK_IN/OUT)
      RAXOL_TRAJECTORY_PATH  trajectory JSON written on every exit path

  CLI flags win over env. SIGTERM flushes the trajectory, emits a final
  `error` event with reason `terminated`, and exits 143 -- a harness kill
  is never mistaken for success.

  ## Exit codes

  `0` success · `1` run or configuration error · `2` timeout or budget
  exhausted · `64` usage error · `143` terminated (SIGTERM)
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    # stdout is the answer channel, so nothing else may print there.
    # `Raxol.Agent.P` lowers the log level itself, but only once its run
    # starts -- the `app.start` below happens first and used to put the whole
    # boot banner ("Starting in full mode", the Endpoint config warning,
    # "Started in ...") on stdout, ahead of the answer. Measured through
    # bin/raxol by cli_entrypoint_smoke_test.exs.
    #
    # Seed :logger's own env rather than calling Logger.configure/1: app.start
    # reloads config and restarts :logger, which would undo a live change.
    # Level :error matches what the runner installs; the handler binds to
    # standard_error so what survives that level lands beside the JSONL event
    # stream instead of corrupting the answer. Mix.Shell.Quiet covers
    # app.start's own announcements.
    Application.put_env(:logger, :level, :error)
    Application.put_env(:logger, :default_handler, config: %{type: :standard_error})
    Mix.shell(Mix.Shell.Quiet)

    # Boot without recompiling (bin/raxol precompiles silently) so stdout
    # stays clean for the answer, then hand off to the shared runner --
    # `Raxol.Agent.P` contains no Mix calls, so the same code path serves
    # the Burrito-packaged `raxol p` where Mix does not exist. `--help`,
    # usage errors, and provider resolution are answered by the runner, so
    # every entrypoint agrees.
    Mix.Task.run("app.start", [
      "--no-compile",
      "--no-deps-check",
      "--no-archives-check",
      "--no-elixir-version-check"
    ])

    exit({:shutdown, Raxol.Agent.P.run(argv)})
  end
end
