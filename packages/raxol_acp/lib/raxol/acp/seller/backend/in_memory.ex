defmodule Raxol.ACP.Seller.Backend.InMemory do
  @moduledoc """
  In-process implementation of `Raxol.ACP.Seller.Backend`.

  Holds a `MapSet` of subscriber pids and forwards every published
  event to all of them as `{:acp_event, event}`. Subscribers are
  monitored so a dead pid is dropped automatically.

  Not a mock: this is a second real implementation of the behaviour,
  same pattern as `Raxol.ACP.ContractClient.InMemory`. It is the
  primary tool for driving end-to-end seller flows in tests and in
  `mix raxol_acp.bench`. The live WebSocket impl lands later.

  ## Usage

      iex> InMemory.subscribe(self())
      :ok
      iex> InMemory.publish(%{type: :job_offered, job_id: "job-1", ...})
      :ok
      iex> flush()
      {:acp_event, %{type: :job_offered, ...}}
  """

  @behaviour Raxol.ACP.Seller.Backend

  use Raxol.Core.Behaviours.BaseManager

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send `event` to every subscriber. Returns `:ok` even when there are
  no subscribers.
  """
  @spec publish(Raxol.ACP.Seller.Backend.event()) :: :ok
  def publish(%{type: type} = event) when is_atom(type) do
    GenServer.call(__MODULE__, {:publish, event})
  end

  @doc "List currently subscribed pids. Intended for inspection / tests."
  @spec subscribers() :: [pid()]
  def subscribers do
    GenServer.call(__MODULE__, :subscribers)
  end

  @doc "Drop every subscriber. Intended for tests."
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # -- Behaviour callbacks --

  @impl Raxol.ACP.Seller.Backend
  def subscribe(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  @impl Raxol.ACP.Seller.Backend
  def unsubscribe(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:unsubscribe, pid})
  end

  @impl Raxol.ACP.Seller.Backend
  def subscriber_count do
    GenServer.call(__MODULE__, :subscriber_count)
  end

  # -- GenServer callbacks --

  @impl GenServer
  def init_manager(_opts) do
    {:ok, %{subscribers: %{}}}
  end

  @impl GenServer
  def handle_manager_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, put_subscriber(state, pid)}
  end

  def handle_manager_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, drop_subscriber(state, pid)}
  end

  def handle_manager_call(:subscriber_count, _from, state) do
    {:reply, map_size(state.subscribers), state}
  end

  def handle_manager_call(:subscribers, _from, state) do
    {:reply, Map.keys(state.subscribers), state}
  end

  def handle_manager_call({:publish, event}, _from, state) do
    for {pid, _ref} <- state.subscribers do
      send(pid, {:acp_event, event})
    end

    {:reply, :ok, state}
  end

  def handle_manager_call(:reset, _from, state) do
    for {_pid, ref} <- state.subscribers, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | subscribers: %{}}}
  end

  @impl GenServer
  def handle_manager_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.subscribers do
      %{^pid => ^ref} -> {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
      _ -> {:noreply, state}
    end
  end

  # -- Helpers --

  defp put_subscriber(state, pid) do
    case Map.fetch(state.subscribers, pid) do
      {:ok, _} ->
        state

      :error ->
        ref = Process.monitor(pid)
        %{state | subscribers: Map.put(state.subscribers, pid, ref)}
    end
  end

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        state

      {ref, rest} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: rest}
    end
  end
end
