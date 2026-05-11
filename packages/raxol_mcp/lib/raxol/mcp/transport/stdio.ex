defmodule Raxol.MCP.Transport.Stdio do
  @moduledoc """
  Stdio transport for MCP.

  Reads JSON-RPC messages line-by-line from stdin, routes them to the
  MCP Server, and writes responses to stdout. This is the transport used
  by Claude Code and other CLI MCP clients.

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

  defstruct [:server, :reader_ref, :io_device, :output_device]

  @type t :: %__MODULE__{
          server: GenServer.server(),
          reader_ref: reference() | nil,
          io_device: IO.device(),
          output_device: IO.device()
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
      output_device: output_device
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
      {:ok, message} ->
        try do
          {:reply, response} = Server.handle_message(state.server, message)

          if response do
            write_response(state.output_device, response)
          end
        rescue
          e ->
            Logger.error("[MCP.Stdio] Error handling message: #{Exception.message(e)}")
            id = if is_map(message), do: Map.get(message, :id), else: nil

            if id do
              error = Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
              write_response(state.output_device, error)
            end
        end

      {:error, _reason} ->
        Logger.debug("[MCP.Stdio] Ignoring non-JSON line: #{String.slice(line, 0, 100)}")
    end

    {:noreply, state}
  end

  def handle_manager_info({:mcp_notification, notification}, state) do
    write_response(state.output_device, notification)
    {:noreply, state}
  end

  def handle_manager_info({:stdio_eof, _reason}, state) do
    Logger.info("[MCP.Stdio] Input stream closed, stopping")
    {:stop, :normal, state}
  end

  def handle_manager_info({:DOWN, ref, :process, _pid, reason}, %{reader_ref: ref} = state) do
    Logger.info("[MCP.Stdio] Reader process exited: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_manager_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private -----------------------------------------------------------------

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
