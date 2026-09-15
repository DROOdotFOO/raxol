defmodule Mix.Tasks.Raxol.Repl do
  @shortdoc "Launch an interactive Elixir REPL in the terminal"
  @moduledoc """
  Interactive Elixir REPL powered by Raxol's terminal UI.

      $ mix raxol.repl

  Evaluates Elixir expressions with persistent bindings, IO capture, an AST
  safety check applied before each evaluation, and per-evaluation resource
  caps. Variables defined in one expression are available in subsequent ones.

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

    # Passed as start options rather than application env: they reach
    # `ReplDemo.init/1` through the runtime's context map, so they configure
    # THIS terminal's REPL and nothing else in the VM. `--sandbox none` on a
    # developer's machine must not lower the level of a playground the same
    # node may be serving over SSH.
    {:ok, pid} =
      Raxol.start_link(Raxol.Playground.Demos.ReplDemo,
        sandbox: sandbox,
        timeout: timeout
      )

    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end
end
