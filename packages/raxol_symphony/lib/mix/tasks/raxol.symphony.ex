defmodule Mix.Tasks.Raxol.Symphony do
  @shortdoc "Start the Symphony orchestrator and (optionally) the terminal dashboard"

  @moduledoc """
  Boots `Raxol.Symphony.Supervisor` from a `WORKFLOW.md` file and (by
  default) launches the terminal dashboard.

  ## Usage

      mix raxol.symphony
      mix raxol.symphony --workflow path/to/WORKFLOW.md
      mix raxol.symphony --headless
      mix raxol.symphony --no-watch

  ## Options

  - `--workflow PATH` (default `./WORKFLOW.md`) -- workflow file
  - `--headless` -- skip the TUI and run orchestrator-only
  - `--no-watch` -- disable file-system hot-reload of the workflow

  Exits with `0` on clean shutdown (Ctrl+C, dashboard quit) and `1` on
  startup failure (workflow missing, validation failed, etc.).
  """

  use Mix.Task

  alias Raxol.Symphony.CLI

  @switches [workflow: :string, headless: :boolean, watch: :boolean]
  @aliases [w: :workflow]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    Mix.Task.run("app.start")

    cli_opts =
      [
        workflow: Keyword.get(opts, :workflow, "./WORKFLOW.md"),
        headless: Keyword.get(opts, :headless, false),
        watch: Keyword.get(opts, :watch, true)
      ]

    case CLI.run(cli_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.shell().error("symphony failed to start: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
