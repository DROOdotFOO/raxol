defmodule Mix.Tasks.Raxol.Playground do
  @shortdoc "Launch the Raxol component playground"
  @moduledoc """
  Interactive terminal playground for browsing Raxol widgets.

      $ mix raxol.playground

  Browse components with j/k, select with Enter, Tab to switch between
  the sidebar and the live demo. Press c to view code snippets,
  / to search, q to quit.

  ## SSH mode

  Serve the playground over SSH so others can connect:

      $ mix raxol.playground --ssh
      $ mix raxol.playground --ssh --port 3333

  Then connect: `ssh localhost -p <port>`

  ## Options

    * `--ssh` - Serve over SSH instead of running in the current terminal
    * `--port` - SSH port (default: 2222, only with --ssh)
    * `--max-connections` - Max concurrent SSH connections (default: 50)
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [ssh: :boolean, port: :integer, max_connections: :integer],
        aliases: [p: :port]
      )

    Mix.Task.run("app.start")

    if opts[:ssh] do
      run_ssh(opts)
    else
      run_terminal()
    end
  end

  defp run_terminal do
    {:ok, pid} = Raxol.start_link(Raxol.Playground.App, mouse: false)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp run_ssh(opts) do
    port = Keyword.get(opts, :port, Raxol.Constants.default_ssh_port())
    max = Keyword.get(opts, :max_connections, 50)

    {:ok, pid} =
      Raxol.SSH.serve(Raxol.Playground.App,
        port: port,
        max_connections: max,
        # The playground is a public, read-only component catalog: anonymous
        # access is intended. Surfaces that reach payment Actions must not.
        allow_anonymous: true
      )

    ref = Process.monitor(pid)

    Mix.shell().info([
      :bright,
      "Raxol Playground SSH server listening on port #{port}",
      :reset,
      "\n",
      "Connect with: ssh localhost -p #{port}\n",
      "Press Ctrl+C to stop."
    ])

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end
end
