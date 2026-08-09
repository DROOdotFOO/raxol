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

    alias Raxol.Agent.Auth.Flow
    alias Raxol.Agent.ClientProtocol.TurnRunner
    alias Raxol.AgentClientProtocol.Error
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateResponse
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.AuthMethod
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.Implementation
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse
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
            | description:
                "Connect a provider interactively with `raxol login`",
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
        | description:
            "Approve in your browser; raxol catches the redirect locally",
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
          {:error,
           Error.new(-32_602, "unknown auth method #{inspect(method_id)}")}
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
           auth_methods: auth_methods()
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
