defmodule Raxol.ACP.Seller.Backend.WebSocket do
  @moduledoc """
  Live `Raxol.ACP.Seller.Backend` implementation backed by a Socket.IO
  v4 connection to the Virtuals ACP server.

  Owns a single `Raxol.ACP.Seller.Backend.WebSocket.Connection`
  process, tracks subscribers, and translates the server's
  `onNewTask`/`onEvaluate` events into the canonical
  `{:acp_event, %{type: ...}}` shape consumed by
  `Raxol.ACP.Seller.Queue`.

  ## Configuration

      config :raxol_acp,
        chain: :mainnet,
        seller_backend: Raxol.ACP.Seller.Backend.WebSocket,
        seller_backend_auth: %{walletAddress: "0x..."}

  URL resolution order (first match wins):

  1. Explicit `:url` opt to `start_link/1`
  2. `:raxol_acp, :seller_backend_url` application env
  3. `acp_socket_url` field on the configured chain
     (`Raxol.ACP.Chain.mainnet/0` -> `https://acpx.virtuals.io`,
     `Raxol.ACP.Chain.sepolia/0` -> `https://acpx.virtuals.gg`)
  4. Hardcoded mainnet fallback `https://acpx.virtuals.io`

  `seller_backend_auth` is the Socket.IO auth payload; `nil` connects
  anonymously.

  ## Event translation

  | server event   | translated message                                                   |
  |----------------|----------------------------------------------------------------------|
  | `onNewTask`    | `{:acp_event, %{type: :job_offered, job_id, request, buyer, offering}}` |
  | `onEvaluate`   | `{:acp_event, %{type: :approval_received, job_id, payload}}`         |

  Only the fields `Raxol.ACP.Seller.Queue` reads off the event are
  populated. The original Socket.IO `AcpJobEventData` map is included
  under `:raw` so callers can inspect anything the translator dropped.

  ## Lifecycle

  Self-contained: each `subscribe/1` call adds a monitored pid;
  `unsubscribe/1` and `:DOWN` clean up. The Connection is started on
  `init/1` and reconnects with backoff on its own; the WebSocket
  module just forwards.
  """

  use GenServer

  @behaviour Raxol.ACP.Seller.Backend

  alias Raxol.ACP.Chain
  alias Raxol.ACP.Seller.Backend.WebSocket.Connection

  require Logger

  @fallback_url "https://acpx.virtuals.io"

  defstruct subscribers: %{},
            connection: nil,
            ready?: false,
            opts: []

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Raxol.ACP.Seller.Backend
  def subscribe(pid) when is_pid(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @impl Raxol.ACP.Seller.Backend
  def unsubscribe(pid) when is_pid(pid), do: GenServer.call(__MODULE__, {:unsubscribe, pid})

  @impl Raxol.ACP.Seller.Backend
  def subscriber_count, do: GenServer.call(__MODULE__, :subscriber_count)

  @doc "Return the inner Connection pid (test/debug only)."
  @spec connection() :: pid() | nil
  def connection, do: GenServer.call(__MODULE__, :connection)

  @doc "Return the readiness flag (handshake complete?)."
  @spec ready?() :: boolean()
  def ready?, do: GenServer.call(__MODULE__, :ready?)

  # -- GenServer callbacks --

  @impl GenServer
  def init(opts) do
    url = resolve_url(opts)
    auth = Keyword.get(opts, :auth) || Application.get_env(:raxol_acp, :seller_backend_auth)

    conn_opts = [
      url: url,
      auth: auth,
      parent: self(),
      reconnect_base_ms: Keyword.get(opts, :reconnect_base_ms, 500),
      reconnect_max_ms: Keyword.get(opts, :reconnect_max_ms, 30_000)
    ]

    {:ok, pid} = Connection.start_link(conn_opts)
    # Take over the link explicitly so WebSocket can drop Connection on
    # terminate without GenServer.stop's reason propagating to the outer
    # caller. The Process.monitor below is what surfaces restarts.
    Process.unlink(pid)
    _ref = Process.monitor(pid)

    {:ok, %__MODULE__{connection: pid, opts: opts}}
  end

  @impl GenServer
  def terminate(_reason, %{connection: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        500 -> :ok
      end
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  @doc false
  # Exposed for unit tests; not part of the public API.
  def resolve_url(opts) do
    cond do
      url = Keyword.get(opts, :url) -> url
      url = Application.get_env(:raxol_acp, :seller_backend_url) -> url
      url = chain_socket_url() -> url
      true -> @fallback_url
    end
  end

  @doc false
  def chain_socket_url do
    case Application.get_env(:raxol_acp, :chain, :mainnet) do
      :mainnet -> Chain.mainnet()[:acp_socket_url]
      :sepolia -> Chain.sepolia()[:acp_socket_url]
      _other -> nil
    end
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    case Map.get(state.subscribers, pid) do
      nil ->
        ref = Process.monitor(pid)
        {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}

      _ref ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        {:reply, :ok, state}

      {ref, rest} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | subscribers: rest}}
    end
  end

  def handle_call(:subscriber_count, _from, state),
    do: {:reply, map_size(state.subscribers), state}

  def handle_call(:connection, _from, state), do: {:reply, state.connection, state}
  def handle_call(:ready?, _from, state), do: {:reply, state.ready?, state}

  @impl GenServer
  def handle_info({:acp_ws, :ready}, state) do
    {:noreply, %{state | ready?: true}}
  end

  def handle_info({:acp_ws, {:disconnected, _reason}}, state) do
    {:noreply, %{state | ready?: false}}
  end

  def handle_info({:acp_ws, {:reconnecting, _attempt, _delay_ms}}, state) do
    {:noreply, state}
  end

  def handle_info({:acp_ws, {:event, name, args, _ack_id}}, state) do
    case translate(name, args) do
      {:ok, event} -> broadcast(state, event)
      :skip -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:acp_ws, _other}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- Event translation --

  # `onNewTask` carries the buyer's request. We surface it as
  # `:job_offered` for the Queue. Offering name comes from the
  # event's `context.offering` (where openclaw's
  # `resolveOfferingName/1` reads it).
  defp translate("onNewTask", [%{} = data | _]) do
    {:ok,
     %{
       type: :job_offered,
       job_id: data["id"] |> to_string(),
       offering: get_in(data, ["context", "offering"]) || "",
       request: get_in(data, ["context", "requirements"]) || %{},
       buyer: data["clientAddress"],
       raw: data
     }}
  end

  # `onEvaluate` fires when the buyer (or evaluator) approves. We
  # surface it as `:approval_received`.
  defp translate("onEvaluate", [%{} = data | _]) do
    {:ok,
     %{
       type: :approval_received,
       job_id: data["id"] |> to_string(),
       payload: get_in(data, ["context", "deliverable"]) || %{},
       raw: data
     }}
  end

  defp translate(_name, _args), do: :skip

  defp broadcast(state, event) do
    msg = {:acp_event, event}

    for pid <- Map.keys(state.subscribers) do
      send(pid, msg)
    end

    :ok
  end
end
