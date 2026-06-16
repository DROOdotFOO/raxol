defmodule Raxol.Agent.Tunnel do
  @moduledoc """
  One endpoint of the reverse co-driving tunnel.

  The co-driving model from omnigent: a host dials OUT to a server over a single
  link (the server never dials in), and many logical channels are multiplexed
  over that one link. A teammate's browser "attaches" by opening a channel on the
  server endpoint; the frames tunnel down to the host endpoint, which spawns the
  channel's handler **locally** -- so the work runs on the owner's machine, and
  the owner's filesystem and credentials never leave it.

  In the BEAM this is a GenServer holding the link plus a registry of channels.
  An endpoint is `role: :server` or `role: :host`. Only the host sets `:on_open`,
  the callback that materializes a local handler for each inbound channel.

  ## The link

  The endpoint is transport-agnostic. Outbound frames go through a `send_fun`
  (`binary -> any`); inbound bytes arrive as `{:tunnel_recv, binary}` messages.
  `Raxol.Agent.Tunnel.Link.connect/2` wires two endpoints together in-process
  (deterministic, no network). A real WebSocket transport (e.g. Mint.WebSocket on
  the host, Bandit on the server) is a drop-in adapter: read the socket and send
  `{:tunnel_recv, bytes}` to the endpoint; set `send_fun` to write the socket.

  ## Channels

  - `open_channel/3` (typically called on the server) allocates a `channel_id`,
    registers the caller (or `:owner`) as the local channel owner, and sends an
    `:open` frame. The peer's `:on_open` spawns its handler.
  - `send_data/3` sends channel I/O to the peer.
  - `close_channel/3` closes a channel on both ends.

  A channel owner receives `{:tunnel_data, channel_id, data}` for inbound I/O and
  `{:tunnel_closed, channel_id, reason}` when the channel closes. Owners are
  monitored: if an owner dies, its channel is closed and the peer notified.
  """

  use GenServer

  alias Raxol.Agent.Tunnel.Frame

  defstruct role: :server,
            host_id: nil,
            capabilities: [],
            send_fun: nil,
            on_open: nil,
            channels: %{},
            monitors: %{},
            peer_hello: nil

  @type server :: GenServer.server()
  @type channel_id :: binary()

  # -- Public API -------------------------------------------------------------

  @doc """
  Start a tunnel endpoint.

  Options:

    * `:role` -- `:server` (default) or `:host`.
    * `:host_id` / `:capabilities` -- host identity, sent in the hello frame.
    * `:on_open` -- host callback `(%{channel_id, path, meta, tunnel} -> {:ok, pid} | {:error, term})`.
    * `:send_fun` -- `(binary -> any)` link writer; may be set later via `set_link/2`.
    * `:name` -- optional registered name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Attach the outbound link writer. A host sends its hello frame on attach."
  @spec set_link(server(), (binary() -> any())) :: :ok
  def set_link(tunnel, send_fun) when is_function(send_fun, 1),
    do: GenServer.call(tunnel, {:set_link, send_fun})

  @doc """
  Open a channel to the peer. Returns `{:ok, channel_id}`.

  `:owner` (default the caller) receives this side's `{:tunnel_data, ...}` /
  `{:tunnel_closed, ...}` messages. `:meta` is an arbitrary map sent in the open
  frame.
  """
  @spec open_channel(server(), binary(), keyword()) ::
          {:ok, channel_id()} | {:error, :no_link}
  def open_channel(tunnel, path, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    meta = Keyword.get(opts, :meta, %{})
    GenServer.call(tunnel, {:open_channel, path, owner, meta})
  end

  @doc "Send channel data to the peer. Pass `binary: true` for raw bytes."
  @spec send_data(server(), channel_id(), binary(), keyword()) :: :ok | {:error, term()}
  def send_data(tunnel, channel_id, data, opts \\ []),
    do: GenServer.call(tunnel, {:send_data, channel_id, data, opts})

  @doc "Close a channel on both ends."
  @spec close_channel(server(), channel_id(), binary()) :: :ok
  def close_channel(tunnel, channel_id, reason \\ ""),
    do: GenServer.call(tunnel, {:close_channel, channel_id, reason})

  @doc "List this endpoint's open channel ids."
  @spec channels(server()) :: [channel_id()]
  def channels(tunnel), do: GenServer.call(tunnel, :channels)

  @doc "The peer's hello payload (`%{host_id, capabilities}`) or `nil`."
  @spec peer_hello(server()) :: map() | nil
  def peer_hello(tunnel), do: GenServer.call(tunnel, :peer_hello)

  # -- GenServer --------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      role: Keyword.get(opts, :role, :server),
      host_id: Keyword.get(opts, :host_id),
      capabilities: Keyword.get(opts, :capabilities, []),
      on_open: Keyword.get(opts, :on_open),
      send_fun: Keyword.get(opts, :send_fun)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:set_link, send_fun}, _from, state) do
    state = %{state | send_fun: send_fun}
    {:reply, :ok, maybe_say_hello(state)}
  end

  def handle_call({:open_channel, _path, _owner, _meta}, _from, %{send_fun: nil} = state),
    do: {:reply, {:error, :no_link}, state}

  def handle_call({:open_channel, path, owner, meta}, _from, state) do
    channel_id = Frame.new_channel_id()
    state = register_channel(state, channel_id, owner, path)
    send_frame(state, Frame.open(channel_id, path, meta))
    {:reply, {:ok, channel_id}, state}
  end

  def handle_call({:send_data, channel_id, data, opts}, _from, state) do
    case Map.has_key?(state.channels, channel_id) do
      true ->
        send_frame(state, Frame.data(channel_id, data, opts))
        {:reply, :ok, state}

      false ->
        {:reply, {:error, :unknown_channel}, state}
    end
  end

  def handle_call({:close_channel, channel_id, reason}, _from, state) do
    send_frame(state, Frame.close(channel_id, 1000, reason))
    {:reply, :ok, drop_channel(state, channel_id)}
  end

  def handle_call(:channels, _from, state),
    do: {:reply, Map.keys(state.channels), state}

  def handle_call(:peer_hello, _from, state),
    do: {:reply, state.peer_hello, state}

  @impl true
  def handle_info({:tunnel_recv, binary}, state) do
    case Frame.decode(binary) do
      {:ok, frame} -> {:noreply, route(frame, state)}
      {:error, _} -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {channel_id, monitors} ->
        send_frame(state, Frame.close(channel_id, 1001, "owner_down"))
        {:noreply, drop_channel(%{state | monitors: monitors}, channel_id)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Frame routing ----------------------------------------------------------

  defp route(%Frame{kind: :hello, payload: payload}, state),
    do: %{state | peer_hello: payload}

  defp route(%Frame{kind: :open, channel_id: cid, payload: payload}, state),
    do: accept_open(state, cid, Map.get(payload, "path", ""), Map.get(payload, "meta", %{}))

  defp route(%Frame{kind: :data, channel_id: cid} = frame, state) do
    case Map.get(state.channels, cid) do
      %{owner: owner} -> send(owner, {:tunnel_data, cid, Frame.read_data(frame)})
      nil -> :ok
    end

    state
  end

  defp route(%Frame{kind: :close, channel_id: cid, payload: payload}, state) do
    deliver_closed(state, cid, Map.get(payload, "reason", ""))
    drop_channel(state, cid)
  end

  # Peer asked to open a channel; the host materializes a local handler.
  defp accept_open(%{on_open: nil} = state, cid, _path, _meta) do
    send_frame(state, Frame.close(cid, 1003, "no_handler"))
    state
  end

  defp accept_open(%{on_open: on_open} = state, cid, path, meta) do
    case on_open.(%{channel_id: cid, path: path, meta: meta, tunnel: self()}) do
      {:ok, owner} when is_pid(owner) ->
        register_channel(state, cid, owner, path)

      {:error, reason} ->
        send_frame(state, Frame.close(cid, 1003, to_string_reason(reason)))
        state
    end
  end

  # -- Channel bookkeeping ----------------------------------------------------

  defp register_channel(state, channel_id, owner, path) do
    ref = Process.monitor(owner)

    %{
      state
      | channels: Map.put(state.channels, channel_id, %{owner: owner, path: path}),
        monitors: Map.put(state.monitors, ref, channel_id)
    }
  end

  defp drop_channel(state, channel_id) do
    monitors =
      case Enum.find(state.monitors, fn {_ref, cid} -> cid == channel_id end) do
        {ref, _cid} ->
          Process.demonitor(ref, [:flush])
          Map.delete(state.monitors, ref)

        nil ->
          state.monitors
      end

    %{state | channels: Map.delete(state.channels, channel_id), monitors: monitors}
  end

  defp deliver_closed(state, channel_id, reason) do
    case Map.get(state.channels, channel_id) do
      %{owner: owner} -> send(owner, {:tunnel_closed, channel_id, reason})
      nil -> :ok
    end
  end

  defp maybe_say_hello(%{role: :host, send_fun: send_fun} = state) when is_function(send_fun) do
    send_frame(state, Frame.hello(state.host_id, state.capabilities))
    state
  end

  defp maybe_say_hello(state), do: state

  defp send_frame(%{send_fun: send_fun}, frame) when is_function(send_fun, 1) do
    send_fun.(Frame.encode(frame))
    :ok
  end

  defp send_frame(_state, _frame), do: :ok

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)
end
