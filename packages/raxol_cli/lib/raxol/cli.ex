defmodule Raxol.CLI do
  @moduledoc """
  Argv dispatcher for the `raxol` command.

  Bare `raxol` (or `raxol agent`) opens an interactive AI agent session; the
  other subcommands expose the Raxol toolkit. The release entrypoint
  (`Raxol.CLI.Application`) reads the Burrito-wrapped argv and calls `main/1`,
  which returns the process exit code.
  """

  @commands ~w(agent code p acp playground new help)

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
    mode = if credentials?(), do: :live, else: :mock

    if mode == :mock do
      IO.puts(
        "No AI credentials found (set AI_API_KEY or a provider key). " <>
          "Running with mock responses."
      )
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

  # With credentials, resolve a real provider (op-ref -> provider-env ->
  # AI_API_KEY). Without, a Mock backend echoes so the session is still usable.
  defp turn_opts(_input, :live), do: [auto_provider: true]

  defp turn_opts(input, :mock) do
    [
      backend: Raxol.Agent.Backend.Mock,
      backend_opts: [
        response: "(mock) Set AI_API_KEY for real replies. You said: #{input}"
      ]
    ]
  end

  defp credentials? do
    ~w(AI_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY)
    |> Enum.any?(&(System.get_env(&1) not in [nil, ""]))
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

  defp interactive? do
    case :io.getopts() do
      opts when is_list(opts) -> Keyword.get(opts, :terminal, false) != false
      _ -> false
    end
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
      playground    Browse the interactive component catalog
      new [name]    Scaffold a new Raxol application
      help          Show this help

    Run `raxol` with no command to start the agent.
    """)

    0
  end

  defp banner, do: "raxol #{version()} -- terminal AI agent + TUI toolkit"

  defp version do
    case :application.get_key(:raxol_cli, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "dev"
    end
  end

  @doc false
  def commands, do: @commands
end
