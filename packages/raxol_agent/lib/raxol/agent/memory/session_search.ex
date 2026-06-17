defmodule Raxol.Agent.Memory.SessionSearch do
  @moduledoc """
  Full-text recall over raw conversation history.

  Distinct from semantic memory (`Raxol.Agent.Memory.Store.Ets`, which recalls
  curated `Record`s), this is an inverted index over `Raxol.Agent.Conversation`
  item text. It answers "what did we say about X earlier" by returning the RAW
  matching items, not summaries.

  Items are tokenized with `Raxol.Agent.Memory.Record.tokenize/1` (the same
  tokenizer the semantic store uses) and ranked with the same length-normalized
  BM25-lite scoring. The index is fed either explicitly with `index/2`, or by
  `attach/3`, which subscribes to a `Raxol.Agent.Conversation.Log` and indexes
  its snapshot plus every appended item.

  ## Tables (derived from the registered name)

    * primary `:set` `{ {conversation_id, seq}, %{item, len} }`
    * `Tok` `:bag` `{token, {conversation_id, seq}}` -- inverted index
    * `DF` `:set` `{token, doc_freq}` plus `{:__N__, doc_count}` and
      `{:__DL__, total_doc_len}` for idf and average document length
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Agent.Memory.Record

  @k1 1.2
  @b 0.75
  @default_limit 10

  # -- Public API -------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Index a list of conversation items (each needs `conversation_id`, `seq`, `type`, `data`)."
  @spec index(GenServer.server(), [map()]) :: :ok
  def index(server \\ __MODULE__, items) when is_list(items) do
    GenServer.call(server, {:index, items})
  end

  @doc """
  Subscribe to a `Conversation.Log` and index its snapshot plus every appended
  item for `conversation_id`.
  """
  @spec attach(GenServer.server(), GenServer.server(), binary()) :: :ok
  def attach(server \\ __MODULE__, log, conversation_id) do
    GenServer.call(server, {:attach, log, conversation_id})
  end

  @doc """
  Full-text search over indexed items, returning the raw matching items ranked
  by relevance. Options: `:limit` (default 10), `:conversation_id` to scope to
  one conversation.
  """
  @spec search(GenServer.server(), String.t(), keyword()) :: [map()]
  def search(server \\ __MODULE__, query, opts \\ []) do
    GenServer.call(server, {:search, query, opts})
  end

  @doc "Remove every indexed item."
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  @doc "Derived ETS table names. Public for tests and tooling."
  @spec primary_table(atom()) :: atom()
  def primary_table(name) when is_atom(name), do: name
  @spec tok_table(atom()) :: atom()
  def tok_table(name) when is_atom(name), do: :"#{name}.Tok"
  @spec df_table(atom()) :: atom()
  def df_table(name) when is_atom(name), do: :"#{name}.DF"

  # -- BaseManager callbacks --------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(_opts) do
    name = registered_name!()
    tables = tables(name)

    :ets.new(tables.primary, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(tables.tok, [:named_table, :public, :bag, read_concurrency: true])
    :ets.new(tables.df, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(tables.df, [{:__N__, 0}, {:__DL__, 0}])

    {:ok, %{tables: tables}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:index, items}, _from, state) do
    Enum.each(items, &do_index(state.tables, &1))
    {:reply, :ok, state}
  end

  def handle_manager_call({:attach, log, conversation_id}, _from, state) do
    {:ok, %{snapshot: snapshot}} = log_subscribe(log, conversation_id)
    Enum.each(snapshot, &do_index(state.tables, &1))
    {:reply, :ok, state}
  end

  def handle_manager_call({:search, query, opts}, _from, state) do
    {:reply, do_search(state.tables, query, opts), state}
  end

  def handle_manager_call(:clear, _from, state) do
    Enum.each(
      [state.tables.primary, state.tables.tok, state.tables.df],
      &:ets.delete_all_objects/1
    )

    :ets.insert(state.tables.df, [{:__N__, 0}, {:__DL__, 0}])
    {:reply, :ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:conversation_item, _conversation_id, item}, state) do
    do_index(state.tables, item)
    {:noreply, state}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- indexing ---------------------------------------------------------------

  defp do_index(tables, item) do
    dockey = dockey(item)
    tokens = item |> item_text() |> Record.tokenize()

    cond do
      dockey == nil or tokens == [] -> :ok
      :ets.member(tables.primary, dockey) -> :ok
      true -> insert_doc(tables, dockey, item, tokens)
    end
  end

  defp insert_doc(tables, dockey, item, tokens) do
    :ets.insert(tables.primary, {dockey, %{item: item, len: length(tokens)}})

    Enum.each(tokens, fn token ->
      :ets.insert(tables.tok, {token, dockey})
      :ets.insert(tables.df, {token, df(tables, token) + 1})
    end)

    bump(tables.df, :__N__, 1)
    bump(tables.df, :__DL__, length(tokens))
    :ok
  end

  # -- search -----------------------------------------------------------------

  defp do_search(tables, query, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    scope = Keyword.get(opts, :conversation_id)
    n = df(tables, :__N__)

    case {Record.tokenize(query), n} do
      {[], _} -> []
      {_, 0} -> []
      {qtokens, n} -> ranked(tables, qtokens, n, scope, limit)
    end
  end

  defp ranked(tables, qtokens, n, scope, limit) do
    avgdl = max(df(tables, :__DL__) / n, 1.0)

    qtokens
    |> Enum.reduce(%{}, fn token, scores -> accumulate(tables, token, n, avgdl, scope, scores) end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {dockey, _score} -> doc_item(tables, dockey) end)
  end

  defp accumulate(tables, token, n, avgdl, scope, scores) do
    case df(tables, token) do
      0 ->
        scores

      doc_freq ->
        idf = :math.log((n - doc_freq + 0.5) / (doc_freq + 0.5) + 1)

        tables.tok
        |> :ets.lookup(token)
        |> Enum.map(&elem(&1, 1))
        |> Enum.filter(&in_scope?(&1, scope))
        |> Enum.reduce(scores, fn dockey, acc ->
          contribution = idf * norm(tables, dockey, avgdl)
          Map.update(acc, dockey, contribution, &(&1 + contribution))
        end)
    end
  end

  defp norm(tables, dockey, avgdl) do
    dl = doc_len(tables, dockey)
    (@k1 + 1) / (1 + @k1 * (1 - @b + @b * dl / avgdl))
  end

  defp in_scope?(_dockey, nil), do: true
  defp in_scope?({conversation_id, _seq}, scope), do: conversation_id == scope

  # -- item helpers -----------------------------------------------------------

  defp dockey(item) do
    case {Map.get(item, :conversation_id), Map.get(item, :seq)} do
      {cid, seq} when is_binary(cid) and is_integer(seq) -> {cid, seq}
      _ -> nil
    end
  end

  defp item_text(item) do
    data = Map.get(item, :data, %{})

    case Map.get(item, :type) do
      :message -> stringify(Map.get(data, :content))
      :reasoning -> stringify(Map.get(data, :text))
      :tool_result -> "#{Map.get(data, :name)} #{inspect(Map.get(data, :result))}"
      :tool_call -> "#{Map.get(data, :name)} #{inspect(Map.get(data, :arguments))}"
      _ -> ""
    end
  end

  defp stringify(text) when is_binary(text), do: text
  defp stringify(_), do: ""

  defp doc_item(tables, dockey) do
    case :ets.lookup(tables.primary, dockey) do
      [{^dockey, %{item: item}}] -> item
      [] -> nil
    end
  end

  defp doc_len(tables, dockey) do
    case :ets.lookup(tables.primary, dockey) do
      [{^dockey, %{len: len}}] -> len
      [] -> 0
    end
  end

  # -- ets helpers ------------------------------------------------------------

  defp df(tables, key) do
    case :ets.lookup(tables.df, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  defp bump(df_table, key, by), do: :ets.update_counter(df_table, key, by, {key, 0})

  defp tables(name) do
    %{primary: primary_table(name), tok: tok_table(name), df: df_table(name)}
  end

  defp log_subscribe(log, conversation_id) do
    Raxol.Agent.Conversation.Log.subscribe(log, conversation_id)
  end

  defp registered_name! do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] ->
        name

      _ ->
        raise """
        Raxol.Agent.Memory.SessionSearch must be started with a registered :name
        so its ETS tables can be derived. Use SessionSearch.start_link(name: :x)
        or rely on the default (Raxol.Agent.Memory.SessionSearch).
        """
    end
  end
end
