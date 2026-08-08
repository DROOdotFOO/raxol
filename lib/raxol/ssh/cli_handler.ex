defmodule Raxol.SSH.CLIHandler do
  @moduledoc false
  @behaviour :ssh_server_channel

  defstruct [
    :app_module,
    :server,
    :peer_ip,
    :session_pid,
    :channel_id,
    :connection_ref,
    :tenant_opts,
    app_opts: [],
    registered: false
  ]

  @impl true
  def init(opts) do
    app_module = Keyword.fetch!(opts, :app_module)
    server = Keyword.get(opts, :server, Raxol.SSH.Server)
    app_opts = Keyword.get(opts, :app_opts, [])
    tenant_opts = Keyword.get(opts, :tenant_opts)

    {:ok,
     %__MODULE__{
       app_module: app_module,
       server: server,
       app_opts: app_opts,
       tenant_opts: tenant_opts
     }}
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel_id, connection_ref}, state) do
    peer_ip = peer_ip(connection_ref)

    case Raxol.SSH.Server.register_connection(state.server, peer_ip) do
      :ok ->
        {:ok,
         %{
           state
           | channel_id: channel_id,
             connection_ref: connection_ref,
             peer_ip: peer_ip,
             registered: true
         }}

      {:error, _reason} ->
        _ =
          :ssh_connection.send(
            connection_ref,
            channel_id,
            "Connection limit reached. Try again later.\r\n"
          )

        _ = :ssh_connection.close(connection_ref, channel_id)
        {:ok, state}
    end
  end

  @impl true
  def handle_msg(msg, state) do
    Raxol.Core.Runtime.Log.debug(
      "[SSH.CLIHandler] Unhandled msg: #{inspect(msg)}"
    )

    {:ok, state}
  end

  @impl true
  def handle_ssh_msg({:ssh_cm, _conn, {:data, _ch, _type, data}}, state) do
    maybe_send(state.session_pid, {:ssh_data, data})
    {:ok, state}
  end

  # A second pty-req on a channel that already has a session is a RESIZE, not
  # a new session. Starting another would orphan the first Lifecycle (and its
  # journal, MCP clients, and tenant workspace) while still costing only the
  # one connection slot registered at `:ssh_channel_up` — a client that loops
  # pty-req could stand up unbounded sessions inside its single admitted
  # connection, straight through `max_connections` and `max_per_ip`.
  @impl true
  def handle_ssh_msg(
        {:ssh_cm, _conn,
         {:pty, _ch, _want_reply, {_term, width, height, _pxw, _pxh, _modes}}},
        %__MODULE__{session_pid: pid} = state
      )
      when not is_nil(pid) do
    send(pid, {:resize, width, height})
    {:ok, state}
  end

  @impl true
  def handle_ssh_msg(
        {:ssh_cm, _conn,
         {:pty, _ch, _want_reply, {_term, width, height, _pxw, _pxh, _modes}}},
        state
      ) do
    case resolve_tenant_opts(state) do
      {:ok, tenant_opts} ->
        {:ok, session_pid} =
          Raxol.SSH.Session.start_link(
            app_module: state.app_module,
            app_opts: state.app_opts,
            tenant_opts: tenant_opts,
            connection_ref: state.connection_ref,
            channel_id: state.channel_id,
            width: width,
            height: height
          )

        {:ok, %{state | session_pid: session_pid}}

      {:error, reason} ->
        # Fail closed: a tenant whose options cannot be derived must not
        # get an unjailed session running under server-wide defaults.
        Raxol.Core.Runtime.Log.warning(
          "[SSH.CLIHandler] Refusing session: tenant options failed " <>
            "(#{inspect(reason)})"
        )

        _ =
          :ssh_connection.send(
            state.connection_ref,
            state.channel_id,
            "Access denied.\r\n"
          )

        _ = :ssh_connection.close(state.connection_ref, state.channel_id)
        {:ok, state}
    end
  end

  @impl true
  def handle_ssh_msg(
        {:ssh_cm, _conn, {:window_change, _ch, width, height, _pxw, _pxh}},
        state
      ) do
    maybe_send(state.session_pid, {:resize, width, height})
    {:ok, state}
  end

  @impl true
  def handle_ssh_msg({:ssh_cm, _conn, {:shell, _ch, _want_reply}}, state) do
    {:ok, state}
  end

  @impl true
  def handle_ssh_msg({:ssh_cm, _conn, {:eof, _ch}}, state) do
    maybe_send(state.session_pid, :eof)
    {:ok, state}
  end

  @impl true
  def handle_ssh_msg({:ssh_cm, _conn, {:closed, _ch}}, state) do
    maybe_send(state.session_pid, :closed)
    {:stop, state.channel_id, state}
  end

  @impl true
  def handle_ssh_msg(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %__MODULE__{registered: true} = state) do
    Raxol.SSH.Server.unregister_connection(state.server, state.peer_ip)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp maybe_send(nil, _msg), do: :ok
  defp maybe_send(pid, msg), do: send(pid, msg)

  # Without a :tenant_opts fun the server is single-tenant: no per-user
  # options, sessions run under the server-wide app_opts as before. With
  # one, the AUTHENTICATED username decides — a raising fun refuses the
  # session (fail closed), never degrades to unjailed defaults.
  defp resolve_tenant_opts(%__MODULE__{tenant_opts: nil}), do: {:ok, []}

  defp resolve_tenant_opts(%__MODULE__{} = state) do
    case connection_user(state.connection_ref) do
      nil ->
        {:error, :no_authenticated_user}

      user ->
        case state.tenant_opts.(user) do
          {:ok, opts} when is_list(opts) -> {:ok, opts}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:bad_tenant_opts, other}}
        end
    end
  rescue
    error -> {:error, {:tenant_opts_raised, error}}
  end

  defp connection_user(connection_ref) do
    case :ssh.connection_info(connection_ref, [:user]) do
      [{:user, user}] when is_list(user) -> to_string(user)
      [{:user, user}] when is_binary(user) -> user
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # The peer IP scopes the per-source connection cap. Any surprise in the
  # connection info degrades to a shared `:unknown` bucket rather than crashing
  # the channel.
  defp peer_ip(connection_ref) do
    case :ssh.connection_info(connection_ref, [:peer]) do
      [{:peer, {_name, {ip, _port}}}] -> ip
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end
end
