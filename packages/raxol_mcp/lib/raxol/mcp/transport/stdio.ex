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
  its callback worker. At end of input every reply already produced is still
  written (methods the server answers inline, such as `initialize` and `ping`,
  and worker-run requests that finished first); every request still running
  in a callback worker (`tools/*`, `resources/*`, `prompts/*`,
  `completion/complete`) is cancelled and gets no reply. The transport stops
  `:normal` once nothing is outstanding; halting the VM is the caller's job.

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
    :reader_ref,
    :io_device,
    :output_device,
    :requests,
    in_flight: %{},
    closing: false
  ]

  @type t :: %__MODULE__{
          server: GenServer.server(),
          reader_ref: reference() | nil,
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
    # Subscribe to server notifications
    Server.subscribe(state.server, self())

    parent = self()
    io_device = state.io_device

    {_pid, ref} =
      spawn_monitor(fn ->
        read_loop(io_device, parent)
      end)

    {:noreply, %{state | reader_ref: ref}}
  end

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
  def handle_manager_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{reader_ref: ref, closing: true} = state
      ),
      do: {:noreply, state}

  def handle_manager_info({:DOWN, ref, :process, _pid, reason}, %{reader_ref: ref} = state) do
    Logger.info("[MCP.Stdio] Reader process exited: #{inspect(reason)}")
    close(state)
  end

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
  # `{:reply, nil}`, so draining the collection ends.
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
