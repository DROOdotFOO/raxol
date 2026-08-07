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
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse
    alias Raxol.AgentClientProtocol.Session

    # handler_arg = %{turn_opts: keyword} — executor and toolset resolved by
    # the launcher, once, before serving.
    @impl true
    def init(arg), do: {:ok, arg}

    @impl true
    def initialize(_req, _ctx), do: {:ok, InitializeResponse.new(1)}

    @impl true
    def new_session(_req, ctx) do
      sid = "acp-#{System.unique_integer([:positive])}"

      {:ok, _session} =
        Session.Supervisor.start_session(ctx.session_sup,
          session_id: sid,
          conn: ctx.conn,
          task_sup: ctx.task_sup,
          turn_runner: TurnRunner.new(ctx.handler_state.turn_opts)
        )

      {:ok, NewSessionResponse.new(sid)}
    end

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
