defmodule Raxol.CLI do
  @moduledoc """
  Argv dispatcher for the `raxol` command.

  Bare `raxol` (or `raxol agent`) opens an interactive AI agent session; the
  other subcommands expose the Raxol toolkit. The release entrypoint
  (`Raxol.CLI.Application`) reads the Burrito-wrapped argv and calls `main/1`,
  which returns the process exit code.
  """

  @commands ~w(agent code p acp login setup doctor playground new help)

  @doc "Dispatch `argv`, returning an exit code."
  @spec main([String.t()]) :: non_neg_integer()
  def main([]), do: run_agent([])
  def main(["agent" | rest]), do: run_agent(rest)
  # The full coding-agent TUI (approvals, plan mode, sessions, slash
  # commands) — the same launch path as `mix raxol.code`.
  def main(["code" | rest]), do: run_code(rest)
  # Headless one-shot: prompt on argv, answer to stdout, contract events to
  # stderr. `-p` matches the historical `bin/raxol -p` wrapper spelling.
  def main(["p" | rest]), do: Raxol.Agent.P.run(rest)
  def main(["-p" | rest]), do: Raxol.Agent.P.run(rest)
  # Serve over ACP on stdio, for editors and agent harnesses that spawn us.
  def main(["acp" | rest]), do: Raxol.Agent.ClientProtocol.Serve.run(rest)
  # The interactive setup an ACP client relaunches us for (Terminal Auth): the
  # args here are the ones `initialize` advertises, so the two cannot drift.
  def main(["login" | rest]), do: Raxol.Agent.ClientProtocol.Login.run(rest)
  # The headless twin of `login`, and the same code `mix raxol.setup` runs.
  # Reachable from the packaged binary because connecting a provider is the
  # first thing a fresh install needs, and an npm install has no Mix tasks.
  def main(["setup" | rest]),
    do: with_app(fn -> Raxol.Agent.Setup.CLI.run(rest) end)

  def main(["doctor" | rest]),
    do: with_app(fn -> Raxol.CLI.Doctor.run(rest) end)

  def main(["playground" | _rest]), do: run_playground()
  def main(["new" | rest]), do: Raxol.CLI.New.run(rest)
  def main([help]) when help in ~w(help --help -h), do: help()

  def main([unknown | _]) do
    IO.puts(:stderr, "raxol: unknown command #{inspect(unknown)}\n")
    help()
    1
  end

  # -- agent ------------------------------------------------------------------

  # An interactive, line-based chat loop: read a prompt, stream the reply, repeat.
  # Line-based stdio (not the full-screen terminal), so it works over a pipe and
  # needs no tty. `/exit` or EOF ends the session.
  defp run_agent(_args) do
    IO.puts(banner())
    mode = agent_mode()

    if mode == :mock do
      IO.puts(mock_mode_message())
    end

    loop([], mode)
    0
  end

  defp loop(history, mode) do
    case prompt() do
      :eof ->
        IO.puts("")
        :ok

      input when input in ~w(/exit /quit) ->
        :ok

      "" ->
        loop(history, mode)

      input ->
        messages = history ++ [%{role: "user", content: input}]
        reply = stream_reply(messages, input, mode)
        loop(messages ++ [%{role: "assistant", content: reply}], mode)
    end
  end

  defp prompt do
    case IO.gets("\n> ") do
      :eof -> :eof
      {:error, _} -> :eof
      data -> String.trim(data)
    end
  end

  # Stream one turn, printing text deltas live; returns the assembled reply text
  # (so the caller can keep conversation context).
  defp stream_reply(messages, input, mode) do
    messages
    |> Raxol.Agent.Stream.run(turn_opts(input, mode))
    |> Enum.reduce("", fn
      {:text_delta, chunk}, acc ->
        IO.write(chunk)
        acc <> chunk

      {:done, _result}, acc ->
        IO.write("\n")
        acc

      _other, acc ->
        acc
    end)
  rescue
    e ->
      IO.puts(:stderr, "\n[agent error] #{Exception.message(e)}")
      ""
  end

  # With credentials, resolve the same provider surface that setup/doctor report:
  # stored op refs, provider env vars, native subscriptions, then AI_API_KEY.
  # Without one, a Mock backend echoes so the session is still usable.
  defp turn_opts(_input, {:live, executor}), do: [executor: executor]

  defp turn_opts(input, :mock) do
    [
      backend: Raxol.Agent.Backend.Mock,
      backend_opts: [
        response:
          "(mock) Connect a provider for real replies. You said: #{input}"
      ]
    ]
  end

  defp agent_mode do
    resolver =
      Application.get_env(
        :raxol_cli,
        :agent_executor_resolver,
        &resolve_agent_executor/0
      )

    case resolver.() do
      {:ok, %Raxol.Agent.ExecutorConfig{} = executor} -> {:live, executor}
      _ -> :mock
    end
  end

  defp resolve_agent_executor do
    executor =
      [
        &auto_executor/0,
        &connected_provider_executor/0,
        &generic_executor/0
      ]
      |> Enum.find_value(& &1.())

    case executor do
      nil -> :error
      executor -> {:ok, executor}
    end
  end

  defp auto_executor do
    case Raxol.Agent.Backend.Resolver.resolve() do
      {:ok, executor, _source} -> executor
      _ -> nil
    end
  end

  defp connected_provider_executor do
    Raxol.Agent.Setup.status().providers
    |> Enum.find_value(fn
      %{available?: true, harness: harness} -> explicit_executor(harness)
      _ -> nil
    end)
  end

  defp explicit_executor(harness) do
    case Raxol.Agent.Backend.Resolver.resolve(harness: harness) do
      {:ok, executor, _source} -> executor
      _ -> nil
    end
  end

  defp generic_executor do
    case System.get_env("AI_API_KEY") do
      key when is_binary(key) and key != "" ->
        [
          harness: :openai,
          api_key: key,
          base_url: System.get_env("AI_BASE_URL"),
          model: System.get_env("AI_MODEL")
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Raxol.Agent.Backend.Resolver.resolve()
        |> case do
          {:ok, executor, _source} -> executor
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp mock_mode_message do
    """
    No provider connected. Mock mode is active.

    Connect:
      raxol login openrouter
      raxol setup --provider anthropic --op op://Vault/Item/api_key

    Try anyway:
      type a prompt, or /exit
    """
  end

  # -- code -------------------------------------------------------------------

  # The fullscreen coding harness. The shared launcher owns flags, provider
  # resolution, and the session store. The local TUI boot vetoes when there
  # is no real terminal (the TUI needs one); `--ssh` serving renders on the
  # remote client, so it boots without that check. `--help`/`--sessions` are
  # answered by the launcher before either boot runs.
  defp run_code(args) do
    boot = if "--ssh" in args, do: &serve_boot/0, else: &code_boot/0
    Raxol.Agent.Code.Launcher.main(args, boot: boot)
  end

  defp code_boot do
    if interactive?() do
      serve_boot()
    else
      {:error, "raxol code requires an interactive terminal."}
    end
  end

  defp serve_boot do
    {:ok, _} = Application.ensure_all_started(:raxol_agent)
    :ok
  end

  # Subcommands that only need the agent application up (no terminal, no
  # launcher): start it, then run. Both of these resolve providers, which
  # reaches `Raxol.Agent.Backend.Resolver` and may shell out to `op`.
  defp with_app(fun) do
    {:ok, _} = Application.ensure_all_started(:raxol_agent)
    fun.()
  end

  # -- playground -------------------------------------------------------------

  # Start the interactive component-catalog TUI. Needs a real terminal; over a
  # pipe it exits with a clear message rather than a crash.
  defp run_playground do
    if interactive?() do
      {:ok, _pid} = Raxol.start_link(Raxol.Playground.App, mouse: false)

      receive do
        :playground_done -> :ok
      end

      0
    else
      IO.puts(:stderr, "raxol playground requires an interactive terminal.")
      1
    end
  end

  # Is there a terminal for a full-screen TUI to draw on?
  #
  # Two different questions, because the packaged binary and a source run do not
  # present stdio the same way.
  #
  # Under Burrito the answer CANNOT come from the group leader. Its launcher
  # spawns the BEAM with stdout on a pipe so it can notice a downstream consumer
  # going away (`app cmd | head -5`), which makes `:io.getopts()` report a
  # non-terminal on every run, tty or not. Asking it there vetoes `raxol code`
  # and `raxol playground` unconditionally -- the packaged binary could never
  # open either one. Stdin is left inherited, so that is where the real answer
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
      agent         Interactive AI agent session (default)
      code          Full coding-agent TUI: gated tools, plan mode, sessions
      p "prompt"    Headless one-shot: answer to stdout, events to stderr
      acp           Serve over the Agent Client Protocol on stdio
      login         Connect an LLM provider (browser sign-in, or a key)
      setup         Connect/inspect a provider headlessly (CI, remote boxes)
      doctor        Report this install: build, runtime, providers, config
      playground    Browse the interactive component catalog
      new [name]    Scaffold an Elixir/Mix Raxol application
      help          Show this help

    Run `raxol` with no command to start the agent.
    """)

    0
  end

  defp banner, do: "raxol #{version()} -- terminal AI agent + TUI toolkit"

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

  @build_sha (case System.cmd("git", ["rev-parse", "--short", "HEAD"],
                     stderr_to_stdout: true
                   ) do
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
