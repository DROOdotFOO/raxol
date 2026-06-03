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
      mix raxol.symphony --ssh
      mix raxol.symphony --ssh --port 2223

  ## Options

  - `--workflow PATH` (default `./WORKFLOW.md`) -- workflow file
  - `--headless` -- skip the TUI and run orchestrator-only
  - `--no-watch` -- disable file-system hot-reload of the workflow
  - `--ssh` -- serve the dashboard over SSH instead of in this terminal.
    The orchestrator still boots locally; each SSH connection gets its
    own Lifecycle reading the same orchestrator snapshot.
  - `--port N` (default `2223`) -- SSH port (only honored with `--ssh`)
  - `--max-connections N` (default `50`) -- max concurrent SSH connections

  Exits with `0` on clean shutdown (Ctrl+C, dashboard quit) and `1` on
  startup failure (workflow missing, validation failed, SSH bind failure).
  """

  use Mix.Task

  alias Raxol.Symphony.CLI

  @default_ssh_port 2223
  @default_max_connections 50

  @switches [
    workflow: :string,
    headless: :boolean,
    watch: :boolean,
    ssh: :boolean,
    port: :integer,
    max_connections: :integer
  ]
  @aliases [w: :workflow, p: :port]

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

    cli_opts =
      if Keyword.get(opts, :ssh, false) do
        [
          {:ssh,
           port: Keyword.get(opts, :port, @default_ssh_port),
           max_connections: Keyword.get(opts, :max_connections, @default_max_connections)}
          | cli_opts
        ]
      else
        cli_opts
      end

    case CLI.run(cli_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.shell().error("symphony failed to start: #{format_error(reason)}")
        System.halt(1)
    end
  end

  defp format_error(:ssh_unavailable),
    do: "--ssh requires the optional :raxol dependency (Raxol.SSH not available)"

  defp format_error(other), do: inspect(other)
end
