defmodule Raxol.AgentClientProtocol.Transport.Paired do
  @moduledoc """
  An in-process, zero-copy pair of `Raxol.AgentClientProtocol.Transport`
  handles. This is the test backbone for the rest of the library and the
  BEAM-local wiring for an agent/client pair that live in the same VM.

  `create_pair/0` starts two lightweight `GenServer`s — one per side — and
  links them to each other as peers. A message sent on the left handle is
  delivered to the right handle's owner (and vice versa), preserving send
  order. No JSON encoding happens anywhere in this module: Elixir maps
  pass straight through by reference. Byte-level codec correctness
  (encoding, framing, partial reads) is exercised by the stdio transport
  instead, not here.

  ## Ownership

  A freshly created handle has no owner (`nil`): messages arriving before
  an owner is set are silently dropped, by design, so a supervisor can
  create the pair before the `Connection` process that will adopt it
  exists. Call `set_owner/2` to adopt (or re-adopt — handoff to a new
  owner is supported at any time, including mid-stream).

  ## Ordering

  Erlang guarantees that messages sent between any two given processes
  arrive in send order. `send_message/2` accepts a frame locally (a
  single, non-nested `GenServer.call/2`) and hands it off to the peer's
  side with `GenServer.cast/2`. Because a side handles its own incoming
  `:send` calls one at a time, in arrival order, the casts it issues to
  the peer land on the peer's mailbox in that same order — so a single
  sending process sees strict order preserved end to end, with no
  explicit sequence number needed.

  This deliberately avoids a synchronous call *into* the peer from
  inside a side's own `handle_call/3`: two sides calling each other
  synchronously at the same time is a classic mutual-deadlock — each
  side blocks inside its callback waiting on the other, and neither can
  drain its mailbox to answer. Keeping the peer hop async (`cast`) is
  what makes simultaneous bidirectional traffic (both ends sending at
  once) safe.

  ## Closing

  `close/1` is idempotent and marks the local side closed immediately.
  It also notifies the peer (a cast), which marks *itself* closed and
  delivers `{:closed, :peer_closed}` to its own owner — the side that
  calls `close/1` does not message its own owner. Once a side's `closed`
  flag is set (locally, by `close/1`, or asynchronously via the peer
  notification), further `send_message/2` calls through it return
  `{:error, :closed}`, and any `:deliver` that arrives after closing is
  dropped rather than reaching the owner. The underlying processes are
  not killed by `close/1`; a handle remains a valid (but permanently
  closed) tuple that can still be inspected.
  """

  use GenServer

  @behaviour Raxol.AgentClientProtocol.Transport

  @type t :: %__MODULE__{pid: pid()}
  defstruct [:pid]

  @typep server_state :: %{
           owner: pid() | nil,
           peer: pid() | nil,
           closed: boolean()
         }

  @doc """
  Create a connected pair of transport handles: `{left, right}`.

  Neither handle has an owner yet — call `set_owner/2` on each before
  relying on inbound delivery.
  """
  @spec create_pair() :: {t(), t()}
  def create_pair do
    {:ok, left_pid} = GenServer.start_link(__MODULE__, initial_state())
    {:ok, right_pid} = GenServer.start_link(__MODULE__, initial_state())

    :ok = GenServer.call(left_pid, {:set_peer, right_pid})
    :ok = GenServer.call(right_pid, {:set_peer, left_pid})

    {%__MODULE__{pid: left_pid}, %__MODULE__{pid: right_pid}}
  end

  @doc """
  Set (or replace) the owner process for a handle. The owner is the
  process that will receive `{:acp_transport, transport_ref, ...}`
  messages for this handle going forward.
  """
  @spec set_owner(t(), pid()) :: :ok
  def set_owner(%__MODULE__{pid: pid}, owner) when is_pid(owner) do
    GenServer.call(pid, {:set_owner, owner})
  end

  @impl Raxol.AgentClientProtocol.Transport
  @spec send_message(t(), map()) :: {:ok, t()} | {:error, term()}
  def send_message(%__MODULE__{pid: pid} = state, message) when is_map(message) do
    case GenServer.call(pid, {:send, message}) do
      :ok -> {:ok, state}
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, {:transport_down, reason}}
  end

  @impl Raxol.AgentClientProtocol.Transport
  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
    if Process.alive?(pid) do
      GenServer.call(pid, :close)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  # -- GenServer callbacks ---------------------------------------------

  @impl GenServer
  @spec init(server_state()) :: {:ok, server_state()}
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:set_peer, peer_pid}, _from, state) when is_pid(peer_pid) do
    {:reply, :ok, %{state | peer: peer_pid}}
  end

  def handle_call({:set_owner, owner}, _from, state) when is_pid(owner) do
    {:reply, :ok, %{state | owner: owner}}
  end

  def handle_call({:send, _message}, _from, %{closed: true} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:send, message}, _from, %{peer: peer} = state) do
    forward_to_peer(peer, message)
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, %{closed: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, %{peer: peer} = state) do
    notify_peer_closed(peer)
    {:reply, :ok, %{state | closed: true}}
  end

  @impl GenServer
  def handle_cast({:deliver, _message}, %{closed: true} = state), do: {:noreply, state}

  def handle_cast({:deliver, message}, %{owner: owner} = state) do
    deliver_to_owner(owner, {:message, message})
    {:noreply, state}
  end

  def handle_cast(:peer_closed, %{closed: true} = state), do: {:noreply, state}

  def handle_cast(:peer_closed, %{owner: owner} = state) do
    deliver_to_owner(owner, {:closed, :peer_closed})
    {:noreply, %{state | closed: true}}
  end

  # -- Helpers ------------------------------------------------------------

  @spec initial_state() :: server_state()
  defp initial_state, do: %{owner: nil, peer: nil, closed: false}

  @spec forward_to_peer(pid() | nil, map()) :: :ok
  defp forward_to_peer(nil, _message), do: :ok

  defp forward_to_peer(peer, message) do
    GenServer.cast(peer, {:deliver, message})
    :ok
  end

  @spec notify_peer_closed(pid() | nil) :: :ok
  defp notify_peer_closed(nil), do: :ok

  defp notify_peer_closed(peer) do
    GenServer.cast(peer, :peer_closed)
    :ok
  end

  @spec deliver_to_owner(pid() | nil, {:message, map()} | {:closed, term()}) :: :ok
  defp deliver_to_owner(nil, _payload), do: :ok

  defp deliver_to_owner(owner, payload) do
    send(owner, {:acp_transport, self(), payload})
    :ok
  end
end
