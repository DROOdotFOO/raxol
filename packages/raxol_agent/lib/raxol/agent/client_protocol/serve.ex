defmodule Raxol.Agent.ClientProtocol.Serve do
  @moduledoc """
  `raxol acp`: serve a Raxol agent over [ACP](https://agentclientprotocol.com)
  on this process's own stdio, for an editor that spawns its agents.

      raxol acp --agent <app>[:<id>]

  `<app>` is one of `config :raxol_agent, :mcp_spawnable_apps`; each
  `session/new` starts it in this BEAM (see
  `Raxol.Agent.ClientProtocol.StdioAgent`). With `<id>` the agent's journal
  continues across runs; its state starts fresh every time. Without
  `--agent` the wire still opens and `initialize` answers, and `session/new`
  is refused with the list of apps.

  stdout carries newline-delimited JSON-RPC and nothing else: logs are moved
  to stderr before the transport starts. The agents this connection started
  are stopped when it ends, so their journals are flushed before the caller
  halts the VM.

  `RAXOL_MAX_TURNS` and `RAXOL_MAX_COST_USD` cap the turns started and the
  spend reported on the connection (see
  `Raxol.Agent.ClientProtocol.Budget`).

  Exit codes: 0 when the peer disconnects, 64 for a usage error or a
  malformed cap, 1 for a build without ACP or a connection that ended
  abnormally.
  """

  @compile {:no_warn_undefined,
            [
              Raxol.AgentClientProtocol.Transport.Stdio,
              Raxol.AgentClientProtocol.Agent,
              Raxol.Agent.ClientProtocol.StdioAgent
            ]}

  alias Raxol.Agent.ClientProtocol.Budget
  alias Raxol.Agent.ClientProtocol.ParentWatch

  @acp_agent Raxol.AgentClientProtocol.Agent
  @handler Raxol.Agent.ClientProtocol.StdioAgent
  @stdio Raxol.AgentClientProtocol.Transport.Stdio

  @switches [agent: :string, help: :boolean]
  @aliases [h: :help]

  @usage """
  Usage: raxol acp [--agent <app>[:<id>]]

  Serve a Raxol agent over the Agent Client Protocol on stdio, for editors
  that speak ACP (such as Zed).

  Options:
    --agent APP[:ID]  the app each session starts, and the id its journal
                      continues under (a new id per session if omitted)
    -h, --help        print this help
  """

  @typedoc "The agent `--agent` names: an app name and, optionally, an id."
  @type agent :: %{app: String.t(), id: String.t() | nil}

  @doc "Parse `argv` and serve until the peer disconnects. Returns the exit code."
  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, [], []} -> run_parsed(opts)
      {_opts, rest, invalid} -> usage_error("unknown arguments #{unknown(rest, invalid)}")
    end
  end

  defp run_parsed(opts) do
    cond do
      Keyword.get(opts, :help, false) ->
        IO.puts(@usage)
        0

      not available?() ->
        IO.puts(
          :stderr,
          "raxol acp: this build has no ACP support: raxol_agent was compiled " <>
            "without raxol_agent_client_protocol"
        )

        1

      true ->
        serve_named(Keyword.get(opts, :agent))
    end
  end

  defp serve_named(spec) do
    case parse_agent(spec) do
      {:ok, agent} -> serve(agent)
      {:error, message} -> usage_error(message)
    end
  end

  defp unknown(rest, invalid),
    do: Enum.join(Enum.map(invalid, &elem(&1, 0)) ++ rest, " ")

  defp usage_error(message) do
    IO.puts(:stderr, "raxol acp: #{message}\n\n#{@usage}")
    64
  end

  @doc "True when this build compiled the ACP agent surface."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(@acp_agent) and Code.ensure_loaded?(@handler)

  @doc """
  Parse the value of `--agent`: `<app>` or `<app>:<id>`. `nil` (no
  `--agent`) is `{:ok, nil}`. Whether the app may start and the id is
  well-formed is decided when a session starts it.
  """
  @spec parse_agent(String.t() | nil) :: {:ok, agent() | nil} | {:error, String.t()}
  def parse_agent(nil), do: {:ok, nil}

  def parse_agent(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [app] when app != "" -> {:ok, %{app: app, id: nil}}
      [app, id] when app != "" and id != "" -> {:ok, %{app: app, id: id}}
      _other -> {:error, "--agent takes <app> or <app>:<id>, got #{inspect(spec)}"}
    end
  end

  defp serve(agent) do
    # This process's stdio is the wire, not a terminal.
    System.put_env("RAXOL_SKIP_TERMINAL_INIT", "true")
    reroute_logs_to_stderr()
    {:ok, _apps} = Application.ensure_all_started(:raxol_agent)

    # A cap that cannot be read refuses to serve: it was set so that nobody
    # has to watch.
    case Budget.start_link() do
      {:error, message} -> usage_error(message)
      {:ok, budget} -> serve_stdio(agent, budget)
      :ignore -> serve_stdio(agent, nil)
    end
  end

  defp serve_stdio(agent, budget) do
    # Burrito's launcher forwards no signal: a client that kills only the
    # launcher would leave this BEAM running with stdin open.
    ParentWatch.start_link([])
    {:ok, handle} = @stdio.start_self()
    serve_connection({@stdio, handle}, %{agent: agent, budget: budget})
  end

  @doc """
  Serve one connection with `handler_arg` (see
  `Raxol.Agent.ClientProtocol.StdioAgent`) and return its exit code, after
  stopping the agents the connection started.

  The connection's supervisor is linked and exits `:shutdown` when the
  connection ends, whatever the reason; the connection's own exit reason
  decides the code.
  """
  @spec serve_connection(term(), map()) :: non_neg_integer()
  def serve_connection(transport, handler_arg) do
    Process.flag(:trap_exit, true)

    {:ok, sup} = @acp_agent.start_link(@handler, transport: transport, handler_arg: handler_arg)
    conn = connection(sup)
    ref = if conn, do: Process.monitor(conn)

    reason = await_shutdown(sup, ref)
    if conn, do: @handler.stop_agents(conn)
    exit_code(reason)
  end

  defp connection(sup) do
    case @acp_agent.connection(sup) do
      {:ok, pid} -> pid
      _error -> nil
    end
  end

  defp await_shutdown(sup, ref, reason \\ :normal) do
    receive do
      {:DOWN, ^ref, :process, _pid, down_reason} -> await_shutdown(sup, ref, down_reason)
      {:EXIT, ^sup, _sup_reason} -> collect_down(ref, reason)
    end
  end

  # The connection goes down before its supervisor, but the two signals come
  # from different processes: take a DOWN that has already landed.
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
    IO.puts(:stderr, "raxol acp: connection ended abnormally: #{inspect(reason)}")
    1
  end

  @doc """
  Bind the default log handler to stderr, keeping stdout clear for the wire.

  `logger_std_h` refuses a change of `:type` at runtime, so the handler is
  removed and added again with the rest of its config.
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
