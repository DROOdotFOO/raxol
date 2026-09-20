defmodule Mix.Tasks.Raxol.Repl do
  @shortdoc "Launch an interactive Elixir REPL in the terminal"
  @moduledoc """
  Interactive Elixir REPL powered by Raxol's terminal UI.

      $ mix raxol.repl

  Evaluates Elixir expressions with persistent bindings and IO capture.
  Variables defined in one expression are available in subsequent ones.

  ## Trust boundary

  This evaluates submitted code with the full authority of the node running
  it, and `Raxol.REPL.Sandbox` in front of it is a mitigation rather than a
  boundary. Running it here is safe only in the sense that YOU started it in
  YOUR terminal: the code runs as you, and you typed it.

  That is why this task passes `local_operator: true`, which
  `Raxol.Playground.Demos.ReplDemo` accepts only at `environment: :terminal`.
  Every other surface -- the web gallery, SSH, anything serving the catalog --
  needs the deployment to opt in explicitly
  (`RAXOL_REPL_EXPOSED=true` or `config :raxol_core, :repl_exposed, true`), and
  a node that holds signing keys refuses to boot with that set.

  ## Options

    * `--sandbox` - Safety level: `none`, `standard` (default), `strict`
    * `--timeout` - Eval timeout in milliseconds (default: 5000)
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [sandbox: :string, timeout: :integer],
        aliases: [s: :sandbox, t: :timeout]
      )

    Mix.Task.run("app.start")

    sandbox =
      case opts[:sandbox] do
        "none" -> :none
        "strict" -> :strict
        _ -> :standard
      end

    timeout = Keyword.get(opts, :timeout, Raxol.Core.Defaults.timeout_ms())

    Application.put_env(:raxol, :repl_sandbox, sandbox)
    Application.put_env(:raxol, :repl_timeout, timeout)

    {:ok, pid} =
      Raxol.start_link(Raxol.Playground.Demos.ReplDemo, local_operator: true)

    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end
end
