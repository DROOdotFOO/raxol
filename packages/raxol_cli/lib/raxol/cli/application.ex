defmodule Raxol.CLI.Application do
  @moduledoc """
  Release entrypoint for the `raxol` command.

  Started as the OTP `mod:` callback outside `:test`. All dependency apps (main
  raxol, raxol_agent) are already started by the time this runs -- raxol_cli sits
  at the top of the dependency graph -- so the CLI can use the terminal runtime
  and the agent immediately. The command runs in a supervised task (so the
  application controller is never blocked by the interactive loop) and halts the
  VM with the command's exit code when it returns.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Run the command synchronously here and halt. This deliberately blocks the
    # release boot: Burrito's launcher appends `-s elixir start_cli`, which runs
    # AFTER boot completes and would treat our argv as script filenames
    # ("No file named <arg>"). Blocking boot until we halt means it never runs.
    System.halt(Raxol.CLI.main(argv()))

    # Unreachable (System.halt does not return); start/2 must still return a spec.
    {:ok, self()}
  end

  # The npm launcher invokes the binary as `--no-halt -- <subcommand>`; Elixir's
  # boot CLI puts everything after `--` into System.argv, so read that first. Fall
  # back to the plain BEAM args (raw binary / `mix run`), stripping any leading
  # `--no-halt`/`--` a caller added.
  defp argv do
    case System.argv() do
      [] -> strip_prefix(plain_argv())
      argv -> strip_prefix(argv)
    end
  end

  defp plain_argv do
    if function_exported?(Burrito.Util.Args, :argv, 0) do
      Burrito.Util.Args.argv()
    else
      Enum.map(:init.get_plain_arguments(), &List.to_string/1)
    end
  end

  defp strip_prefix(["--no-halt" | rest]), do: strip_prefix(rest)
  defp strip_prefix(["--" | rest]), do: rest
  defp strip_prefix(other), do: other
end
