# Compiled only when the ACP package is present. `use` injects the generated
# Agent behaviour, so a guard at call sites cannot replace this gate.
if Code.ensure_loaded?(Raxol.AgentClientProtocol.Agent) do
  defmodule Raxol.Agent.ClientProtocol.StdioAgent do
    @moduledoc """
    A Raxol agent as an ACP agent: the handler `raxol acp --agent` serves.

    `handler_arg` is `%{agent: %{app: name, id: id | nil} | nil}`, plus
    `:budget` (the connection's `Raxol.Agent.ClientProtocol.Budget`, absent
    or `nil` for no cap) and `:auth_opts` for `Raxol.Agent.Auth.Flow`.

    `initialize` always answers, so a client can connect before an agent is
    named. `session/new` then starts the named app in this BEAM and answers
    with the agent's id as the session id:

      * the app is matched against `config :raxol_agent,
        :mcp_spawnable_apps` and started by
        `Raxol.Agent.McpTools.start_owned/4`, under the rules `agent_spawn`
        applies: a required, locked journal bound to the project root and
        the app. The root is the request's `cwd`, which must be absolute.
      * with an id, a journal an earlier run left under it for the same root
        and app is continued; the agent's state starts fresh. One agent runs
        under the id, so a second `session/new` is refused while it does, or
        while another `session/new` is still starting it. An agent of this
        connection left without a session (its `session/new` was cancelled
        while it started) is stopped and started again.
      * without an id, every session starts a new agent under a random one.
      * with no agent named, or an app that is not listed, the request is
        refused and the error lists the apps that are.

    ## Ownership

    The agent's session tree is owned by `{{StdioAgent, connection}, _}`, not
    by `Raxol.Agent.McpTools`. Where one BEAM also serves the `agent_*` MCP
    tools, they do not list, ask or stop this agent and do not serve its
    journal; `agent_spawn` of its id is refused as in use, and this handler
    refuses an id an MCP-spawned agent runs under. `stop_agents/1` stops the
    agents a connection started; `Raxol.Agent.ClientProtocol.Serve` calls it
    when the connection ends.

    ## Turns

    `session/prompt` is one turn of the agent
    (`Raxol.Agent.ClientProtocol.Turn`): tool calls marked `sensitive` ask
    the client through `session/request_permission`
    (`Raxol.Agent.ClientProtocol.Permission`). `session/load` is not offered:
    a restarted agent has its journal and none of its state, so a replayed
    transcript would describe an agent that no longer exists.
    """

    use Raxol.AgentClientProtocol.Agent

    alias Raxol.Agent.Auth.Flow
    alias Raxol.Agent.ClientProtocol.Turn
    alias Raxol.Agent.McpTools
    alias Raxol.AgentClientProtocol.Error
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.AgentCapabilities
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateResponse
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.AuthMethod
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.Implementation
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse
    alias Raxol.AgentClientProtocol.Session

    @agents Raxol.Agent.Registry

    @impl true
    def init(arg), do: {:ok, arg}

    @doc """
    The auth methods `initialize` advertises: Agent Auth for each provider in
    `Raxol.Agent.Auth.Flow.providers/0`.

    Each carries its `_meta` type marker: the ACP registry infers the method
    type from that key.
    """
    @spec auth_methods() :: [AuthMethod.t()]
    def auth_methods, do: Enum.map(Flow.providers(), &agent_auth_method/1)

    defp agent_auth_method(provider) do
      %{
        AuthMethod.new(to_string(provider), "Sign in with #{label(provider)}")
        | description: "Approve in your browser; raxol catches the redirect locally",
          _meta: %{"agent-auth" => %{"provider" => to_string(provider)}}
      }
    end

    defp label(:openrouter), do: "OpenRouter"
    defp label(provider), do: provider |> to_string() |> String.capitalize()

    # Runs in the request's own task, so the wait for a browser holds up
    # nothing else, and a `$/cancel_request` ends it and closes the port.
    @impl true
    def authenticate(%{method_id: method_id}, ctx) do
      case provider_for(method_id) do
        {:ok, provider} -> run_agent_auth(provider, ctx)
        :error -> {:error, Error.new(-32_602, "unknown auth method #{inspect(method_id)}")}
      end
    end

    defp run_agent_auth(provider, ctx) do
      case Flow.run(provider, auth_opts(ctx)) do
        {:ok, _result} ->
          {:ok, AuthenticateResponse.new()}

        {:error, reason} ->
          {:error, Error.new(-32_603, "#{provider} sign-in failed: #{Flow.describe(reason)}")}
      end
    end

    # A method id is matched against the advertised list, never made an atom.
    defp provider_for(method_id) when is_binary(method_id) do
      case Enum.find(Flow.providers(), &(to_string(&1) == method_id)) do
        nil -> :error
        provider -> {:ok, provider}
      end
    end

    defp provider_for(_method_id), do: :error

    defp auth_opts(%{handler_state: state}) when is_map(state),
      do: Map.get(state, :auth_opts, [])

    defp auth_opts(_ctx), do: []

    @impl true
    def initialize(_req, _ctx) do
      {:ok,
       %{
         InitializeResponse.new(1)
         | agent_info: implementation(),
           auth_methods: auth_methods(),
           agent_capabilities: AgentCapabilities.new()
       }}
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
      with {:ok, agent} <- named_agent(ctx),
           {:ok, root} <- project_root(req) do
        id = Map.get(agent, :id) || random_id()
        claimed(id, fn -> start_session(agent.app, id, root, ctx) end)
      end
    end

    defp start_session(app, id, root, ctx) do
      with :ok <- start_agent(app, id, root, ctx.conn) do
        open_session(id, ctx)
      end
    end

    # One `session/new` at a time starts an agent under an id, so a second
    # one never takes the first's half-started agent for an abandoned one.
    # The claim ends with this process: a request cancelled mid-start gives
    # it up.
    defp claimed(id, start) do
      if claim(id) do
        try do
          start.()
        after
          release(id)
        end
      else
        refuse("id #{id} is in use: another session/new is starting it")
      end
    end

    defp claim(id, again? \\ true) do
      case Registry.register(@agents, {:acp_starting, id}, nil) do
        {:ok, _owner} -> true
        {:error, {:already_registered, holder}} -> again? and claim_after(holder, id)
      end
    rescue
      # No agent registry: the start itself reports that.
      ArgumentError -> true
    end

    # The registry drops a dead holder's claim a moment after it died.
    defp claim_after(holder, id) do
      if Process.alive?(holder) do
        false
      else
        Raxol.Agent.Session.await_free({:acp_starting, id})
        claim(id, false)
      end
    end

    defp release(id) do
      Registry.unregister(@agents, {:acp_starting, id})
    rescue
      ArgumentError -> :ok
    end

    @doc "Stop every agent `conn`'s sessions started."
    @spec stop_agents(pid()) :: :ok
    def stop_agents(conn) when is_pid(conn) do
      owner = owner(conn)

      for {id, {^owner, _owned}} <- Raxol.Agent.Session.Supervisor.owners(),
          do: McpTools.stop_owned(owner, id)

      :ok
    end

    defp owner(conn), do: {__MODULE__, conn}

    defp named_agent(%{handler_state: %{agent: %{app: app} = agent}}) when is_binary(app),
      do: {:ok, agent}

    defp named_agent(_ctx) do
      refuse(
        "no agent is named: start raxol acp with --agent <app>[:<id>]; " <>
          "spawnable: #{spawnable()}"
      )
    end

    defp spawnable do
      case McpTools.spawnable() do
        [] -> "none"
        names -> Enum.join(names, ", ")
      end
    end

    defp project_root(%{cwd: cwd}) when is_binary(cwd) do
      if Path.type(cwd) == :absolute,
        do: {:ok, cwd},
        else: refuse("cwd must be an absolute path: the agent's journal is bound to it")
    end

    defp project_root(_req),
      do: refuse("cwd must be an absolute path: the agent's journal is bound to it")

    defp start_agent(app, id, root, conn) do
      start = fn -> McpTools.start_owned(owner(conn), app, id, root) end

      case past_orphan(start.(), start, id, conn) do
        {:ok, _started} -> :ok
        {:error, message} -> refuse(message)
      end
    end

    # A refused start is tried once more when an orphan stood in its way.
    defp past_orphan({:ok, _started} = started, _start, _id, _conn), do: started

    defp past_orphan(refusal, start, id, conn),
      do: if(stop_orphan(id, conn), do: start.(), else: refusal)

    # An agent of this connection with no ACP session: the `session/new` that
    # started it was cancelled before it opened one. Nothing can prompt that
    # agent, so it makes way.
    defp stop_orphan(id, conn) do
      owner = owner(conn)

      with {:ok, {^owner, _owned}} <- Raxol.Agent.Session.Supervisor.owner(id),
           [] <- Registry.lookup(Session.registry(), {conn, id}) do
        McpTools.stop_owned(owner, id) == :ok
      else
        _other -> false
      end
    end

    # Random, not counted: a counter starts over in every BEAM and would name
    # an earlier run's journal.
    defp random_id, do: "acp-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    # The agent does not outlive a session that could not be opened for it.
    defp open_session(id, ctx) do
      started =
        Session.Supervisor.start_session(ctx.session_sup,
          session_id: id,
          conn: ctx.conn,
          task_sup: ctx.task_sup,
          turn_runner: Turn.runner(id, Map.get(ctx.handler_state, :budget))
        )

      case started do
        {:ok, _session} ->
          {:ok, NewSessionResponse.new(id)}

        {:error, reason} ->
          _ = McpTools.stop_owned(owner(ctx.conn), id)
          {:error, Error.new(-32_603, "the session did not start: #{inspect(reason)}")}
      end
    end

    defp refuse(message), do: {:error, Error.new(-32_602, message)}

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
