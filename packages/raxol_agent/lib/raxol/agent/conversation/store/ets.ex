defmodule Raxol.Agent.Conversation.Store.ETS do
  @moduledoc """
  ETS-backed `Raxol.Agent.Conversation.Store` adapter.

  Items live in a named `ordered_set` keyed on `{conversation_id, seq}`, so
  iteration is naturally sequence-ordered within a conversation. Sequence
  allocation uses a sibling `set` and `:ets.update_counter/3` for atomic, 0-based
  per-conversation increments (the same pattern as `Raxol.Agent.ThreadLog.Ets`). A
  third `set` tracks known conversation ids for `list_conversations/1`.

  ## Config

      %{table: :my_conversation_items}

  Defaults to `:raxol_conversation_items`. Conversations sharing a table name
  share its items; isolate by passing distinct names.

  ## Lifetime

  Tables live for the duration of the BEAM; not supervised, not persisted. A
  durable adapter is a follow-up.
  """

  @behaviour Raxol.Agent.Conversation.Store

  alias Raxol.Agent.Conversation.Item

  @default_table :raxol_conversation_items

  @doc "Ensure the items, sequence-counter, and conversation-registry tables exist."
  @spec ensure_tables(map()) :: {atom(), atom(), atom()}
  def ensure_tables(config) do
    items = Map.get(config, :table, @default_table)
    counters = :"#{items}_seq"
    convs = :"#{items}_convs"

    ensure_table(items, [:ordered_set, :public, :named_table, read_concurrency: true])
    ensure_table(counters, [:set, :public, :named_table, write_concurrency: true])
    ensure_table(convs, [:set, :public, :named_table, read_concurrency: true])

    {items, counters, convs}
  end

  defp ensure_table(name, opts) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, opts)
      _ -> name
    end
  end

  @impl true
  def append(config, conversation_id, new_items) do
    {items, counters, convs} = ensure_tables(config)
    :ets.insert(convs, {conversation_id})

    materialized =
      Enum.map(new_items, fn attrs ->
        seq = next_sequence(counters, conversation_id)

        item =
          Item.new(
            conversation_id: conversation_id,
            seq: seq,
            type: Map.fetch!(attrs, :type),
            status: Map.get(attrs, :status, :completed),
            response_id: Map.get(attrs, :response_id),
            created_by: Map.get(attrs, :created_by),
            data: Map.get(attrs, :data, %{})
          )

        :ets.insert(items, {{conversation_id, seq}, item})
        item
      end)

    {:ok, materialized}
  end

  # 0-based atomic sequence allocation per conversation.
  defp next_sequence(counters, conversation_id) do
    :ets.update_counter(counters, conversation_id, {2, 1}, {conversation_id, -1})
  end

  @impl true
  def list_items(config, conversation_id, opts \\ []) do
    {items, _counters, _convs} = ensure_tables(config)
    after_seq = Keyword.get(opts, :after, -1)
    before = Keyword.get(opts, :before, :infinity)
    limit = Keyword.get(opts, :limit, 1_000)
    order = Keyword.get(opts, :order, :asc)
    type = Keyword.get(opts, :type)

    stream =
      items
      |> walk(conversation_id, after_seq, before)
      |> maybe_filter_type(type)

    result =
      case limit do
        :all -> Enum.to_list(stream)
        n when is_integer(n) and n >= 0 -> Enum.take(stream, n)
      end

    {:ok, maybe_reverse(result, order)}
  end

  @impl true
  def get_conversation(config, conversation_id) do
    {_items, counters, _convs} = ensure_tables(config)

    case :ets.lookup(counters, conversation_id) do
      [{^conversation_id, last_seq}] when last_seq >= 0 ->
        {:ok, %{id: conversation_id, last_seq: last_seq, item_count: last_seq + 1}}

      _ ->
        {:error, :not_found}
    end
  end

  @impl true
  def list_conversations(config) do
    {_items, _counters, convs} = ensure_tables(config)
    {:ok, for({id} <- :ets.tab2list(convs), do: id)}
  end

  # --- Walk helpers ---------------------------------------------------------

  defp walk(items, conversation_id, after_seq, before) do
    Stream.unfold({conversation_id, after_seq}, fn key ->
      next_in_conversation(items, conversation_id, before, key)
    end)
  end

  defp next_in_conversation(items, conversation_id, before, key) do
    case :ets.next(items, key) do
      :"$end_of_table" ->
        nil

      {^conversation_id, seq} = found when before == :infinity or seq < before ->
        [{^found, item}] = :ets.lookup(items, found)
        {item, found}

      {^conversation_id, _seq_at_or_past_before} ->
        nil

      _other_conversation ->
        nil
    end
  end

  defp maybe_filter_type(stream, nil), do: stream

  defp maybe_filter_type(stream, types) when is_list(types),
    do: Stream.filter(stream, &(&1.type in types))

  defp maybe_filter_type(stream, type),
    do: Stream.filter(stream, &(&1.type == type))

  defp maybe_reverse(list, :asc), do: list
  defp maybe_reverse(list, :desc), do: Enum.reverse(list)
end
