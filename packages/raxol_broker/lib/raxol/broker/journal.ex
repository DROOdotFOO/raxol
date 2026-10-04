defmodule Raxol.Broker.Journal do
  @moduledoc """
  The broker's decision journal: one hash-chained `Raxol.Agent.Journal.FileStore`
  per install, at `~/.raxol/broker/journal` (`$RAXOL_BROKER_JOURNAL` or the
  `:path` option).

  Every order decision is a group of consecutive records sharing a
  `group_id`: the intent, a snapshot of the policy context, each verdict
  (`:pre_review`, then `:post_review`), the review response, and a terminal
  record (the order response, a DENY verdict, or a close). This process is
  the journal's only appender, so a group written with `append_group/1` is
  one Writer call and lands contiguously. A write-ahead caller opens the
  group with `open_group/2` before any review or order call and adds records
  with `append_to_group/2` as they happen; every broker record is synced to
  disk before the call returns.

  ## Recovery

  On start the chain is verified. A damaged journal (`{:damaged, offset}`)
  keeps the process up but refuses every append and every query: no order
  can be sized against a journal that cannot be trusted. On a healthy
  journal, every group left open by a crash is closed before anything else
  is written:

    * no post-review ALLOW yet: closed as DENY `crash_before_verdict`;
    * a post-review ALLOW but no order response: closed as
      `crash_outcome_unknown`. The order call may have gone out, so the
      group counts toward notional and order rate until reconciled.

  ## Index

  Queries read an ETS table (named after the server) built from the journal
  on start and kept current on append. Placed and unknown-outcome groups count
  toward `today_notional/1` and `orders_last_minute/1`, cancels never do, and
  `realized_pnl_today/1` sums `append_fill/1` records. The exchange-day
  boundary is the caller's: pass the start of the day as a UTC instant.
  Queries return `{:error, reason}` while the journal is damaged or not
  running; a policy context left `nil` then denies.

  Arming (#1179) must check `verify/1` first: it walks the chain on disk now,
  where `status/1` reports what was found at start.
  """

  use GenServer

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.OperatorFile
  alias Raxol.Broker.{Intent, Policy}
  alias Raxol.Broker.Journal.{Codec, Groups}
  alias Raxol.Broker.Policy.Context

  @types ~w(intent context verdict review order close fill)
  @phases [:pre_review, :post_review]
  @minute_us 60_000_000

  @type server :: atom()
  @type group_id :: String.t()
  @type entry ::
          {:verdict, :pre_review | :post_review, Policy.result()}
          | {:review, map()}
          | {:order, :placed | :failed, map()}
          | {:close, atom()}
  @type group :: %{intent: Intent.t(), context: Context.t(), entries: [entry()]}
  @type fill :: %{
          order_id: String.t(),
          symbol: String.t(),
          side: :buy | :sell,
          qty: Decimal.t(),
          price: Decimal.t(),
          realized_pnl: Decimal.t()
        }
  @type status :: :ok | {:damaged, pos_integer()} | {:error, term()}

  # -- Lifecycle ----------------------------------------------------------------

  @doc """
  Start the journal. Options: `:name` (default `#{inspect(__MODULE__)}`, also
  the ETS table name), `:path`, and `:clock`, a zero-arity function returning
  the UTC `DateTime` stamped on records (default `DateTime.utc_now/0`).
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The journal directory: `:path`, `$RAXOL_BROKER_JOURNAL`, or `~/.raxol/broker/journal`."
  @spec path(keyword()) :: Path.t() | nil
  def path(opts \\ []),
    do: Keyword.get(opts, :path) || OperatorFile.path("RAXOL_BROKER_JOURNAL", "broker/journal")

  @doc "Split a journal path into `{base_dir, session_id}` for FileStore's read-side functions."
  @spec location(Path.t()) :: {Path.t(), String.t()}
  def location(path) do
    path = Path.expand(path)
    {Path.dirname(path), Path.basename(path)}
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    with path when is_binary(path) <- path(opts) || {:error, :no_journal_path},
         {base, session} = location(path),
         {:ok, handle} <-
           FileStore.open(session,
             base_dir: base,
             chain: true,
             immediate_sync_types: @types,
             title: "raxol broker journal"
           ) do
      table = :ets.new(name, [:named_table, :ordered_set, :protected, read_concurrency: true])

      state = %{
        handle: handle,
        table: table,
        clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
        open: %{},
        status: :ok
      }

      {:ok, recover(state)}
    else
      {:error, reason} -> {:stop, {:journal_open_failed, reason}}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    FileStore.close(state.handle)
  catch
    :exit, _ -> :ok
  end

  # -- Writes -------------------------------------------------------------------

  @doc """
  Write the intent and its context snapshot, durable before any review or
  order call. Returns the new group's id.
  """
  @spec open_group(Intent.t(), Context.t(), server()) :: {:ok, group_id()} | {:error, term()}
  def open_group(%Intent{} = intent, %Context{} = context, server \\ __MODULE__),
    do: GenServer.call(server, {:append_group, intent, context, []})

  @doc """
  Add one record to an open group: a verdict, a review response, the order
  response, or a close (`{:close, reason}`, recorded as DENY). An order
  response, a close, or a DENY verdict finishes the group.
  """
  @spec append_to_group(group_id(), entry(), server()) :: :ok | {:error, term()}
  def append_to_group(group_id, entry, server \\ __MODULE__) when is_binary(group_id),
    do: GenServer.call(server, {:append_to_group, group_id, entry})

  @doc """
  Write a whole group (intent, context, then `entries` in order) as one
  contiguous run of records. Returns the group's id.
  """
  @spec append_group(group(), server()) :: {:ok, group_id()} | {:error, term()}
  def append_group(group, server \\ __MODULE__)

  def append_group(
        %{intent: %Intent{} = intent, context: %Context{} = context, entries: entries},
        server
      )
      when is_list(entries),
      do: GenServer.call(server, {:append_group, intent, context, entries})

  def append_group(other, _server), do: {:error, {:invalid_group, other}}

  @doc "Record a fill with the realized P&L the broker reported for it."
  @spec append_fill(fill(), server()) :: :ok | {:error, term()}
  def append_fill(fill, server \\ __MODULE__), do: GenServer.call(server, {:append_fill, fill})

  # -- Queries ------------------------------------------------------------------

  @doc "USD notional of counted orders at or after `since` (both sides)."
  @spec today_notional(DateTime.t(), server()) :: {:ok, Decimal.t()} | {:error, term()}
  def today_notional(%DateTime{} = since, server \\ __MODULE__) do
    with :ok <- healthy(server), do: {:ok, sum(server, :order, to_us(since))}
  end

  @doc "Counted orders in the 60 seconds ending at `now` (exclusive start, inclusive end)."
  @spec orders_last_minute(DateTime.t(), server()) :: {:ok, non_neg_integer()} | {:error, term()}
  def orders_last_minute(%DateTime{} = now, server \\ __MODULE__) do
    with :ok <- healthy(server) do
      to = to_us(now)
      from = to - @minute_us
      spec = [{{{:order, :"$1", :_}, :_}, [{:>, :"$1", from}, {:"=<", :"$1", to}], [true]}]
      {:ok, :ets.select_count(server, spec)}
    end
  end

  @doc "Realized P&L of fills at or after `since`."
  @spec realized_pnl_today(DateTime.t(), server()) :: {:ok, Decimal.t()} | {:error, term()}
  def realized_pnl_today(%DateTime{} = since, server \\ __MODULE__) do
    with :ok <- healthy(server), do: {:ok, sum(server, :fill, to_us(since))}
  end

  @doc """
  What start-up recovery found: `:ok`, `{:damaged, offset}`, or `{:error,
  reason}` when recovery or indexing failed.
  """
  @spec status(server()) :: status()
  def status(server \\ __MODULE__) do
    case :ets.lookup(server, :status) do
      [{:status, status}] -> status
      [] -> {:error, :journal_not_ready}
    end
  rescue
    ArgumentError -> {:error, :journal_not_running}
  end

  @doc """
  Walk the chain on disk now: `:ok` or `{:broken, offset}`. A break also marks
  the journal damaged, so later appends and queries are refused.
  """
  @spec verify(server()) :: :ok | {:broken, pos_integer()}
  def verify(server \\ __MODULE__), do: GenServer.call(server, :verify)

  # -- Server -------------------------------------------------------------------

  @impl GenServer
  def handle_call(:verify, _from, state) do
    case FileStore.verify(state.handle) do
      :ok -> {:reply, :ok, state}
      {:broken, offset} -> {:reply, {:broken, offset}, set_status(state, {:damaged, offset})}
    end
  end

  def handle_call(_request, _from, %{status: status} = state) when status != :ok,
    do: {:reply, {:error, refusal(status)}, state}

  def handle_call({:append_group, intent, context, entries}, _from, state) do
    id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    open = %{intent: intent, context: context, last: nil}
    head = group_head(state, id, intent, context)

    with {:ok, records, effect} <- apply_entries(entries, id, open, state),
         records = head ++ records,
         {:ok, _offsets} <- write(state, records) do
      {:reply, {:ok, id}, settle(state, id, open, effect, List.last(records))}
    else
      {:error, reason} -> {:reply, {:error, reason}, state_after(state, reason)}
    end
  end

  def handle_call({:append_to_group, id, entry}, _from, state) do
    with {:ok, open} <- fetch_open(state, id),
         {:ok, records, effect} <- apply_entries([entry], id, open, state),
         {:ok, _offsets} <- write(state, records) do
      {:reply, :ok, settle(state, id, open, effect, List.last(records))}
    else
      {:error, reason} -> {:reply, {:error, reason}, state_after(state, reason)}
    end
  end

  def handle_call({:append_fill, fill}, _from, state) do
    with {:ok, fields} <- encode_fill(fill),
         at = state.clock.(),
         record = %{"kind" => "broker", "type" => "fill", "at" => iso(at), "fill" => fields},
         {:ok, [offset]} <- write(state, [record]) do
      :ets.insert(state.table, {{:fill, to_us(at), offset}, fill.realized_pnl})
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state_after(state, reason)}
    end
  end

  # -- Entries ------------------------------------------------------------------

  defp group_head(state, id, intent, context) do
    [
      record(state, "intent", id, %{"intent" => Codec.encode_intent(intent)}),
      record(state, "context", id, %{"context" => Codec.encode_context(context)})
    ]
  end

  # Validate entries in order against the group's state and build their
  # records. The effect says how the group ends: still open (with its latest
  # verdict), placed, or otherwise finished.
  defp apply_entries(entries, id, open, state) do
    case Enum.reduce_while(
           entries,
           {:ok, [], {:open, open.last}},
           &apply_entry(&1, &2, id, state)
         ) do
      {:ok, records, effect} -> {:ok, Enum.reverse(records), effect}
      error -> error
    end
  end

  defp apply_entry(_entry, {:ok, _records, effect}, id, _state) when elem(effect, 0) != :open,
    do: {:halt, {:error, {:group_finished, id}}}

  defp apply_entry(entry, {:ok, records, {:open, last}}, id, state) do
    case entry_record(entry, last) do
      {:ok, type, fields, effect} ->
        {:cont, {:ok, [record(state, type, id, fields) | records], effect}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp entry_record({:verdict, phase, result}, _last) when phase in @phases do
    with {:ok, encoded} <- Codec.encode_result(result) do
      fields = %{
        "phase" => Atom.to_string(phase),
        "result" => encoded,
        "rule_ids" => Enum.map(Policy.rule_ids(), &Atom.to_string/1)
      }

      effect =
        if encoded["action"] == "deny", do: {:finished}, else: {:open, {phase, encoded["action"]}}

      {:ok, "verdict", fields, effect}
    end
  end

  defp entry_record({:review, response}, last) when is_map(response),
    do: {:ok, "review", %{"response" => Codec.term(response)}, {:open, last}}

  defp entry_record({:order, status, response}, _last)
       when status in [:placed, :failed] and is_map(response) do
    fields = %{"status" => Atom.to_string(status), "response" => Codec.term(response)}
    {:ok, "order", fields, if(status == :placed, do: {:placed}, else: {:finished})}
  end

  defp entry_record({:close, reason}, _last) when is_atom(reason) and not is_nil(reason),
    do: {:ok, "close", %{"reason" => Atom.to_string(reason), "outcome" => "deny"}, {:finished}}

  defp entry_record(entry, _last), do: {:error, {:invalid_entry, entry}}

  # Track the group after a successful write: keep it open or drop it, and
  # index a placed order.
  defp settle(state, id, open, {:open, last}, _record),
    do: %{state | open: Map.put(state.open, id, %{open | last: last})}

  defp settle(state, id, open, {:placed}, record) do
    state = %{state | open: Map.delete(state.open, id)}

    case index_order(state, id, open.intent, open.context, record["at"]) do
      :ok -> state
      {:error, reason} -> set_status(state, {:error, reason})
    end
  end

  defp settle(state, id, _open, {:finished}, _record),
    do: %{state | open: Map.delete(state.open, id)}

  defp fetch_open(state, id) do
    case Map.fetch(state.open, id) do
      {:ok, open} -> {:ok, open}
      :error -> {:error, {:unknown_or_finished_group, id}}
    end
  end

  defp encode_fill(%{order_id: order_id, symbol: symbol, side: side} = fill)
       when is_binary(order_id) and order_id != "" and side in [:buy, :sell] do
    decimals = [:qty, :price, :realized_pnl]

    if Intent.symbol?(symbol) and Enum.all?(decimals, &finite?(Map.get(fill, &1))) do
      {:ok,
       %{
         "order_id" => order_id,
         "symbol" => symbol,
         "side" => Atom.to_string(side),
         "qty" => Decimal.to_string(fill.qty),
         "price" => Decimal.to_string(fill.price),
         "realized_pnl" => Decimal.to_string(fill.realized_pnl)
       }}
    else
      {:error, {:invalid_fill, fill}}
    end
  end

  defp encode_fill(fill), do: {:error, {:invalid_fill, fill}}

  defp finite?(%Decimal{coef: coef}), do: is_integer(coef)
  defp finite?(_value), do: false

  # -- Recovery and index -------------------------------------------------------

  defp recover(state) do
    case FileStore.status(state.handle) do
      {:damaged, offset} -> set_status(state, {:damaged, offset})
      :ok -> recover_healthy(state)
    end
  end

  defp recover_healthy(state) do
    with {:ok, records} <- FileStore.read(state.handle),
         {groups, _fills} = Groups.fold(records),
         closes =
           for(group <- groups, Groups.outcome(group) == :open, do: crash_close(state, group)),
         {:ok, _offsets} <- write(state, closes),
         {:ok, records} <- reread(state, records, closes),
         :ok <- build_index(state, records) do
      set_status(state, :ok)
    else
      {:error, reason} -> set_status(state, damage_or(state, reason))
    end
  end

  defp crash_close(state, group) do
    {reason, outcome} = Groups.crash_close(group)
    record(state, "close", group.id, %{"reason" => reason, "outcome" => outcome})
  end

  defp reread(_state, records, []), do: {:ok, records}
  defp reread(state, _records, _closes), do: FileStore.read(state.handle)

  defp build_index(state, records) do
    {groups, fills} = Groups.fold(records)

    with :ok <- index_groups(state, Enum.filter(groups, &Groups.counts?/1)) do
      Enum.each(fills, fn %{"id" => offset, "at" => at, "fill" => fill} ->
        :ets.insert(
          state.table,
          {{:fill, parse_us(at), offset}, Decimal.new(fill["realized_pnl"])}
        )
      end)
    end
  end

  defp index_groups(state, groups) do
    Enum.reduce_while(groups, :ok, fn group, :ok ->
      with {:ok, intent} <- Codec.decode_intent(group.intent),
           {:ok, context} <- Codec.decode_context(group.context),
           :ok <- index_order(state, group.id, intent, context, Groups.counted_at(group)) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:unindexable_group, group.id, reason}}}
      end
    end)
  end

  defp index_order(_state, _id, %Intent{kind: :cancel}, _context, _at), do: :ok

  defp index_order(state, id, intent, context, at) do
    case Policy.notional(intent, context) do
      {:ok, notional} ->
        :ets.insert(state.table, {{:order, parse_us(at), id}, notional})
        :ok

      {:error, reason} ->
        {:error, {:unpriced_order, id, reason}}
    end
  end

  # -- Helpers ------------------------------------------------------------------

  defp record(state, type, id, fields) do
    Map.merge(fields, %{
      "kind" => "broker",
      "type" => type,
      "group_id" => id,
      "at" => iso(state.clock.())
    })
  end

  defp write(_state, []), do: {:ok, []}
  defp write(state, records), do: FileStore.append_many(state.handle, records)

  # A write the Writer refused as damaged means the chain broke under us.
  defp state_after(state, :damaged), do: set_status(state, damage_or(state, :damaged))
  defp state_after(state, _reason), do: state

  defp damage_or(state, reason) do
    case FileStore.status(state.handle) do
      {:damaged, offset} -> {:damaged, offset}
      :ok -> {:error, reason}
    end
  end

  defp set_status(state, status) do
    :ets.insert(state.table, {:status, status})
    %{state | status: status}
  end

  defp refusal({:damaged, offset}), do: {:journal_damaged, offset}
  defp refusal({:error, reason}), do: {:journal_unavailable, reason}

  defp healthy(server) do
    case status(server) do
      :ok -> :ok
      other -> {:error, refusal_or(other)}
    end
  end

  defp refusal_or({:error, reason}) when reason in [:journal_not_running, :journal_not_ready],
    do: reason

  defp refusal_or(status), do: refusal(status)

  defp sum(table, tag, from) do
    table
    |> :ets.select([{{{tag, :"$1", :_}, :"$2"}, [{:>=, :"$1", from}], [:"$2"]}])
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  defp to_us(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  defp parse_us(at) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(at)
    to_us(datetime)
  end
end
