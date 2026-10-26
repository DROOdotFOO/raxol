defmodule Raxol.MCP.Transport.Stdio do
  @moduledoc """
  Stdio transport for MCP.

  Reads JSON-RPC messages line-by-line from stdin, routes them to the
  MCP Server, and writes responses to stdout. This is the transport used
  by Claude Code and other CLI MCP clients.

  ## Ordering and cancellation

  The reader never waits for the server: each line goes out in read order
  through `Raxol.MCP.Server.request/3`, so a slow `tools/call` does not hold
  up the `tools/list` behind it, and methods the server handles inline keep
  their order. Replies arrive in this process's mailbox and only this process
  writes stdout. Requests run concurrently and share the server's
  `:max_in_flight` cap with every other connection, so a stdio client can be
  answered `server_busy`.

  `notifications/cancelled` cancels the named in-flight request, which kills
  its callback worker. That holds for a `tools/call` waiting on an elicitation
  answer too: it stays in flight until it is answered, so a cancel drops it
  unanswered, or kills its tool once the answer approved it. A request that
  reuses the id of one still in flight is answered `-32600` and not run. At
  end of input every reply already produced is still written (methods the
  server answers inline, such as `initialize` and `ping`, and worker-run
  requests that finished first); every request still running in a callback
  worker (`tools/*`, `resources/*`, `prompts/*`, `completion/complete`) or
  waiting on an elicitation answer is cancelled and gets no reply. The
  transport stops `:normal` once nothing is outstanding; halting the VM is the
  caller's job.

  If the transport dies any other way (killed, a crash), the server cancels its
  outstanding requests, since it monitors every `Raxol.MCP.Server.request/3`
  caller, and the linked reader exits with it rather than go on consuming
  input.

  The transport monitors the server it subscribed to and stops with
  `{:server_down, reason}` when that server goes down, whether or not a request
  is pending, and with `{:server_down, :noproc}` at start if no server is
  running. A restarted server (`Raxol.MCP.Supervisor` restarts it under the
  same name) knows nothing of this transport's subscription, so carrying on
  would leave it unable to receive notifications or be asked for an
  elicitation; stopping lets the client restart the whole server process.

  The transport traps exits (to see its reader's), and keeps ordinary link
  semantics otherwise: when the process that started it exits, it stops with
  the same reason, as any OTP process that traps exits does, and an abnormal
  exit of any other linked process stops it with that reason (a `:normal` one
  is ignored, as an untrapped link would ignore it).

  ## Notifications

  Subscribes to the MCP Server for push notifications (e.g. `notifications/tools/list_changed`).
  Notifications are written to stdout as unsolicited JSON-RPC messages.

  ## Important

  When using this transport, configure Logger to write to stderr to avoid
  corrupting the JSON-RPC stream on stdout:

      config :logger, :default_handler, %{config: %{type: :standard_error}}

  Or at runtime:

      Logger.configure_backend(:console, device: :standard_error)
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.MCP.{Protocol, Server}

  defstruct [
    :server,
    :reader,
    :io_device,
    :output_device,
    :server_monitor,
    :requests,
    in_flight: %{},
    closing: false
  ]

  @type t :: %__MODULE__{
          server: GenServer.server(),
          reader: pid() | nil,
          server_monitor: reference() | nil,
          io_device: IO.device(),
          output_device: IO.device(),
          requests: :gen_server.request_id_collection(),
          in_flight: %{optional(term()) => reference()},
          closing: boolean()
        }

  # -- Client API ---------------------------------------------------------------

  @doc """
  Start the stdio transport.

  ## Options

  - `:server` -- MCP Server pid or name (default: `Raxol.MCP.Server`)
  - `:name` -- GenServer name (optional)
  - `:io_device` -- input device (default: `:stdio`), useful for testing
  - `:output_device` -- output device (default: `:stdio`), useful for testing
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    gen_opts = if name = Keyword.get(opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  # -- GenServer Callbacks -------------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    # The reader is linked so that it cannot outlive this process; trapping its
    # exit keeps a reader crash a clean close rather than a crash here.
    Process.flag(:trap_exit, true)
    server = Keyword.get(opts, :server, Server)
    io_device = Keyword.get(opts, :io_device, :stdio)
    output_device = Keyword.get(opts, :output_device, :stdio)

    state = %__MODULE__{
      server: server,
      io_device: io_device,
      output_device: output_device,
      requests: :gen_server.reqids_new()
    }

    {:ok, state, {:continue, :start_reader}}
  end

  @impl GenServer
  def handle_continue(:start_reader, state) do
    case GenServer.whereis(state.server) do
      nil ->
        Logger.error("[MCP.Stdio] MCP server not running: #{inspect(state.server)}")
        {:stop, {:server_down, :noproc}, state}

      server ->
        # Monitor and subscribe the same process, so a restart between the two
        # cannot leave this transport subscribed to a server it is not watching.
        server_monitor = Process.monitor(server)
        Server.subscribe(server, self())

        parent = self()
        io_device = state.io_device
        reader = spawn_link(fn -> read_loop(io_device, parent) end)

        {:noreply, %{state | reader: reader, server_monitor: server_monitor}}
    end
  end

  # A `:normal` stop does not take the linked reader down (it is not trapping,
  # so it ignores a normal exit), and a reader left blocked in `IO.gets/2`
  # would go on consuming input meant for whatever runs next.
  @impl GenServer
  def terminate(_reason, %{reader: reader}) when is_pid(reader) do
    Process.exit(reader, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:stdio_line, line}, state) do
    case Protocol.decode(line) do
      {:ok, %{method: "notifications/cancelled"} = message}
      when not is_map_key(message, :id) ->
        {:noreply, cancel_request(state, message)}

      {:ok, message} ->
        {:noreply, send_request(state, message)}

      {:error, _reason} ->
        Logger.debug("[MCP.Stdio] Ignoring non-JSON line: #{String.slice(line, 0, 100)}")
        {:noreply, state}
    end
  end

  def handle_manager_info({:mcp_notification, notification}, state) do
    write_response(state.output_device, notification)
    {:noreply, state}
  end

  def handle_manager_info({:stdio_eof, _reason}, state) do
    Logger.info("[MCP.Stdio] Input stream closed, stopping")
    close(state)
  end

  # The reader exits after reporting end of input; that exit is expected.
  def handle_manager_info({:EXIT, pid, _reason}, %{reader: pid, closing: true} = state),
    do: {:noreply, state}

  def handle_manager_info({:EXIT, pid, reason}, %{reader: pid} = state) do
    Logger.info("[MCP.Stdio] Reader process exited: #{inspect(reason)}")
    close(state)
  end

  def handle_manager_info({:DOWN, ref, :process, _server, reason}, %{server_monitor: ref} = state) do
    Logger.error("[MCP.Stdio] MCP server down: #{inspect(reason)}")
    {:stop, {:server_down, reason}, state}
  end

  # Trapping exits must not swallow a linked process's crash. The parent's exit
  # never gets here: `gen_server` handles it before any callback.
  def handle_manager_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_manager_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_manager_info(msg, state) do
    case :gen_server.check_response(msg, state.requests, true) do
      {{:reply, {:reply, response}}, {id, request_ref}, requests} ->
        if response, do: write_reply(state.output_device, id, response)

        maybe_stop(%{
          state
          | requests: requests,
            in_flight: forget(state.in_flight, id, request_ref)
        })

      {{:error, {reason, _server}}, _label, requests} ->
        Logger.error("[MCP.Stdio] MCP server down: #{inspect(reason)}")
        {:stop, {:server_down, reason}, %{state | requests: requests}}

      no_match when no_match in [:no_reply, :no_request] ->
        {:noreply, state}
    end
  end

  # -- Private -----------------------------------------------------------------

  # Ids are how a cancel and a reply find their request, so two in flight under
  # one id would leave the first unreachable. The second is refused, not run.
  defp send_request(state, %{id: id, method: _method}) when is_map_key(state.in_flight, id) do
    error =
      Protocol.error_response(id, Protocol.invalid_request(), "duplicate request id in flight")

    write_reply(state.output_device, id, error)
    state
  end

  defp send_request(state, message) do
    {req_id, request_ref} = Server.request(state.server, message)
    id = Map.get(message, :id)
    requests = :gen_server.reqids_add(req_id, {id, request_ref}, state.requests)

    in_flight =
      if id != nil and Protocol.request?(message),
        do: Map.put(state.in_flight, id, request_ref),
        else: state.in_flight

    %{state | requests: requests, in_flight: in_flight}
  end

  defp cancel_request(state, message) do
    id =
      case Map.get(message, :params) do
        %{"requestId" => id} -> id
        _ -> nil
      end

    case Map.pop(state.in_flight, id) do
      {nil, _in_flight} ->
        state

      {request_ref, in_flight} ->
        Server.cancel(state.server, request_ref)
        %{state | in_flight: in_flight}
    end
  end

  # The server answers every request exactly once, a cancelled one with
  # `{:reply, nil}` (one parked for an elicitation answer included), so
  # draining the collection ends.
  defp close(state) do
    cancel_all(state)
    maybe_stop(%{state | closing: true})
  end

  defp maybe_stop(%{closing: true} = state) do
    if :gen_server.reqids_size(state.requests) == 0,
      do: {:stop, :normal, state},
      else: {:noreply, state}
  end

  defp maybe_stop(state), do: {:noreply, state}

  defp cancel_all(state) do
    for {_req_id, {_id, request_ref}} <- :gen_server.reqids_to_list(state.requests) do
      Server.cancel(state.server, request_ref)
    end

    :ok
  end

  # A JSON-RPC id may be reused once its request completed, so only drop the
  # mapping that still points at this request.
  defp forget(in_flight, id, request_ref) do
    case in_flight do
      %{^id => ^request_ref} -> Map.delete(in_flight, id)
      _ -> in_flight
    end
  end

  defp write_reply(device, id, response) do
    write_response(device, response)
  rescue
    e ->
      Logger.error("[MCP.Stdio] Error writing response: #{Exception.message(e)}")

      if id do
        error = Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
        write_response(device, error)
      end
  end

  defp read_loop(io_device, parent) do
    case IO.gets(io_device, "") do
      :eof ->
        send(parent, {:stdio_eof, :eof})

      {:error, reason} ->
        send(parent, {:stdio_eof, reason})

      line when is_binary(line) ->
        trimmed = line |> String.trim_trailing("\n") |> String.trim_trailing("\r")

        if trimmed != "" do
          send(parent, {:stdio_line, trimmed})
        end

        read_loop(io_device, parent)
    end
  end

  defp write_response(device, response) do
    data = Protocol.encode!(response)
    IO.write(device, data)
  end
end
