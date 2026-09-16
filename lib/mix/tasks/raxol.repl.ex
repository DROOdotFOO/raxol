defmodule Mix.Tasks.Raxol.Repl do
  @shortdoc "Launch an interactive Elixir REPL in the terminal"
  @moduledoc """
  Interactive Elixir REPL powered by Raxol's terminal UI.

      $ mix raxol.repl

  Evaluates Elixir expressions with persistent bindings, IO capture, an AST
  safety check applied before each evaluation, and per-evaluation resource
  caps. Variables defined in one expression are available in subsequent ones.

  ## Options

    * `--sandbox` - Safety level: `none`, `standard`, `strict` (default)
    * `--timeout` - Positive eval timeout in milliseconds (default: 5000)
  """

  use Mix.Task

  @switches [sandbox: :string, timeout: :integer]
  @aliases [s: :sandbox, t: :timeout]
  @sandbox_levels %{
    "none" => :none,
    "standard" => :standard,
    "strict" => :strict
  }

  @impl true
  def run(args) do
    opts = parse_options!(args)

    Mix.Task.run("app.start")

    # Passed as start options rather than application env: they reach
    # `ReplDemo.init/1` through the runtime's context map, so they configure
    # THIS terminal's REPL and nothing else in the VM. An explicit
    # `--sandbox none` on a developer's machine must not lower the level of a
    # playground the same node may be serving over SSH.
    {:ok, pid} =
      Raxol.start_link(Raxol.Playground.Demos.ReplDemo, opts)

    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  @doc false
  @spec parse_options!([String.t()]) :: keyword()
  def parse_options!(args) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {opts, [], []} ->
        [
          sandbox: parse_sandbox!(opts[:sandbox]),
          timeout: parse_timeout!(opts[:timeout])
        ]

      {_opts, positional, invalid} ->
        details =
          [invalid_options(invalid), positional_arguments(positional)]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("; ")

        Mix.raise("invalid raxol.repl options: #{details}")
    end
  end

  defp parse_sandbox!(nil), do: :strict

  defp parse_sandbox!(value) do
    Map.get(@sandbox_levels, value) ||
      Mix.raise(
        "invalid --sandbox value #{inspect(value)}; " <>
          "expected one of: none, standard, strict"
      )
  end

  defp parse_timeout!(nil), do: Raxol.Core.Defaults.timeout_ms()

  defp parse_timeout!(timeout) when is_integer(timeout) and timeout > 0,
    do: timeout

  defp parse_timeout!(timeout) do
    Mix.raise(
      "invalid --timeout value #{inspect(timeout)}; expected a positive integer"
    )
  end

  defp invalid_options([]), do: nil
  defp invalid_options(options), do: "unknown or malformed #{inspect(options)}"

  defp positional_arguments([]), do: nil

  defp positional_arguments(arguments),
    do: "unexpected positional arguments #{inspect(arguments)}"
end
