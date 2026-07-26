defmodule Raxol.Gateway.Adapter.Email.ThreadStore do
  @moduledoc """
  Remembers the last inbound message per email conversation so an outbound
  reply can thread against it.

  `Raxol.Gateway.Adapter.Email.send_message/3` cannot learn the inbound
  `Message-ID` from its arguments -- the `Raxol.Gateway.Adapter` contract is
  frozen at `(conn, route, rendered)`. This store closes that gap: the inbound
  feed's wiring records each normalized message here (keyed by the conversation
  address), and the adapter reads it back at send time through the `conn`'s
  `:thread_lookup` function, which `thread_lookup_fn/1` builds.

  The store is a small in-memory cap map (one entry per conversation address,
  most-recently-seen wins), bounded by `:max_entries` (default 10_000) with
  oldest-recorded eviction. It holds only mail metadata (`Message-ID`,
  references, subject) -- never message bodies.

  ## Wiring

      {:ok, store} = ThreadStore.start_link(name: MyThreads)

      on_message = fn raw ->
        case Email.normalize_event(raw) do
          {:ok, route, event} ->
            ThreadStore.record_event(store, route, event)
            SessionRouter.route(router, route, event)

          :ignore ->
            :ok
        end
      end

      {:ok, conn} =
        Email.connect(
          relay: relay,
          from: from,
          thread_lookup: ThreadStore.thread_lookup_fn(store)
        )
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Gateway.Route

  @default_max_entries 10_000

  @type meta :: %{optional(atom()) => term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Record the inbound message `meta` for a conversation `key`."
  @spec record(GenServer.server(), String.t(), meta()) :: :ok
  def record(server, key, meta) when is_binary(key) and is_map(meta) do
    GenServer.call(server, {:record, key, meta})
  end

  @doc """
  Record the inbound message from a normalized `{route, event}`.

  A no-op unless the event carries the `:email` metadata `normalize_event/1`
  produces, so it is safe to call on every routed event.
  """
  @spec record_event(GenServer.server(), Route.t() | map(), map()) :: :ok
  def record_event(server, %{chat_id: key}, %{email: meta}) when is_map(meta) do
    record(server, to_string(key), meta)
  end

  def record_event(_server, _route, _event), do: :ok

  @doc "The recorded inbound message for `key`, or `:none`."
  @spec lookup(GenServer.server(), String.t()) :: {:ok, meta()} | :none
  def lookup(server, key) when is_binary(key) do
    GenServer.call(server, {:lookup, key})
  end

  @doc """
  A `(route -> meta | nil)` function for `Email.connect`'s `:thread_lookup`.

  Resolves the reply-threading metadata for a route by its `chat_id` (the
  conversation address); `nil` when nothing has been recorded yet.
  """
  @spec thread_lookup_fn(GenServer.server()) :: (map() -> meta() | nil)
  def thread_lookup_fn(server) do
    fn %{chat_id: key} ->
      case lookup(server, to_string(key)) do
        {:ok, meta} -> meta
        :none -> nil
      end
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    {:ok,
     %{
       entries: %{},
       order: [],
       max: Keyword.get(opts, :max_entries, @default_max_entries)
     }}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:record, key, meta}, _from, state) do
    {:reply, :ok, put_entry(state, key, meta)}
  end

  def handle_manager_call({:lookup, key}, _from, state) do
    reply =
      case Map.fetch(state.entries, key) do
        {:ok, meta} -> {:ok, meta}
        :error -> :none
      end

    {:reply, reply, state}
  end

  # Most-recent key at the head of `order`; on overflow drop the tail (oldest
  # recorded) so memory is bounded by `:max_entries` regardless of sender count.
  defp put_entry(state, key, meta) do
    order = [key | Enum.reject(state.order, &(&1 == key))]
    entries = Map.put(state.entries, key, meta)

    if map_size(entries) > state.max do
      {kept, dropped} = Enum.split(order, state.max)
      %{state | entries: Map.drop(entries, dropped), order: kept}
    else
      %{state | entries: entries, order: order}
    end
  end
end
