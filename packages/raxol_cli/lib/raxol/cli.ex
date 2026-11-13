defmodule Raxol.CLI do
  @moduledoc """
  Argv dispatcher for the `raxol` command.

  Bare `raxol` prints the help; the subcommands expose the Raxol toolkit. The
  release entrypoint (`Raxol.CLI.Application`) reads the Burrito-wrapped argv
  and calls `main/1`, which returns the process exit code.
  """

  @commands ~w(acp mcp doctor update playground new help)

  @doc """
  Dispatch `argv`, returning an exit code.

  A VM booted for `raxol mcp` (`config/runtime.exs`, e.g. `RAXOL_MODE=mcp`
  left exported) runs nothing else: its stray output goes to stderr and its
  apps start in MCP mode, so any other command is refused with exit 1.
  """
  @spec main([String.t()]) :: non_neg_integer()
  def main(argv) do
    if Application.get_env(:raxol_cli, :mcp_boot, false) and not match?(["mcp" | _], argv) do
      IO.puts(:stderr, "raxol: this VM booted for `raxol mcp` (RAXOL_MODE=mcp?); only mcp runs")
      1
    else
      dispatch(argv)
    end
  end

  defp dispatch([]), do: help()
  # Serve a Raxol agent over ACP on stdio, for editors that spawn us.
  defp dispatch(["acp" | rest]), do: Raxol.Agent.ClientProtocol.Serve.run(rest)
  # Serve Raxol apps as MCP tools on stdio, for OMP and other MCP clients.
  defp dispatch(["mcp" | rest]), do: Raxol.CLI.MCP.run(rest)
  defp dispatch(["doctor" | rest]), do: Raxol.CLI.Doctor.run(rest)

  defp dispatch(["update" | rest]), do: Raxol.CLI.Update.run(rest)
  defp dispatch(["playground" | _rest]), do: run_playground()
  defp dispatch(["new" | rest]), do: Raxol.CLI.New.run(rest)

  defp dispatch(["--version"]) do
    IO.puts("raxol #{version()}")
    0
  end

  defp dispatch([help]) when help in ~w(help --help -h), do: help()

  defp dispatch([unknown | _]) do
    IO.puts(:stderr, "raxol: unknown command #{inspect(unknown)}\n")
    help()
    1
  end

  # -- playground -------------------------------------------------------------

  # Start the interactive component-catalog TUI. Needs a real terminal; over a
  # pipe it exits with a clear message rather than a crash.
  defp run_playground do
    cond do
      !interactive?() ->
        IO.puts(:stderr, "raxol playground requires an interactive terminal.")
        1

      auto_update_prompt() == :updated ->
        0

      true ->
        {:ok, _pid} = Raxol.start_link(Raxol.Playground.App, mouse: false)

        receive do
          :playground_done -> :ok
        end

        0
    end
  end

  defp auto_update_prompt do
    Raxol.CLI.Update.auto_prompt(prompt?: interactive?(false))
  end

  # Is there a terminal for a full-screen TUI to draw on?
  #
  # Two different questions, because the packaged binary and a source run do not
  # present stdio the same way.
  #
  # Under Burrito the answer CANNOT come from the group leader. Its launcher
  # spawns the BEAM with stdout on a pipe so it can notice a downstream consumer
  # going away (`app cmd | head -5`), which makes `:io.getopts()` report a
  # non-terminal on every run, tty or not. Asking it there vetoes
  # `raxol playground` unconditionally -- the packaged binary could never
  # open it. Stdin is left inherited, so that is where the real answer
  # lives, and it is the honest one: termbox2 opens /dev/tty directly
  # (`tb_init/0` is `tb_init_file("/dev/tty")`), so the TUI never draws through
  # the piped stdout anyway.
  #
  # Everywhere else keep reading the group leader. It is what `with_io/1` swaps,
  # which is what lets the veto be tested without a tty deciding the outcome.
  defp interactive?, do: interactive?(burrito?())

  @doc false
  # Split on the packaging so a test can pin the branch: the Burrito arm's
  # answer comes from the real stdin of the OS process, which a unit test
  # cannot pose either way.
  def interactive?(true), do: tty_stdin?()
  def interactive?(false), do: terminal_group_leader?()

  defp burrito?, do: System.get_env("__BURRITO") == "1"

  defp terminal_group_leader? do
    case :io.getopts() do
      opts when is_list(opts) -> Keyword.get(opts, :terminal, false) != false
      _ -> false
    end
  rescue
    _ -> false
  end

  defp tty_stdin? do
    Code.ensure_loaded?(:prim_tty) and
      function_exported?(:prim_tty, :isatty, 1) and
      :prim_tty.isatty(:stdin) == true
  rescue
    _ -> false
  end

  # -- help -------------------------------------------------------------------

  defp help do
    IO.puts(banner())

    IO.puts("""

    Usage: raxol [command]

    Commands:
      acp           Serve a Raxol agent over the Agent Client Protocol (--agent)
      mcp           Serve Raxol apps as MCP tools on stdio (for OMP)
      doctor        Report this install: build, runtime, ACP surface
      update        Update the installed binary from GitHub Releases
      playground    Browse the interactive component catalog
      new [name]    Scaffold an Elixir/Mix Raxol application
      help          Show this help

    Options:
      --version     Show the installed Raxol version
      -h, --help    Show this help
    """)

    0
  end

  defp banner, do: "raxol #{version()} -- TUI toolkit and agent runtime"

  # The commit this binary was built from, resolved at COMPILE time and baked
  # in. A packaged binary otherwise reports only its release version, which
  # changes far less often than its contents: a months-old build and a build
  # from five minutes ago both say "0.2.6", and the only way to tell them apart
  # is to diff their behaviour. (That is not hypothetical — a stale
  # `burrito_out` binary was found serving a pre-fix ACP handshake while
  # claiming the current version.)
  #
  # `@external_resource` on `.git/HEAD` recompiles this module when the commit
  # moves, so the stamp cannot go stale on its own.
  @git_head Path.join([__DIR__, "..", "..", "..", "..", ".git", "HEAD"])
  if File.exists?(@git_head), do: @external_resource(@git_head)

  @build_sha (case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
                {sha, 0} -> String.trim(sha)
                _ -> nil
              end)

  @doc false
  # Public so `Raxol.CLI.Doctor` reports the same string the banner does.
  @spec version() :: String.t()
  def version do
    case :application.get_key(:raxol_cli, :vsn) do
      {:ok, vsn} -> stamped(List.to_string(vsn))
      _ -> stamped("dev")
    end
  end

  # A build with no git available (a Hex install, a source tarball) reports the
  # bare version rather than inventing a provenance it does not have. Selected
  # at compile time: `@build_sha` is a constant, so a runtime guard on it would
  # leave one clause provably dead.
  if is_binary(@build_sha) do
    defp stamped(vsn), do: vsn <> "+" <> @build_sha
  else
    defp stamped(vsn), do: vsn
  end

  @doc false
  def commands, do: @commands
end
