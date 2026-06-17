defmodule Raxol.Agent.Conversation.Log do
  @moduledoc """
  Append-only conversation item log with live-tail-no-replay streaming.

  Wraps a `Raxol.Agent.Conversation.Store` (durability) with an in-process
  subscriber fan-out (liveness). The stream itself keeps NO replay buffer -- all
  history lives in the store. This is the omnigent model: durability in the store,
  the stream is ephemeral pub/sub.

  ## Exact snapshot/live-tail partition

  `subscribe/3` returns a snapshot AND registers the caller as a subscriber in a
  single serialized `GenServer.call`. Because `append/3` is also a serialized
  call, the two never interleave: a subscribe processed before an append excludes
  those items from its snapshot but receives them on the live tail; a subscribe
  processed after an append includes them in the snapshot and is NOT re-sent them.
  So a reconnecting client sees every item exactly once with no gap and no dupe --
  belt-and-suspenders deduping by `Item.id` is then trivial.

  Live items arrive as `{:conversation_item, conversation_id, item}` messages.
  Subscribers are monitored; their subscriptions are dropped automatically when
  they exit.

  ## Usage

      {:ok, log} = Log.start_link(name: MyLog)
      {:ok, %{snapshot: history, last_seq: cursor}} = Log.subscribe(log, "conv-1")
      {:ok, [item]} = Log.append(log, "conv-1", %{type: :message, data: %{content: "hi"}})
      # the subscriber's mailbox now holds {:conversation_item, "conv-1", item}

  Reconnect by passing the last seq seen: `Log.subscribe(log, conv, after: cursor)`.
  """

  use GenServer

  alias Raxol.Agent.Conversation.Store

  defstruct store: nil, subscribers: %{}, monitors: %{}

  @type server :: GenServer.server()
  @type conversation_id :: binary()

  # -- Public API -------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Append one item (a map) or a list of items; broadcasts to subscribers."
  @spec append(server(), conversation_id(), Store.new_item() | [Store.new_item()]) ::
          {:ok, [Raxol.Agent.Conversation.Item.t()]}
  def append(server, conversation_id, item) when is_map(item),
    do: append(server, conversation_id, [item])

  def append(server, conversation_id, items) when is_list(items),
    do: GenServer.call(server, {:append, conversation_id, items})

  @doc """
  Subscribe the caller to a conversation; returns its snapshot + last seq.

  Options: `:after` -- only snapshot items after this seq (for reconnect).
  """
  @spec subscribe(server(), conversation_id(), keyword()) ::
          {:ok, %{snapshot: [Raxol.Agent.Conversation.Item.t()], last_seq: integer() | nil}}
  def subscribe(server, conversation_id, opts \\ []),
    do: GenServer.call(server, {:subscribe, conversation_id, self(), opts})

  @doc "Stop receiving live items for a conversation."
  @spec unsubscribe(server(), conversation_id()) :: :ok
  def unsubscribe(server, conversation_id),
    do: GenServer.call(server, {:unsubscribe, conversation_id, self()})

  @doc "Page through stored items (passthrough to the store, no subscription)."
  @spec items(server(), conversation_id(), keyword()) ::
          {:ok, [Raxol.Agent.Conversation.Item.t()]}
  def items(server, conversation_id, opts \\ []),
    do: GenServer.call(server, {:items, conversation_id, opts})

  @doc "Conversation metadata (`%{id, last_seq, item_count}`) or `{:error, :not_found}`."
  @spec get_conversation(server(), conversation_id()) :: {:ok, map()} | {:error, :not_found}
  def get_conversation(server, conversation_id),
    do: GenServer.call(server, {:get_conversation, conversation_id})

  @doc "List known conversation ids."
  @spec list_conversations(server()) :: {:ok, [conversation_id()]}
  def list_conversations(server), do: GenServer.call(server, :list_conversations)

  # -- GenServer --------------------------------------------------------------

  @impl true
  def init(opts) do
    store = Store.normalize(Keyword.get(opts, :store, default_store()))
    {:ok, %__MODULE__{store: store}}
  end

  defp default_store, do: {Raxol.Agent.Conversation.Store.ETS, %{}}

  @impl true
  def handle_call({:append, conversation_id, new_items}, _from, state) do
    {:ok, items} = Store.append(state.store, conversation_id, new_items)
    broadcast(state, conversation_id, items)
    {:reply, {:ok, items}, state}
  end

  def handle_call({:subscribe, conversation_id, pid, opts}, _from, state) do
    list_opts = snapshot_opts(opts)
    {:ok, snapshot} = Store.list_items(state.store, conversation_id, list_opts)

    last_seq =
      case List.last(snapshot) do
        nil -> Keyword.get(opts, :after)
        item -> item.seq
      end

    state = add_subscriber(state, conversation_id, pid)
    {:reply, {:ok, %{snapshot: snapshot, last_seq: last_seq}}, state}
  end

  def handle_call({:unsubscribe, conversation_id, pid}, _from, state) do
    {:reply, :ok, remove_subscriber(state, conversation_id, pid)}
  end

  def handle_call({:items, conversation_id, opts}, _from, state) do
    {:reply, Store.list_items(state.store, conversation_id, opts), state}
  end

  def handle_call({:get_conversation, conversation_id}, _from, state) do
    {:reply, Store.get_conversation(state.store, conversation_id), state}
  end

  def handle_call(:list_conversations, _from, state) do
    {:reply, Store.list_conversations(state.store), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_pid(state, pid)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Subscriber bookkeeping -------------------------------------------------

  defp snapshot_opts(opts) do
    base = [limit: :all]

    case Keyword.get(opts, :after) do
      nil -> base
      after_seq -> [{:after, after_seq} | base]
    end
  end

  defp broadcast(state, conversation_id, items) do
    for pid <- Map.get(state.subscribers, conversation_id, MapSet.new()),
        item <- items do
      send(pid, {:conversation_item, conversation_id, item})
    end
  end

  defp add_subscriber(state, conversation_id, pid) do
    set = Map.get(state.subscribers, conversation_id, MapSet.new())

    if MapSet.member?(set, pid) do
      state
    else
      ref = Process.monitor(pid)

      %{
        state
        | subscribers: Map.put(state.subscribers, conversation_id, MapSet.put(set, pid)),
          monitors: Map.put(state.monitors, {pid, conversation_id}, ref)
      }
    end
  end

  defp remove_subscriber(state, conversation_id, pid) do
    set = state.subscribers |> Map.get(conversation_id, MapSet.new()) |> MapSet.delete(pid)

    monitors =
      case Map.pop(state.monitors, {pid, conversation_id}) do
        {nil, monitors} ->
          monitors

        {ref, monitors} ->
          Process.demonitor(ref, [:flush])
          monitors
      end

    %{state | subscribers: Map.put(state.subscribers, conversation_id, set), monitors: monitors}
  end

  defp drop_pid(state, pid) do
    subscribers =
      Map.new(state.subscribers, fn {conv, set} -> {conv, MapSet.delete(set, pid)} end)

    monitors =
      state.monitors
      |> Enum.reject(fn {{p, _conv}, _ref} -> p == pid end)
      |> Map.new()

    %{state | subscribers: subscribers, monitors: monitors}
  end
end
