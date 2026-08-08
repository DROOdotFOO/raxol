# Compiled only when the ACP package is present (a dev/test path dep of
# raxol_agent; production embedders add :raxol_agent_client_protocol
# themselves). `use` injects the generated Agent behaviour, so a guard at
# call sites cannot substitute for this compile-time gate.
if Code.ensure_loaded?(Raxol.AgentClientProtocol.Agent) do
  defmodule Raxol.Agent.ClientProtocol.StdioAgent do
    @moduledoc """
    The coding agent as an ACP agent: the handler `mix raxol.acp` serves
    over stdio, so an ACP-speaking editor (Zed and its ecosystem) can spawn
    and drive Raxol's agent loop.

    Each `session/new` starts a `Raxol.AgentClientProtocol.Session` whose
    `:turn_runner` is `Raxol.Agent.ClientProtocol.TurnRunner` over the
    launcher-resolved executor; `session/prompt` defers to that session.
    Turns run the read-only toolset (read/grep/glob, no
    write_file/edit_file/bash): ACP's permission flow is not yet bridged to
    the authorization engine, and an unattended surface fails closed until
    it is — the same posture as the harness MCP tools.
    """

    use Raxol.AgentClientProtocol.Agent

    alias Raxol.Agent.ClientProtocol.TurnRunner
    alias Raxol.AgentClientProtocol.Error
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.Implementation
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse
    alias Raxol.AgentClientProtocol.Session

    # handler_arg = %{turn_opts: keyword} — executor and toolset resolved by
    # the launcher, once, before serving.
    @impl true
    def init(arg), do: {:ok, arg}

    # Identify ourselves in the handshake: clients and benchmark harnesses
    # record `agentInfo` as the agent under test, and a nil there is reported
    # as an unnamed agent.
    @impl true
    def initialize(_req, _ctx) do
      {:ok, %{InitializeResponse.new(1) | agent_info: implementation()}}
    end

    defp implementation do
      version =
        case :application.get_key(:raxol_agent, :vsn) do
          {:ok, vsn} -> List.to_string(vsn)
          _ -> "dev"
        end

      Implementation.new("raxol", version)
    end

    @impl true
    def new_session(req, ctx) do
      sid = "acp-#{System.unique_integer([:positive])}"
      turn_opts = session_turn_opts(ctx.handler_state.turn_opts, req)

      {:ok, _session} =
        Session.Supervisor.start_session(ctx.session_sup,
          session_id: sid,
          conn: ctx.conn,
          task_sup: ctx.task_sup,
          turn_runner: TurnRunner.new(turn_opts)
        )

      {:ok, NewSessionResponse.new(sid)}
    end

    # `session/new` names the session's working directory; scope this session's
    # fs/glob/grep tools to it through the tool-context `:cwd` seam
    # (`Raxol.Agent.Actions.Fs.working_dir/1`), so two sessions on one server
    # get independent roots and each tool call is contained under its own cwd.
    # A blank cwd leaves the server-wide default in place. Map pattern, not a
    # struct pattern, per the cross-package convention.
    defp session_turn_opts(base_opts, %{cwd: cwd})
         when is_binary(cwd) and cwd != "" do
      context =
        base_opts
        |> Keyword.get(:context)
        |> ensure_context_map()
        |> Map.put(:cwd, cwd)

      Keyword.put(base_opts, :context, context)
    end

    defp session_turn_opts(base_opts, _req), do: base_opts

    defp ensure_context_map(context) when is_map(context), do: context
    defp ensure_context_map(_other), do: %{}

    @impl true
    def prompt(req, ctx) do
      case Registry.lookup(Session.registry(), {ctx.conn, req.session_id}) do
        [{pid, _value} | _rest] ->
          case Session.begin_prompt(pid, req, ctx.reply_ref, ctx.rx_seq) do
            :ok -> :deferred
            {:error, %Error{} = error} -> {:error, error}
          end

        [] ->
          {:error, Error.new(-32_602, "unknown session")}
      end
    end
  end
end
