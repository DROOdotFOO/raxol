defmodule Mix.Tasks.Raxol.Repl do
  @shortdoc "Launch an interactive Elixir REPL in the terminal"
  @moduledoc """
  Interactive Elixir REPL powered by Raxol's terminal UI.

      $ mix raxol.repl

  Evaluates Elixir expressions with persistent bindings, IO capture, an AST
  safety check applied before each evaluation, and per-evaluation resource
  caps. Variables defined in one expression are available in subsequent ones.

  ## Trust boundary

  This evaluates submitted code with the full authority of the node running
  it, and `Raxol.REPL.Sandbox` in front of it is a mitigation rather than a
  boundary. Running it here is safe only in the sense that YOU started it in
  YOUR terminal: the code runs as you, and you typed it.

  That is why this task passes `local_operator: true`, which
  `Raxol.Playground.Demos.ReplDemo` accepts only at `environment: :terminal`.
  It is also what makes `--sandbox` and `--timeout` take effect: a served
  launch ignores both. Every other surface, the web gallery, SSH, anything
  serving the catalog, needs the deployment to opt in explicitly
  (`RAXOL_REPL_EXPOSED=true` or `config :raxol_core, :repl_exposed, true`), and
  a node that holds signing keys refuses to boot with that set.

  ## Options

    * `--sandbox` - Safety level: `none`, `standard`, `strict` (default)
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

    # Only the options the operator actually gave are passed, so a bare
    # `mix raxol.repl` inherits ReplDemo's own defaults rather than restating
    # them here. An unrecognised `--sandbox` value aborts instead of quietly
    # picking a level: the operator asked for something specific.
    start_opts =
      [local_operator: true]
      |> put_given(:sandbox, opts[:sandbox] && sandbox_level!(opts[:sandbox]))
      |> put_given(:timeout, opts[:timeout])

    # Passed as start options rather than application env: they reach
    # `ReplDemo.init/1` through the runtime's context map, so they configure
    # THIS terminal's REPL and nothing else in the VM. `--sandbox none` on a
    # developer's machine must not lower the level of a playground the same
    # node may be serving over SSH.
    {:ok, pid} = Raxol.start_link(Raxol.Playground.Demos.ReplDemo, start_opts)

    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp put_given(opts, _key, nil), do: opts
  defp put_given(opts, key, value), do: Keyword.put(opts, key, value)

  defp sandbox_level!("none"), do: :none
  defp sandbox_level!("standard"), do: :standard
  defp sandbox_level!("strict"), do: :strict

  defp sandbox_level!(other) do
    Mix.raise(
      "unknown --sandbox level #{inspect(other)}; expected none, standard, or strict"
    )
  end
end
