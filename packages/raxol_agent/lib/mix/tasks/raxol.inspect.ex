defmodule Mix.Tasks.Raxol.Inspect do
  @shortdoc "Show every config source the coding agent will use here"

  @moduledoc """
  Print one snapshot of everything `mix raxol.code` / `mix raxol.p` will
  discover in the current directory:

    * provider resolution, per provider, with the source it would resolve
      from (op:// reference, env var) and an actionable note when it cannot;
    * the `.raxol/config.json` per-repo provider/model pin;
    * `.raxol/hooks.json` rules (the actual matchers and commands);
    * `.mcp.json` servers (env variable *names* only, never values);
    * skills provider and roots, with per-root skill counts;
    * the session store location, count, and latest session.

      mix raxol.inspect
      mix raxol.inspect --json

  The directory inspected is the agent workspace (`RAXOL_CLI_CWD` when the
  `bin/` shims set it, else the current directory), the same resolution the
  coding agent itself uses. The TUI's `/inspect` shows the same snapshot.

  ## Options

    * `--json`     — machine-readable output (one JSON object)
    * `-h`/`--help` — print usage and exit
  """

  use Mix.Task

  alias Raxol.Agent.Code.Inspection

  @switches [json: :boolean, help: :boolean]
  @aliases [h: :help]

  @usage """
  Usage: mix raxol.inspect [--json]

  Show every config source the coding agent will use in this directory:
  provider resolution, the .raxol/config.json pin, hooks, MCP servers,
  skills roots, and the session store.

  Options:
    --json           machine-readable output (one JSON object)
    -h, --help       print this help

  Full docs: mix help raxol.inspect
  """

  @impl Mix.Task
  def run(argv) do
    {opts, _args, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      Keyword.get(opts, :help, false) -> IO.puts(@usage)
      invalid != [] -> usage_error("unknown options: #{inspect(invalid)}")
      true -> print(Keyword.get(opts, :json, false))
    end
  end

  defp print(json?) do
    snapshot = Inspection.gather(Raxol.Agent.Actions.Fs.working_dir())

    if json? do
      IO.puts(Jason.encode!(snapshot))
    else
      IO.puts(Inspection.render(snapshot))
    end
  end

  defp usage_error(message) do
    IO.puts(:stderr, "raxol.inspect: #{message}\n\n#{@usage}")
    exit({:shutdown, 64})
  end
end
