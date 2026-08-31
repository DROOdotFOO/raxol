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
    Turns run the FULL toolset, mutating tools included. Every sensitive call
    is gated on a `session/request_permission` round trip via
    `Raxol.Agent.ClientProtocol.Permission`, which `TurnRunner` injects as the
    turn's `:tool_authorizer`. Reads are not gated, so a read-heavy turn costs
    no extra protocol traffic. A client that refuses, times out, disconnects,
    or does not implement permissions denies the write and keeps reading, so
    the surface is fail-closed on the DECISION rather than on the toolset.

    Both of ACP's registry-accepted auth methods are advertised. `authenticate`
    runs Agent Auth in-process via `Raxol.Agent.Auth.Flow` for the providers
    that have a real browser flow; Terminal Auth (`raxol login`) covers every
    other provider. See `auth_methods/0`.
    """

    use Raxol.AgentClientProtocol.Agent

    require Logger

    alias Raxol.Agent.Auth.Flow
    alias Raxol.Agent.ClientProtocol.TurnRunner
    alias Raxol.Agent.Journal.FileStore
    alias Raxol.Agent.SessionKey
    alias Raxol.AgentClientProtocol.Connection
    alias Raxol.AgentClientProtocol.Error
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.AgentCapabilities
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateResponse
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.AuthMethod
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.Implementation
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionResponse
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse
    alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
    alias Raxol.AgentClientProtocol.Session

    # handler_arg = %{turn_opts: keyword} — executor and toolset resolved by
    # the launcher, once, before serving.
    @impl true
    def init(arg), do: {:ok, arg}

    # Both of the registry's accepted methods, in the order a client should
    # prefer them.
    #
    # Agent Auth first: `authenticate` runs the OAuth flow in-process -- bind a
    # loopback port, open a browser, catch the redirect, store the credential --
    # so the user never leaves the editor. It is offered only for the providers
    # in `Flow.providers/0`, because a method advertised without a flow behind
    # it is a sign-in that hangs.
    #
    # Terminal Auth second, and still the general answer: raxol takes its
    # credential from a stored `op://` reference or a provider env var, never
    # from the wire, so for every provider without a browser flow the client
    # relaunches this same binary and the user connects one in a real terminal.
    #
    # Each entry carries its `_meta` type marker. The registry validator infers
    # the method from that key and silently defaults an untyped method to
    # `agent` -- so the markers are load-bearing, not decoration: an untyped
    # entry would claim Agent Auth for a flow that does not exist.
    @doc false
    def auth_methods do
      Enum.map(Flow.providers(), &agent_auth_method/1) ++
        [
          %{
            AuthMethod.new("terminal", "Run in terminal")
            | description: "Connect a provider interactively with `raxol login`",
              _meta: %{"terminal-auth" => %{"args" => ["login"]}}
          }
        ]
    end

    # Total on purpose: a provider added to `Flow.providers/0` is advertised
    # even before anyone writes copy for it here. A FunctionClauseError raised
    # from this function would take out `initialize`, not just the new method.
    defp agent_auth_method(provider) do
      %{
        AuthMethod.new(to_string(provider), "Sign in with #{label(provider)}")
        | description: "Approve in your browser; raxol catches the redirect locally",
          _meta: %{"agent-auth" => %{"provider" => to_string(provider)}}
      }
    end

    defp label(:openrouter), do: "OpenRouter"
    defp label(provider), do: provider |> to_string() |> String.capitalize()

    # The Agent Auth flow itself. Each inbound request already runs in its own
    # dispatch task (Connection §4.1), so waiting here for a browser blocks
    # only this request -- the wire keeps moving, and a `$/cancel_request`
    # kills the task, which closes the loopback port with it.
    #
    # Fail-closed on the whole flow: a refusal, a timeout, a disconnect, or a
    # key the provider will not authorize is an error, never a partial success
    # that leaves a client thinking it can open a session.
    @impl true
    def authenticate(%{method_id: "terminal"}, _ctx) do
      {:error,
       Error.new(
         -32_602,
         "terminal auth does not run over the wire: relaunch this binary as `raxol login`"
       )}
    end

    def authenticate(%{method_id: method_id}, ctx) do
      case provider_for(method_id) do
        {:ok, provider} ->
          run_agent_auth(provider, ctx)

        :error ->
          {:error, Error.new(-32_602, "unknown auth method #{inspect(method_id)}")}
      end
    end

    defp run_agent_auth(provider, ctx) do
      case Flow.run(provider, auth_opts(ctx)) do
        {:ok, _result} ->
          {:ok, AuthenticateResponse.new()}

        {:error, reason} ->
          {:error,
           Error.new(
             -32_603,
             "#{provider} sign-in failed: #{Flow.describe(reason)}"
           )}
      end
    end

    # Never `String.to_atom/1` on wire input: a method id is matched against
    # the advertised list and anything else is an unknown method.
    defp provider_for(method_id) when is_binary(method_id) do
      case Enum.find(Flow.providers(), &(to_string(&1) == method_id)) do
        nil -> :error
        provider -> {:ok, provider}
      end
    end

    defp provider_for(_method_id), do: :error

    # The flow's seams, injectable through `handler_arg` so a test drives the
    # real loopback socket with no browser and no network.
    defp auth_opts(%{handler_state: state}) when is_map(state) do
      Map.get(state, :auth_opts, [])
    end

    defp auth_opts(_ctx), do: []

    # Identify ourselves in the handshake: clients and benchmark harnesses
    # record `agentInfo` as the agent under test, and a nil there is reported
    # as an unnamed agent.
    @impl true
    def initialize(_req, _ctx) do
      {:ok,
       %{
         InitializeResponse.new(1)
         | agent_info: implementation(),
           auth_methods: auth_methods(),
           agent_capabilities: capabilities()
       }}
    end

    # Advertised capabilities gate themselves: `Capabilities.negotiated?/2`
    # resolves an inbound gated method against THIS struct, and the Connection
    # answers a non-negotiated one with -32601 before it is even decoded. So
    # the response was previously leaving `agent_capabilities` nil, which read
    # as every optional capability being false -- `session/load` included, and
    # it was refused on that basis.
    #
    # Only `load_session` is claimed. The prompt/mcp/session capability groups
    # stay absent because nothing behind them is wired yet, and a capability is
    # a promise the gate will hold us to.
    defp capabilities, do: %{AgentCapabilities.new() | load_session: true}

    defp implementation do
      version =
        case :application.get_key(:raxol_agent, :vsn) do
          {:ok, vsn} -> List.to_string(vsn)
          _ -> "dev"
        end

      Implementation.new("raxol", version)
    end

    # The id is minted through `Raxol.Agent.SessionKey` rather than locally,
    # for two reasons. It has to stay meaningful after this VM exits -- a
    # client stores it and names it again to resume, and the previous
    # `System.unique_integer/1` id restarted from a fresh sequence every run,
    # so it named a different session on the far side of a restart. And it is
    # the directory a session's journal lives in, which the coding TUI also
    # writes, so the two surfaces cannot each own the format.
    @impl true
    def new_session(req, ctx) do
      sid = SessionKey.mint()
      {:ok, _session} = start_session(sid, req, ctx)
      {:ok, NewSessionResponse.new(sid)}
    end

    @doc """
    Replay a session recorded by an earlier run, then bind it so the next
    `session/prompt` continues it.

    The history is the notifications the original turns delivered, re-sent as
    the same `session/update` frames rather than rebuilt from a second
    vocabulary (see `Raxol.Agent.ClientProtocol.TurnRunner`'s "Durable
    record"). `Connection.notify/3` is a call, so every frame is on the wire
    ahead of this reply.
    """
    @impl true
    def load_session(req, ctx) do
      with {:ok, sid} <- loadable_id(req.session_id),
           {:ok, records} <- load_records(sid, ctx),
           :ok <- ensure_session(sid, req, ctx) do
        replay(records, ctx)
        {:ok, LoadSessionResponse.new()}
      end
    end

    # The session id arrives from the wire and becomes a path:
    # `FileStore.read_records/2` joins it onto the journal base WITHOUT
    # sanitizing (unlike `open/2`, which validates). This is the guard for
    # that, and it belongs here, in front of the read.
    defp loadable_id(session_id) do
      if SessionKey.valid?(session_id) do
        {:ok, session_id}
      else
        {:error, Error.new(-32_602, "session id #{inspect(session_id)} is not loadable")}
      end
    end

    # An id we have no journal for is reported as unknown rather than replayed
    # as an empty history: a client that mistyped an id, or kept one past its
    # deletion, must not be handed something that looks like a fresh session.
    defp load_records(sid, ctx) do
      case FileStore.read_records(sid, journal_opts(ctx)) do
        {:ok, []} ->
          {:error, Error.new(-32_602, "unknown session #{inspect(sid)}")}

        {:ok, records} ->
          {:ok, records}

        {:error, :damaged} ->
          {:error, Error.new(-32_603, "session #{inspect(sid)} has a damaged journal")}
      end
    end

    # Loading the same session twice on one connection must not mint a second
    # Session over the first.
    defp ensure_session(sid, req, ctx) do
      case Registry.lookup(Session.registry(), {ctx.conn, sid}) do
        [{_pid, _value} | _rest] ->
          :ok

        [] ->
          case start_session(sid, req, ctx) do
            {:ok, _session} ->
              :ok

            {:error, reason} ->
              {:error, Error.new(-32_603, "could not load session: #{inspect(reason)}")}
          end
      end
    end

    defp start_session(sid, req, ctx) do
      turn_opts = session_turn_opts(ctx.handler_state.turn_opts, req)

      Session.Supervisor.start_session(ctx.session_sup,
        session_id: sid,
        conn: ctx.conn,
        task_sup: ctx.task_sup,
        turn_runner: TurnRunner.new(turn_opts)
      )
    end

    # Only the delivered notifications are history; the turn-boundary records
    # are bookkeeping. A record that will not decode is skipped and counted
    # rather than aborting the load -- a partial history is worth more than
    # none, and the count says so out loud instead of leaving a silent gap.
    defp replay(records, ctx) do
      skipped =
        records
        |> Enum.filter(&(&1["type"] == "session_update"))
        |> Enum.reduce(0, fn record, skipped ->
          case decode_notification(record) do
            {:ok, notif} ->
              Connection.notify(ctx.conn, "session/update", notif)
              skipped

            :error ->
              skipped + 1
          end
        end)

      if skipped > 0 do
        Logger.warning("acp session/load: skipped #{skipped} undecodable record(s)")
      end

      :ok
    end

    defp decode_notification(%{"payload" => %{"notification" => json}}) when is_map(json) do
      case SessionNotification.from_json(json) do
        {:ok, notif} -> {:ok, notif}
        {:error, _reason} -> :error
      end
    end

    defp decode_notification(_record), do: :error

    defp journal_opts(%{handler_state: %{turn_opts: turn_opts}}) when is_list(turn_opts),
      do: Keyword.get(turn_opts, :journal_opts, [])

    defp journal_opts(_ctx), do: []

    # `session/new` names the session's working directory; scope this session's
    # fs/glob/grep tools to it through the tool-context `:cwd` seam
    # (`Raxol.Agent.Actions.Fs.working_dir/1`), so two sessions on one server
    # get independent roots and each tool call is contained under its own cwd.
    # A blank cwd leaves the server-wide default in place. Map pattern, not a
    # struct pattern, per the cross-package convention.
    defp session_turn_opts(base_opts, req) do
      cwd = session_cwd(req)

      base_opts
      |> put_session_cwd(cwd)
      |> put_workspace_instructions(cwd)
    end

    # A blank or absent cwd leaves the server-wide default in place.
    defp session_cwd(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd
    defp session_cwd(_req), do: nil

    defp put_session_cwd(base_opts, nil), do: base_opts

    defp put_session_cwd(base_opts, cwd) do
      context =
        base_opts
        |> Keyword.get(:context)
        |> ensure_context_map()
        |> Map.put(:cwd, cwd)

      Keyword.put(base_opts, :context, context)
    end

    # The editor names the session root, so `AGENTS.md` resolves per session
    # rather than once at boot. A `:system_prompt` source spec is left alone:
    # `TurnRunner` resolves those itself, and there is no text to append to.
    defp put_workspace_instructions(base_opts, cwd) do
      root = cwd || Raxol.Agent.Actions.Fs.working_dir()

      case Keyword.get(base_opts, :system_prompt) do
        system when is_binary(system) ->
          Keyword.put(
            base_opts,
            :system_prompt,
            Raxol.Agent.Code.ProjectContext.augment(system, root)
          )

        _other ->
          base_opts
      end
    end

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
