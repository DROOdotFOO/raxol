defmodule Raxol.Agent.Memory.Store.Ets do
  @moduledoc """
  Default cross-session memory provider: a self-contained ETS+DETS store.

  Follows the `Raxol.Payments.Mandate.Store` pattern: a GenServer owns writes,
  reads bypass through ETS directly (`read_concurrency: true`). Table names are
  derived from the registered name, so multiple instances can coexist via a
  distinct `:name`.

  ## Tables (derived from the server name)

    * primary `:set` `{id, record}`
    * `Tok` `:bag` `{token, id}` - inverted index
    * `Tag` `:bag` `{tag, id}`
    * `Agent` `:bag` `{agent_id, id}` - per-agent partition
    * `DF` `:set` `{token, doc_freq}` plus `{:__N__, doc_count}` and
      `{:__DL__, total_doc_len}` for IDF / average document length

  Only the primary records are persisted to DETS (`:dets_path` opt or the
  `:memory_store_path` Application key); every secondary index, including DF,
  is rebuilt from the primary records on open, so no stale index can survive a
  restart.

  ## Ranking (pure Elixir, no SQLite/NIF)

  `score = relevance + recency + tag_bonus`, where relevance is a length-
  normalized BM25-lite sum of IDF over matching query tokens, recency decays
  exponentially from `last_accessed`, and tag_bonus rewards tag overlap. An
  empty query degrades to recency-only most-recent-N (the `prefetch` default).
  """

  use Raxol.Core.Behaviours.BaseManager
  use Raxol.Agent.Memory

  alias Raxol.Agent.Memory.Record
  alias Raxol.Core.Stores.Dets

  @k1 1.2
  @b 0.75
  @default_limit 5
  @recency_weight 0.3
  @recency_halflife_days 30
  @tag_weight 0.5
  @seconds_per_day 86_400

  # -- Public API -------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Raxol.Agent.Memory
  def store(%Record{} = record, opts \\ []) do
    GenServer.call(server(opts), {:store, record})
  end

  @impl Raxol.Agent.Memory
  def forget(id, opts \\ []) when is_binary(id) do
    GenServer.call(server(opts), {:forget, id})
  end

  @impl Raxol.Agent.Memory
  def search(query, opts \\ []) do
    srv = server(opts)
    limit = Keyword.get(opts, :limit, @default_limit)
    agent_id = Keyword.get(opts, :agent_id)
    qtags = normalize_tags(Keyword.get(opts, :query_tags, []))

    results =
      case Record.tokenize(query) do
        [] -> recent(srv, agent_id, limit)
        qtokens -> ranked(srv, qtokens, qtags, agent_id, limit)
      end

    touch(srv, results)
    results
  end

  @doc "Remove all entries. Intended for tests."
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  @doc "Every stored record, in unspecified order."
  @spec list_all(atom()) :: [Record.t()]
  def list_all(server \\ __MODULE__) do
    server |> primary_table() |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
  end

  @doc "Derived ETS table names. Public for tests and tooling."
  @spec primary_table(atom()) :: atom()
  def primary_table(server) when is_atom(server), do: server
  @spec tok_table(atom()) :: atom()
  def tok_table(server) when is_atom(server), do: :"#{server}.Tok"
  @spec tag_table(atom()) :: atom()
  def tag_table(server) when is_atom(server), do: :"#{server}.Tag"
  @spec agent_table(atom()) :: atom()
  def agent_table(server) when is_atom(server), do: :"#{server}.Agent"
  @spec df_table(atom()) :: atom()
  def df_table(server) when is_atom(server), do: :"#{server}.DF"

  # -- BaseManager callbacks --------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    name = registered_name!()
    tables = tables(name)

    :ets.new(tables.primary, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(tables.tok, [:named_table, :public, :bag, read_concurrency: true])
    :ets.new(tables.tag, [:named_table, :public, :bag, read_concurrency: true])
    :ets.new(tables.agent, [:named_table, :public, :bag, read_concurrency: true])
    :ets.new(tables.df, [:named_table, :public, :set, read_concurrency: true])

    dets =
      case Dets.resolve_path(opts, :raxol_agent, :memory_store_path) do
        nil -> nil
        path -> Dets.open!(:"#{name}.Dets", path, &replay_record(tables, &1))
      end

    {:ok, %{tables: tables, dets: dets}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:store, %Record{} = record}, _from, state) do
    deindex(state.tables, record.id)
    :ets.insert(state.tables.primary, {record.id, record})
    index(state.tables, record)
    Dets.put(state.dets, record.id, record)
    {:reply, {:ok, record}, state}
  end

  def handle_manager_call({:forget, id}, _from, state) do
    deindex(state.tables, id)
    :ets.delete(state.tables.primary, id)
    Dets.delete(state.dets, id)
    {:reply, :ok, state}
  end

  def handle_manager_call(:clear, _from, state) do
    Enum.each(state.tables, fn {_key, table} -> :ets.delete_all_objects(table) end)
    Dets.clear(state.dets)
    {:reply, :ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:touch, ids}, state) do
    now = System.system_time(:second)
    Enum.each(ids, fn id -> bump_last_accessed(state.tables.primary, id, now) end)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state), do: Dets.close(state.dets)

  # -- Indexing ---------------------------------------------------------------

  defp index(tables, %Record{} = record) do
    tokens = Record.tokenize(record.content)
    Enum.each(tokens, &:ets.insert(tables.tok, {&1, record.id}))
    Enum.each(record.tags, &:ets.insert(tables.tag, {&1, record.id}))
    if record.agent_id, do: :ets.insert(tables.agent, {record.agent_id, record.id})
    adjust_df(tables.df, tokens, length(tokens), 1)
  end

  defp deindex(tables, id) do
    case :ets.lookup(tables.primary, id) do
      [{^id, %Record{} = prior}] ->
        tokens = Record.tokenize(prior.content)
        Enum.each(tokens, &:ets.match_delete(tables.tok, {&1, id}))
        Enum.each(prior.tags, &:ets.match_delete(tables.tag, {&1, id}))
        if prior.agent_id, do: :ets.match_delete(tables.agent, {prior.agent_id, id})
        adjust_df(tables.df, tokens, length(tokens), -1)

      [] ->
        :ok
    end
  end

  defp adjust_df(df, tokens, doc_len, sign) do
    Enum.each(tokens, fn t -> :ets.update_counter(df, t, {2, sign}, {t, 0}) end)
    :ets.update_counter(df, :__N__, {2, sign}, {:__N__, 0})
    :ets.update_counter(df, :__DL__, {2, sign * doc_len}, {:__DL__, 0})
  end

  defp bump_last_accessed(primary, id, now) do
    case :ets.lookup(primary, id) do
      [{^id, %Record{} = r}] -> :ets.insert(primary, {id, %{r | last_accessed: now}})
      [] -> :ok
    end
  end

  # -- Search -----------------------------------------------------------------

  defp recent(srv, agent_id, limit) do
    srv
    |> records_for_agent(agent_id)
    |> Enum.sort_by(& &1.last_accessed, :desc)
    |> Enum.take(limit)
  end

  defp ranked(srv, qtokens, qtags, agent_id, limit) do
    df = df_table(srv)
    n = counter(df, :__N__)
    avgdl = average_doc_len(df, n)

    srv
    |> candidate_ids(qtokens, agent_id)
    |> Enum.flat_map(&fetch(srv, &1))
    |> Enum.map(&%{&1 | score: score(&1, qtokens, qtags, df, n, avgdl)})
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp candidate_ids(srv, qtokens, agent_id) do
    tok = tok_table(srv)

    qtokens
    |> Enum.flat_map(&:ets.lookup(tok, &1))
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> filter_by_agent(srv, agent_id)
  end

  defp filter_by_agent(ids, _srv, nil), do: ids

  defp filter_by_agent(ids, srv, agent_id) do
    allowed =
      srv |> agent_table() |> :ets.lookup(agent_id) |> MapSet.new(&elem(&1, 1))

    Enum.filter(ids, &MapSet.member?(allowed, &1))
  end

  defp score(%Record{} = record, qtokens, qtags, df, n, avgdl) do
    relevance(record, qtokens, df, n, avgdl) + recency(record) + tag_bonus(record, qtags)
  end

  defp relevance(record, qtokens, df, n, avgdl) do
    doc_tokens = Record.tokenize(record.content)
    doc_set = MapSet.new(doc_tokens)
    dl = length(doc_tokens)
    norm = (@k1 + 1) / (1 + @k1 * (1 - @b + @b * dl / max(avgdl, 1.0)))

    qtokens
    |> Enum.filter(&MapSet.member?(doc_set, &1))
    |> Enum.reduce(0.0, fn token, acc -> acc + idf(counter(df, token), n) end)
    |> Kernel.*(norm)
  end

  defp idf(doc_freq, n), do: :math.log(1 + (n - doc_freq + 0.5) / (doc_freq + 0.5))

  defp recency(record) do
    age_days = (System.system_time(:second) - record.last_accessed) / @seconds_per_day
    @recency_weight * :math.exp(-age_days / @recency_halflife_days)
  end

  defp tag_bonus(_record, []), do: 0.0

  defp tag_bonus(record, qtags) do
    overlap =
      record.tags
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(qtags))
      |> MapSet.size()

    @tag_weight * overlap
  end

  defp average_doc_len(_df, n) when n <= 0, do: 1.0
  defp average_doc_len(df, n), do: max(counter(df, :__DL__) / n, 1.0)

  defp records_for_agent(srv, nil) do
    srv |> primary_table() |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
  end

  defp records_for_agent(srv, agent_id) do
    srv
    |> agent_table()
    |> :ets.lookup(agent_id)
    |> Enum.flat_map(fn {_agent, id} -> fetch(srv, id) end)
  end

  defp fetch(srv, id) do
    case :ets.lookup(primary_table(srv), id) do
      [{^id, record}] -> [record]
      [] -> []
    end
  end

  defp counter(df, key) do
    case :ets.lookup(df, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  defp touch(_srv, []), do: :ok
  defp touch(srv, results), do: GenServer.cast(srv, {:touch, Enum.map(results, & &1.id)})

  # -- Name + DETS resolution -------------------------------------------------

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)

  defp tables(name) do
    %{
      primary: primary_table(name),
      tok: tok_table(name),
      tag: tag_table(name),
      agent: agent_table(name),
      df: df_table(name)
    }
  end

  defp registered_name! do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] ->
        name

      _ ->
        raise """
        Raxol.Agent.Memory.Store.Ets must be started with a registered :name
        so its ETS tables can be derived. Use Store.Ets.start_link(name: :x)
        or rely on the default (Raxol.Agent.Memory.Store.Ets).
        """
    end
  end

  # Re-index one record read back from DETS on open. The secondary indices
  # (tok/tag/agent/df) are rebuilt from the primary records, so no stale index
  # can outlive a restart.
  defp replay_record(tables, {id, %Record{} = record}) do
    :ets.insert(tables.primary, {id, record})
    index(tables, record)
  end

  defp normalize_tags(tags) when is_list(tags) do
    Enum.map(tags, &(&1 |> to_string() |> String.downcase()))
  end

  defp normalize_tags(_), do: []
end
