defmodule Raxol.Agent.ClientProtocol.Serve do
  @moduledoc """
  Serve the coding agent over [ACP](https://agentclientprotocol.com) on this
  process's own stdio.

  The release-safe half of the ACP surface: this module makes no Mix calls, so
  the Burrito-packaged `raxol acp` and the `mix raxol.acp` boot shim run the
  same code — the same split as `Raxol.Agent.P` and `mix raxol.p`. Option
  parsing, `--help`, provider resolution, and every exit code live here, so the
  two entrypoints cannot disagree.

  stdout carries newline-delimited JSON-RPC and nothing else. Logs are rerouted
  to stderr before the transport binds, because on this surface a single stray
  line is a protocol parse error at the client.

  Turns run the read-only toolset — see `Raxol.Agent.ClientProtocol.StdioAgent`.
  """

  @compile {:no_warn_undefined,
            [
              Raxol.AgentClientProtocol.Transport.Stdio,
              Raxol.AgentClientProtocol.Agent,
              Raxol.Agent.ClientProtocol.StdioAgent
            ]}

  @switches [backend: :string, harness: :string, model: :string, help: :boolean]
  @aliases [h: :help]

  @usage """
  Usage: raxol acp [options]

  Serve the coding agent over the Agent Client Protocol on stdio
  (for ACP-speaking editors such as Zed).

  Options:
    --backend NAME   LLM backend (auto-detected if omitted; --harness is a
                     deprecated alias)
    --model NAME     model override
    -h, --help       print this help
  """

  @doc """
  Parse `argv` and serve until the peer disconnects, returning an exit code.

  A clean disconnect is 0. The non-zero paths are a usage error (64), an
  unavailable ACP build (1), an unresolved provider (1), and a connection that
  ended abnormally (1).
  """
  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    {opts, _args, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      Keyword.get(opts, :help, false) ->
        IO.puts(@usage)
        0

      invalid != [] ->
        IO.puts(
          :stderr,
          "raxol acp: unknown options: #{inspect(invalid)}\n\n#{@usage}"
        )

        64

      not available?() ->
        IO.puts(
          :stderr,
          "raxol acp: this build has no ACP support. The protocol package " <>
            "(raxol_agent_client_protocol) is unpublished, so a Hex install of " <>
            "raxol_agent is compiled without it; build from the raxol repo."
        )

        1

      true ->
        serve(opts)
    end
  end

  @doc "True when this build compiled the ACP agent surface."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(Raxol.Agent.ClientProtocol.TurnRunner) and
      Raxol.Agent.ClientProtocol.TurnRunner.available?() and
      Code.ensure_loaded?(Raxol.Agent.ClientProtocol.StdioAgent)
  end

  # Provider first: a config problem exits before anything binds stdio, so a
  # misconfigured agent fails loudly instead of opening a wire it cannot serve.
  defp serve(opts) do
    case Raxol.Agent.Backend.Cli.resolve_executor(opts, nil) do
      {:error, message} ->
        IO.puts(:stderr, "raxol acp: #{message}")
        1

      {:ok, executor, _source} ->
        start_serving(executor)
    end
  end

  defp start_serving(executor) do
    # No terminal driver: this process's stdio is the protocol wire, not a UI.
    System.put_env("RAXOL_SKIP_TERMINAL_INIT", "true")
    reroute_logs_to_stderr()
    {:ok, _apps} = Application.ensure_all_started(:raxol_agent)

    {:ok, handle} = Raxol.AgentClientProtocol.Transport.Stdio.start_self()

    serve_connection(
      {Raxol.AgentClientProtocol.Transport.Stdio, handle},
      %{turn_opts: turn_opts(executor)}
    )
  end

  @doc false
  # Serve one connection and return its exit code.
  #
  # On peer disconnect the transport reports {:closed, _}, the Connection stops
  # :normal, and the supervisor -- one_for_all with auto_shutdown:
  # :any_significant over a significant Connection child -- exits :shutdown into
  # the link `start_link` just made. Trapping turns that into a message we can
  # answer with an exit code. Blocking instead got both callers wrong: the mix
  # task died OF the linked exit (stderr "** (EXIT ...)", status 1 on a CLEAN
  # disconnect), and the packaged binary, whose caller is OTP's
  # application-master starter and therefore already trapping, ignored it and
  # parked forever -- one resident BEAM per editor session holding the provider
  # key, which Burrito's launcher cannot signal away.
  @spec serve_connection(term(), map()) :: non_neg_integer()
  def serve_connection(transport, handler_arg) do
    Process.flag(:trap_exit, true)

    {:ok, sup} =
      Raxol.AgentClientProtocol.Agent.start_link(
        Raxol.Agent.ClientProtocol.StdioAgent,
        transport: transport,
        handler_arg: handler_arg
      )

    await_shutdown(sup, monitor_connection(sup))
  end

  # OTP folds every significant-child exit into one :shutdown at the
  # supervisor, so the supervisor's own reason cannot tell a clean disconnect
  # from a crash. The Connection's DOWN carries the real one.
  defp monitor_connection(sup) do
    case Raxol.AgentClientProtocol.Agent.connection(sup) do
      {:ok, pid} -> Process.monitor(pid)
      _ -> nil
    end
  end

  defp await_shutdown(sup, ref, reason \\ :normal) do
    receive do
      {:DOWN, ^ref, :process, _pid, down_reason} ->
        await_shutdown(sup, ref, down_reason)

      {:EXIT, ^sup, _sup_reason} ->
        exit_code(collect_down(ref, reason))
    end
  end

  # The Connection dies before the supervisor it brings down, but the two
  # signals come from different processes, so take a DOWN that has already
  # landed rather than assuming they arrive in that order.
  defp collect_down(nil, reason), do: reason

  defp collect_down(ref, reason) do
    receive do
      {:DOWN, ^ref, :process, _pid, down_reason} -> down_reason
    after
      0 -> reason
    end
  end

  defp exit_code(reason) when reason in [:normal, :shutdown], do: 0
  defp exit_code({:shutdown, _}), do: 0

  defp exit_code(reason) do
    IO.puts(
      :stderr,
      "raxol acp: connection ended abnormally: #{inspect(reason)}"
    )

    1
  end

  # Read-only toolset, matching the StdioAgent contract.
  defp turn_opts(executor) do
    [
      executor: executor,
      actions:
        Raxol.Agent.Actions.Fs.all() ++ Raxol.Agent.Actions.Code.read_only(),
      system_prompt:
        "You are a coding assistant driven by an editor over ACP. Use the " <>
          "available read-only tools to inspect files. Be concise."
    ]
  end

  @doc """
  Bind the default log handler to stderr, keeping stdout clear for the wire.

  `update_handler_config(:config, ...)` is rejected by `logger_std_h` as an
  illegal runtime type change, so the handler has to be removed and re-added.
  The existing config is carried across so Elixir's formatter and level
  survive: re-adding a bare `logger_std_h` would keep stdout clean but reduce
  every stderr log line to Erlang's default format.
  """
  @spec reroute_logs_to_stderr() :: :ok
  def reroute_logs_to_stderr do
    case :logger.get_handler_config(:default) do
      {:ok, %{module: module} = config} ->
        _ = :logger.remove_handler(:default)

        rebound =
          config
          |> Map.drop([:id, :module])
          |> Map.put(:config, %{type: :standard_error})

        _ = :logger.add_handler(:default, module, rebound)

      _ ->
        _ =
          :logger.add_handler(:default, :logger_std_h, %{
            config: %{type: :standard_error}
          })
    end

    :ok
  end
end
