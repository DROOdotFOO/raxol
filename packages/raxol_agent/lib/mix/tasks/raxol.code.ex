defmodule Mix.Tasks.Raxol.Code do
  @shortdoc "Interactive coding agent TUI (the axol face ≡··≡)"

  @moduledoc """
  An interactive, multi-turn coding assistant in the terminal — the
  `mix raxol.code` surface, wearing the axol face `≡··≡`.

      mix raxol.code
      mix raxol.code --harness anthropic --model claude-sonnet-5
      mix raxol.code --ascii            # ASCII-only face for legacy terminals

  It boots `Raxol.Agent.Code.App`, a TEA app that owns a coding loop over
  the harness contract: type a prompt, watch the agent stream reasoning,
  read files, and (with your per-call approval) write files and run shell
  commands scoped to the current working directory.

  ## Keys

    * type + Enter — send a prompt
    * `y` / `n`     — answer a tool-approval prompt
    * Esc           — deny a pending approval, else interrupt the turn
    * Ctrl+C        — quit

  ## Options

    * `--harness`  — backend harness atom (default `lm_studio`; also
      `anthropic`, `openai`, `ollama`, ... see `Backend.Selector`)
    * `--model`    — model override
    * `--base-url` — override the backend base URL
    * `--system`   — system prompt override
    * `--ascii`    — ASCII-only face (no `≡`/`·`)
  """

  use Mix.Task

  @switches [
    harness: :string,
    model: :string,
    base_url: :string,
    system: :string,
    ascii: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)

    case invalid do
      [] -> launch(opts)
      _ -> usage_error("unknown options: #{inspect(invalid)}")
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
    |> Keyword.put(:ascii, Keyword.get(opts, :ascii, false))
  end

  defp build_executor(opts) do
    harness_name = Keyword.get(opts, :harness, "lm_studio")
    supported = Raxol.Agent.Backend.Selector.supported_harnesses()

    harness =
      Enum.find(supported, &(Atom.to_string(&1) == harness_name)) ||
        usage_error(
          "unknown harness #{inspect(harness_name)}; supported: " <>
            Enum.map_join(supported, ", ", &Atom.to_string/1)
        )

    attrs =
      [harness: harness]
      |> maybe_put(:model, Keyword.get(opts, :model))

    Raxol.Agent.ExecutorConfig.new(attrs)
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
