defmodule Raxol.Gateway.Adapter.Discord.GatewaySocket do
  @moduledoc """
  Holds one connection to the Discord Gateway (v10, JSON encoding) and
  hands each dispatch frame to a caller-supplied function.

  This is the Discord update *feed*, the counterpart of
  `Raxol.Telegram.UpdatePoller`: sink-agnostic, `:on_event` decides what a
  frame means. Pair it with `Raxol.Gateway.Adapter.Discord.normalize_event/1`
  and authorize BEFORE routing:

      {:ok, conn} = Raxol.Gateway.Adapter.Discord.connect(bot_token: token)

      Raxol.Gateway.Adapter.Discord.GatewaySocket.start_link(
        token: token,
        on_event: fn frame ->
          with {:ok, route, event} <- Raxol.Gateway.Adapter.Discord.normalize_event(frame),
               :allow <- Raxol.Gateway.Pairing.authorize(MyPairing, route) do
            Raxol.Gateway.SessionRouter.route(MyRouter, route, event)
          else
            :ignore -> :ok
            :deny -> Logger.info("unauthorized discord chat denied")
          end
        end
      )

  ## Options

    * `:token` (required) - the bot token, sent in identify/resume
    * `:on_event` (required) - 1-arity function called per dispatch frame
      (op 0), in order, with the raw string-keyed frame
      (`%{"t" => type, "d" => data, ...}`). A crash inside it is caught and
      logged.
    * `:intents` - intent bitfield (default
      `Raxol.Gateway.Adapter.Discord.Protocol.default_intents/0`; note
      MESSAGE_CONTENT is privileged and must also be enabled in the
      developer portal)
    * `:gateway_url` - default `"wss://gateway.discord.gg"`; the
      `?v=10&encoding=json` query is appended, so pass it query-free
    * `:transport` / `:transport_opts` - the
      `Raxol.Gateway.Adapter.Discord.GatewaySocket.Transport` module
      (default `MintTransport`, which needs the optional
      `:mint_web_socket` dependency) and its options
    * `:parent` - optional pid receiving `{:discord_socket, payload}`
      lifecycle notifications (`:ready`, `{:disconnected, reason}`,
      `{:reconnecting, attempt, delay}`)
    * `:reconnect_base_ms` / `:reconnect_max_ms` - backoff window
      (defaults 500 / 30_000)
    * `:jitter_fn` - 0-arity float source for the first-heartbeat jitter
      (default `:rand.uniform/0`); injectable so tests control when the
      heartbeat timer can fire
    * `:name` - optional registered name

  ## Semantics

  Heartbeats are client-initiated at the HELLO interval (first beat
  jittered per the gateway docs); a beat that is never acknowledged marks
  the connection a zombie and forces a reconnect. After READY the socket
  resumes interrupted sessions (session id + sequence + resume URL) so
  missed dispatches replay; an unresumable session re-identifies from
  scratch. Reconnects back off exponentially from
  `:reconnect_base_ms` doubling to `:reconnect_max_ms`, resetting once a
  session reaches READY/RESUMED. Frames are never logged whole - identify
  and resume embed the token.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Core.ErrorHandling
  alias Raxol.Gateway.Adapter.Discord.GatewaySocket.MintTransport
  alias Raxol.Gateway.Adapter.Discord.Protocol

  @default_gateway_url "wss://gateway.discord.gg"
  @gateway_query "v=10&encoding=json"
  @default_reconnect_base_ms 500
  @default_reconnect_max_ms 30_000

  @doc "Current connection phase. Mostly for tests and introspection."
  @spec phase(GenServer.server()) :: atom()
  def phase(server), do: GenServer.call(server, :phase)

  @doc "Gracefully close the connection and stop the socket."
  @spec close(GenServer.server()) :: :ok
  def close(server), do: GenServer.cast(server, :close)

  @impl true
  def init_manager(opts) do
    state = %{
      token: Keyword.fetch!(opts, :token),
      on_event: Keyword.fetch!(opts, :on_event),
      intents: Keyword.get(opts, :intents, Protocol.default_intents()),
      gateway_url: Keyword.get(opts, :gateway_url, @default_gateway_url),
      transport: Keyword.get(opts, :transport, MintTransport),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      parent: Keyword.get(opts, :parent),
      reconnect_base_ms: Keyword.get(opts, :reconnect_base_ms, @default_reconnect_base_ms),
      reconnect_max_ms: Keyword.get(opts, :reconnect_max_ms, @default_reconnect_max_ms),
      jitter_fn: Keyword.get(opts, :jitter_fn, &:rand.uniform/0),
      conn: nil,
      phase: :disconnected,
      heartbeat_interval_ms: nil,
      heartbeat_timer: nil,
      awaiting_ack: false,
      seq: nil,
      session_id: nil,
      resume_gateway_url: nil,
      reconnect_attempts: 0,
      reconnect_timer: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_manager_call(:phase, _from, state),
    do: {:reply, state.phase, state}

  @impl true
  def handle_manager_cast(:close, state) do
    {:stop, :normal, teardown(state, :closed_by_us)}
  end

  @impl true
  def handle_manager_info(:connect, state) do
    state = cancel_timer(state, :reconnect_timer)
    {:noreply, attempt_connect(state)}
  end

  def handle_manager_info(:heartbeat, %{phase: phase} = state)
      when phase in [:identifying, :ready] do
    if state.awaiting_ack do
      Logger.warning("discord_socket heartbeat never acknowledged (zombie)")
      {:noreply, state |> teardown(:zombie) |> schedule_reconnect()}
    else
      state = send_payload(state, Protocol.encode_heartbeat(state.seq))

      # A failed send tears down inside send_payload; only a live
      # connection keeps the heartbeat cycle going.
      state =
        if state.conn do
          state
          |> Map.put(:awaiting_ack, true)
          |> schedule_heartbeat(state.heartbeat_interval_ms)
        else
          state
        end

      {:noreply, state}
    end
  end

  def handle_manager_info(:heartbeat, state), do: {:noreply, state}

  def handle_manager_info(msg, %{conn: conn} = state) when not is_nil(conn) do
    case state.transport.stream(conn, msg) do
      {:ok, conn, events} ->
        {:noreply, Enum.reduce(events, %{state | conn: conn}, &handle_event/2)}

      {:error, conn, reason} ->
        Logger.warning("discord_socket transport error: #{inspect(reason)}")

        state =
          %{state | conn: conn}
          |> teardown({:transport, reason})
          |> schedule_reconnect()

        {:noreply, state}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # Crash and termination reports must never dump the state: :token is the
  # bot credential.
  @impl GenServer
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{token: _token} = state -> %{state | token: :redacted}
      other -> other
    end)
  end

  # -- Connect path -----------------------------------------------------

  defp attempt_connect(state) do
    url = state.resume_gateway_url || state.gateway_url

    case state.transport.connect(parse_url(url), state.transport_opts) do
      {:ok, conn} ->
        %{state | conn: conn, phase: :upgrading}

      {:error, reason} ->
        Logger.warning("discord_socket connect failed: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  defp parse_url(url) do
    uri = URI.parse(url)

    scheme =
      case uri.scheme do
        "wss" -> :wss
        "https" -> :wss
        "ws" -> :ws
        "http" -> :ws
        other -> raise ArgumentError, "unsupported scheme: #{inspect(other)}"
      end

    port = uri.port || if scheme == :wss, do: 443, else: 80
    path = (uri.path || "/") <> "?" <> @gateway_query
    %{scheme: scheme, host: uri.host, port: port, path: path}
  end

  # -- Transport events -------------------------------------------------

  defp handle_event(:upgraded, state), do: %{state | phase: :awaiting_hello}

  defp handle_event({:text, payload}, state),
    do: handle_gateway_message(Protocol.decode(payload), state)

  defp handle_event({:close, code, reason}, state) do
    Logger.debug("discord_socket closed: #{inspect(code)} #{inspect(reason)}")
    state |> teardown({:ws_close, code, reason}) |> schedule_reconnect()
  end

  defp handle_event({:transport_error, reason}, state) do
    Logger.warning("discord_socket transport error: #{inspect(reason)}")
    state |> teardown({:transport, reason}) |> schedule_reconnect()
  end

  # -- Gateway messages -------------------------------------------------

  defp handle_gateway_message({:hello, interval}, state) do
    state =
      %{state | heartbeat_interval_ms: interval, awaiting_ack: false}
      |> cancel_timer(:heartbeat_timer)
      |> send_payload(identify_or_resume(state))

    # A failed identify/resume send tears down inside send_payload; only a
    # live connection enters the heartbeat cycle.
    if state.conn do
      state
      |> schedule_heartbeat(first_heartbeat_delay(state, interval))
      |> Map.put(:phase, :identifying)
    else
      state
    end
  end

  defp handle_gateway_message(:heartbeat_ack, state),
    do: %{state | awaiting_ack: false}

  defp handle_gateway_message(:heartbeat_request, state),
    do: send_payload(state, Protocol.encode_heartbeat(state.seq))

  defp handle_gateway_message(:reconnect, state),
    do: state |> teardown(:server_reconnect) |> schedule_reconnect()

  defp handle_gateway_message({:invalid_session, true}, state),
    do: state |> teardown(:invalid_session) |> schedule_reconnect()

  defp handle_gateway_message({:invalid_session, false}, state) do
    %{state | session_id: nil, seq: nil, resume_gateway_url: nil}
    |> teardown(:invalid_session_unresumable)
    |> schedule_reconnect()
  end

  defp handle_gateway_message({:dispatch, frame}, state) do
    state = advance_seq(state, frame["s"])

    state =
      case frame["t"] do
        "READY" -> handle_ready(state, frame["d"])
        "RESUMED" -> handle_resumed(state)
        _other -> state
      end

    deliver(state, frame)
    state
  end

  defp handle_gateway_message({:unknown, _frame}, state), do: state

  defp handle_gateway_message({:error, reason}, state) do
    Logger.warning("discord_socket bad frame: #{inspect(reason)}")
    state
  end

  defp handle_ready(state, %{} = data) do
    notify(state, :ready)

    %{
      state
      | phase: :ready,
        reconnect_attempts: 0,
        session_id: data["session_id"],
        resume_gateway_url: data["resume_gateway_url"]
    }
  end

  defp handle_ready(state, _data), do: %{state | phase: :ready}

  defp handle_resumed(state) do
    notify(state, :ready)
    %{state | phase: :ready, reconnect_attempts: 0}
  end

  defp identify_or_resume(%{session_id: sid, seq: seq} = state)
       when is_binary(sid) and is_integer(seq),
       do: Protocol.encode_resume(state.token, sid, seq)

  defp identify_or_resume(state),
    do: Protocol.encode_identify(state.token, state.intents)

  defp advance_seq(state, seq) when is_integer(seq),
    do: %{state | seq: max(seq, state.seq || 0)}

  defp advance_seq(state, _seq), do: state

  defp deliver(state, frame) do
    case ErrorHandling.safe_call(fn -> state.on_event.(frame) end) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "discord_socket on_event failed for #{inspect(frame["t"])}: " <>
            inspect(error)
        )
    end
  end

  # -- Send + reconnect helpers ------------------------------------------

  defp send_payload(%{conn: nil} = state, _payload), do: state

  defp send_payload(state, payload) do
    case state.transport.send_text(state.conn, payload) do
      {:ok, conn} ->
        %{state | conn: conn}

      {:error, conn, reason} ->
        Logger.warning("discord_socket send failed: #{inspect(reason)}")

        %{state | conn: conn}
        |> teardown({:send, reason})
        |> schedule_reconnect()
    end
  end

  defp teardown(state, reason) do
    notify(state, {:disconnected, reason})
    if state.conn, do: state.transport.close(state.conn)

    state
    |> cancel_timer(:heartbeat_timer)
    |> Map.merge(%{conn: nil, phase: :disconnected, awaiting_ack: false})
  end

  defp schedule_reconnect(state) do
    state = cancel_timer(state, :reconnect_timer)
    attempt = state.reconnect_attempts + 1

    delay =
      state.reconnect_base_ms
      |> Bitwise.bsl(min(attempt - 1, 16))
      |> min(state.reconnect_max_ms)

    timer = Process.send_after(self(), :connect, delay)
    notify(state, {:reconnecting, attempt, delay})
    %{state | reconnect_attempts: attempt, reconnect_timer: timer}
  end

  defp schedule_heartbeat(state, interval_ms) do
    timer = Process.send_after(self(), :heartbeat, interval_ms)
    %{state | heartbeat_timer: timer}
  end

  # The gateway docs require jittering the first heartbeat to spread
  # thundering herds after large reconnects.
  defp first_heartbeat_delay(state, interval),
    do: trunc(state.jitter_fn.() * interval)

  defp cancel_timer(state, key) do
    case Map.fetch!(state, key) do
      nil ->
        state

      timer ->
        Process.cancel_timer(timer)
        Map.put(state, key, nil)
    end
  end

  defp notify(%{parent: nil}, _payload), do: :ok

  defp notify(%{parent: parent}, payload),
    do: send(parent, {:discord_socket, payload})
end
