defmodule Raxol.Broker.Journal do
  @moduledoc """
  The broker's decision journal: one hash-chained `Raxol.Agent.Journal.FileStore`
  per install, at `~/.raxol/broker/journal` (`$RAXOL_BROKER_JOURNAL` or the
  `:path` option), opened private (directory 0700, files 0600).

  Every order decision is a group of consecutive records sharing a
  `group_id`: the intent, a snapshot of the policy context, each verdict
  (`:pre_review`, then `:post_review`), the review response, any human
  approval of an ASK, a `placing` record, and a terminal record (the order
  response, a DENY verdict, a declined approval, or a close). This process is
  the journal's only appender, so a group written with `append_group/1` is
  one Writer call and lands contiguously. A write-ahead caller opens the
  group with `open_group/2` before any review or order call and adds records
  with `append_to_group/2` as they happen; every broker record is synced to
  disk before the call returns.

  ## Claim

  One executor writes orders per journal. `claim/1` claims the journal for
  the calling process and monitors it; the claim is released when that
  process exits. Only a `Raxol.Broker.Executor` may claim: a caller whose
  proc_lib initial call is not `{Raxol.Broker.Executor, :init, 1}` is
  refused with `{:error, :not_an_executor}`, so no other process can take a
  free claim and write `placing` through this public API. The same process
  may claim again; any other process is refused with
  `{:error, {:journal_claimed, pid}}` while the claimant lives. A claim is
  taken even on a damaged journal; `placing` is still refused there.

  Threat model: the BEAM cannot stop code that deliberately writes into
  another module's private state, e.g. `Process.put(:"$initial_call", ...)`
  in its own process or `:sys.replace_state/2` on this one. The guarantee is
  that no path through public APIs writes `placing` (and so sends an order)
  without the Executor's review pipeline; every remaining bypass requires
  impersonating the Executor's private process-dictionary slots on purpose.

  ## Write timeouts

  `open_group/4`, `append_to_group/4` and `append_group/3` wait `:infinity`
  by default (pass a timeout to override). A journal write is a local fsync,
  so a slow one is still progress, and a caller that gives up does not undo
  it: the request stays queued and lands later. A timed-out `placing` whose
  append lands after the caller closed the group would turn an order that
  was never sent into a counted unknown outcome and make its intent a
  permanent duplicate.

  ## Placing

  `{:placing}` is written immediately before the order call, and only when
  all of these hold (otherwise nothing is written):

    * the caller is the claimant (`{:error, {:not_claimant, id}}`);
    * the group has a `review` record and either its latest `:post_review`
      verdict is ALLOW or it has an approved `approval` record
      (`{:error, {:not_reviewed, id}}`);
    * no other group for the same intent id reached `placing` with an
      outcome other than `:failed` (`{:error, {:duplicate_intent, other_id}}`).

  The journal prices the order from the group's own intent and context
  (`Raxol.Broker.Policy.notional/2`) and records that notional; it refuses an
  order it cannot price (`{:error, {:unpriced_order, reason}}`), so nothing
  unpriced is ever sent. Cancels record a `nil` notional. After `placing` the
  only records a group takes are its order response (`:placed`, `:failed` or
  `:unknown`) or a close, and an order response is refused for a group with no
  `placing` record (`{:error, {:not_placing, id}}`). A close after `placing`
  records an `unknown` outcome: the order may exist.

  ## Recovery

  On start the chain is verified. A damaged journal (`{:damaged, offset}`)
  keeps the process up but refuses every append and every query: no order
  can be sized against a journal that cannot be trusted. On a healthy
  journal, every group left open by a crash is closed before anything else
  is written:

    * no `placing` record: closed as DENY `crash_before_verdict`, no order
      was sent;
    * a `placing` record but no order response: closed as
      `crash_outcome_unknown`. The order call may have gone out, so the
      group keeps counting toward notional and order rate.

  The journal traps exits: a supervisor shutdown closes the Writer it started,
  and if the Writer dies (including one this journal joined rather than
  started) the journal stops so its supervisor restarts it.

  ## Index

  Queries read an ETS table (named after the server) built from the journal
  on start and kept current on append. An order counts toward
  `today_notional/1` and `orders_last_minute/1` from its `placing` record, at
  that record's time and notional, until an order response says `:failed`;
  cancels never count. Only recorded notionals are used, never recomputed, so
  the live index and the one rebuilt on start agree. `realized_pnl_today/1`
  sums `append_fill/1` records. The exchange-day boundary is the caller's:
  pass the start of the day as a UTC instant. Queries return `{:error,
  reason}` while the journal is damaged or not running; a policy context left
  `nil` then denies.

  `placing_for_intent/2` answers whether a group for an intent id reached
  `placing` with an outcome other than `:failed`: the executor's idempotency
  check, so a re-run of the same intent after a restart never sends a second
  order, while an intent whose order definitely failed may be retried. The
  same index backs the duplicate-intent gate on `placing`.

  Arming (#1179) must check `verify/1` first: it walks the chain on disk now,
  where `status/1` reports what was found at start.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.OperatorFile
  alias Raxol.Broker.{Intent, Policy}
  alias Raxol.Broker.Journal.{Codec, Groups}
  alias Raxol.Broker.Policy.Context

  @types ~w(intent context verdict review approval placing order close fill)
  @phases [:pre_review, :post_review]
  @order_statuses [:placed, :failed, :unknown]
  @decisions [:approved, :declined]
  @before_placing [:verdict, :review, :approval, :placing]
  @minute_us 60_000_000

  @type server :: atom()
  @type group_id :: String.t()
  @type entry ::
          {:verdict, :pre_review | :post_review, Policy.result()}
          | {:review, map()}
          | {:approval, :approved | :declined, String.t()}
          | {:placing}
          | {:order, :placed | :failed | :unknown, map()}
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
    Process.flag(:trap_exit, true)
    name = Keyword.fetch!(opts, :name)

    with path when is_binary(path) <- path(opts) || {:error, :no_journal_path},
         {:ok, handle} <- open_store(path) do
      table = :ets.new(name, [:named_table, :ordered_set, :protected, read_concurrency: true])

      state = %{
        handle: handle,
        table: table,
        clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
        open: %{},
        claimant: nil,
        status: :ok
      }

      {:ok, recover(state)}
    else
      {:error, reason} -> {:stop, {:journal_open_failed, reason}}
    end
  end

  defp open_store(path) do
    {base, session} = location(path)

    opts = [
      base_dir: base,
      chain: true,
      private: true,
      immediate_sync_types: @types,
      title: "raxol broker journal"
    ]

    with {:ok, handle} <- FileStore.open(session, opts) do
      # A joined Writer was started by (and is linked to) another process:
      # link it here too, so its death stops this journal instead of leaving
      # it appending into a dead handle.
      unless handle.owner?, do: Process.link(handle.writer)
      {:ok, handle}
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

  `opts[:mode]` (`:dry_run` or `:armed`) is stored on the intent record and
  shown by replay; it is omitted when not given. `opts[:timeout]` bounds the
  call (default `:infinity`, see "Write timeouts").
  """
  @spec open_group(Intent.t(), Context.t(), server(), keyword()) ::
          {:ok, group_id()} | {:error, term()}
  def open_group(%Intent{} = intent, %Context{} = context, server \\ __MODULE__, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, :infinity)

    case Keyword.get(opts, :mode) do
      mode when mode in [nil, :dry_run, :armed] ->
        GenServer.call(server, {:append_group, intent, context, [], opts}, timeout)

      mode ->
        {:error, {:invalid_mode, mode}}
    end
  end

  @doc """
  Add one record to an open group (see `t:entry/0`):

    * `{:verdict, phase, result}`: a DENY finishes the group;
    * `{:review, response}`;
    * `{:approval, :approved | :declined, by}`: a human's answer to an ASK; a
      decline finishes the group as DENY;
    * `{:placing}`: written immediately before the order call; refused unless
      the caller is the claimant (`{:not_claimant, id}`), the group was
      reviewed and allowed or approved (`{:not_reviewed, id}`), and no other
      group placed this intent without failing (`{:duplicate_intent, other}`).
      The journal records the order's notional and counts it from here, and
      refuses with `{:unpriced_order, reason}` when a non-cancel intent cannot
      be priced;
    * `{:order, :placed | :failed | :unknown, response}`: finishes the group;
      refused with `{:not_placing, id}` before `{:placing}`. `:failed` stops
      the order counting and frees the intent for a retry;
    * `{:close, reason}`: finishes the group, as DENY before `{:placing}` and
      as an unknown outcome (still counted) after it.

  Only an order response or a close may follow `{:placing}`
  (`{:already_placing, id}` otherwise).

  `timeout` bounds the call (default `:infinity`, see "Write timeouts").
  """
  @spec append_to_group(group_id(), entry(), server(), timeout()) :: :ok | {:error, term()}
  def append_to_group(group_id, entry, server \\ __MODULE__, timeout \\ :infinity)
      when is_binary(group_id),
      do: GenServer.call(server, {:append_to_group, group_id, entry}, timeout)

  @doc """
  Write a whole group (intent, context, then `entries` in order) as one
  contiguous run of records, with the same rules as `append_to_group/2`.
  Returns the group's id. `timeout` bounds the call (default `:infinity`,
  see "Write timeouts").
  """
  @spec append_group(group(), server(), timeout()) :: {:ok, group_id()} | {:error, term()}
  def append_group(group, server \\ __MODULE__, timeout \\ :infinity)

  def append_group(
        %{intent: %Intent{} = intent, context: %Context{} = context, entries: entries},
        server,
        timeout
      )
      when is_list(entries),
      do: GenServer.call(server, {:append_group, intent, context, entries, []}, timeout)

  def append_group(other, _server, _timeout), do: {:error, {:invalid_group, other}}

  @doc "Record a fill with the realized P&L the broker reported for it."
  @spec append_fill(fill(), server()) :: :ok | {:error, term()}
  def append_fill(fill, server \\ __MODULE__), do: GenServer.call(server, {:append_fill, fill})

  @doc """
  Claim the journal for the calling process, the only one allowed to write
  `{:placing}`. Only a `Raxol.Broker.Executor` process may claim (proc_lib
  initial call `{Raxol.Broker.Executor, :init, 1}`); any other caller gets
  `{:error, :not_an_executor}`. Released when the claimant exits; the
  claimant may claim again. Returns `{:error, {:journal_claimed, pid}}` while
  another live process holds the claim.
  """
  @spec claim(server()) :: :ok | {:error, term()}
  def claim(server \\ __MODULE__), do: GenServer.call(server, :claim)

  # -- Queries ------------------------------------------------------------------

  @doc "USD notional of counted orders at or after `since` (both sides)."
  @spec today_notional(DateTime.t(), server()) :: {:ok, Decimal.t()} | {:error, term()}
  def today_notional(%DateTime{} = since, server \\ __MODULE__) do
    with :ok <- healthy(server), do: select(fn -> {:ok, sum(server, :order, to_us(since))} end)
  end

  @doc "Counted orders in the 60 seconds ending at `now` (exclusive start, inclusive end)."
  @spec orders_last_minute(DateTime.t(), server()) :: {:ok, non_neg_integer()} | {:error, term()}
  def orders_last_minute(%DateTime{} = now, server \\ __MODULE__) do
    with :ok <- healthy(server) do
      to = to_us(now)
      from = to - @minute_us
      spec = [{{{:order, :"$1", :_}, :_}, [{:>, :"$1", from}, {:"=<", :"$1", to}], [true]}]
      select(fn -> {:ok, :ets.select_count(server, spec)} end)
    end
  end

  @doc "Realized P&L of fills at or after `since`."
  @spec realized_pnl_today(DateTime.t(), server()) :: {:ok, Decimal.t()} | {:error, term()}
  def realized_pnl_today(%DateTime{} = since, server \\ __MODULE__) do
    with :ok <- healthy(server), do: select(fn -> {:ok, sum(server, :fill, to_us(since))} end)
  end

  @doc """
  The id of a group for `intent_id` that reached `placing` with an outcome
  other than `:failed`, or nil when none did.
  """
  @spec placing_for_intent(String.t(), server()) :: {:ok, group_id() | nil} | {:error, term()}
  def placing_for_intent(intent_id, server \\ __MODULE__) when is_binary(intent_id) do
    with :ok <- healthy(server), do: select(fn -> intent_placing(server, intent_id) end)
  end

  defp intent_placing(table, intent_id) do
    case :ets.lookup(table, {:intent_placing, intent_id}) do
      [{_key, group_id}] -> {:ok, group_id}
      [] -> {:ok, nil}
    end
  end

  @doc "Ids of the groups still open (no terminal record), oldest first."
  @spec open_groups(server()) :: {:ok, [group_id()]} | {:error, term()}
  def open_groups(server \\ __MODULE__), do: GenServer.call(server, :open_groups)

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
  Walk the chain on disk now: `:ok`, `{:broken, offset}`, or `{:error,
  reason}` when the chain cannot be checked at all (e.g. `:unchained`, the
  chain flag gone from `meta.json`). Anything but `:ok` also marks the journal
  damaged, so later appends and queries are refused.

  The walk reads the whole journal inside this process with no timeout, and
  every append waits behind it.
  """
  @spec verify(server()) :: :ok | {:broken, pos_integer()} | {:error, term()}
  def verify(server \\ __MODULE__), do: GenServer.call(server, :verify, :infinity)

  # -- Server -------------------------------------------------------------------

  @impl GenServer
  def handle_call(:verify, _from, state) do
    case FileStore.verify(state.handle) do
      :ok ->
        {:reply, :ok, state}

      {:broken, offset} ->
        {:reply, {:broken, offset}, set_status(state, {:damaged, offset})}

      {:error, reason} ->
        {:reply, {:error, reason}, set_status(state, {:error, {:unverifiable, reason}})}
    end
  end

  def handle_call(:claim, {pid, _tag}, state) do
    cond do
      not executor?(pid) ->
        {:reply, {:error, :not_an_executor}, state}

      match?({^pid, _ref}, state.claimant) ->
        {:reply, :ok, state}

      claimed_by_other?(state.claimant) ->
        {:reply, {:error, {:journal_claimed, elem(state.claimant, 0)}}, state}

      true ->
        {:reply, :ok, take_claim(state, pid)}
    end
  end

  def handle_call(_request, _from, %{status: status} = state) when status != :ok,
    do: {:reply, {:error, refusal(status)}, state}

  def handle_call(:open_groups, _from, state) do
    ids = state.open |> Enum.sort_by(fn {_id, group} -> group.seq end) |> Enum.map(&elem(&1, 0))
    {:reply, {:ok, ids}, state}
  end

  def handle_call({:append_group, intent, context, entries, opts}, {caller, _tag}, state) do
    id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    seq = System.unique_integer([:monotonic])
    group = new_group(intent, context, seq)
    head = group_head(state, id, intent, context, Keyword.get(opts, :mode))

    with {:ok, records, group} <- apply_entries(entries, id, group, gate(state, caller)),
         {:ok, _offsets} <- write(state, head ++ records) do
      {:reply, {:ok, id}, settle(state, id, group, records)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state_after(state, reason)}
    end
  end

  def handle_call({:append_to_group, id, entry}, {caller, _tag}, state) do
    with {:ok, group} <- fetch_open(state, id),
         {:ok, records, group} <- apply_entries([entry], id, group, gate(state, caller)),
         {:ok, _offsets} <- write(state, records) do
      {:reply, :ok, settle(state, id, group, records)}
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

  @impl GenServer
  def handle_info({:EXIT, writer, reason}, %{handle: %{writer: writer}} = state),
    do: {:stop, {:journal_writer_down, reason}, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{claimant: {pid, ref}} = state),
    do: {:noreply, %{state | claimant: nil}}

  def handle_info(message, state) do
    Logger.warning("#{inspect(__MODULE__)} ignored an unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # -- Claim --------------------------------------------------------------------

  # The claim goes only to a process started as `Raxol.Broker.Executor`
  # (proc_lib records its initial call). Reading another process's dictionary
  # is how the BEAM exposes that; a dead caller has none and is refused.
  defp executor?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        List.keyfind(dictionary, :"$initial_call", 0) ==
          {:"$initial_call", {Raxol.Broker.Executor, :init, 1}}

      nil ->
        false
    end
  end

  defp claimed_by_other?(nil), do: false
  defp claimed_by_other?({other, _ref}), do: Process.alive?(other)

  # A dead claimant's :DOWN may still be queued; drop it with the old monitor.
  defp take_claim(%{claimant: {_other, ref}} = state, pid) do
    Process.demonitor(ref, [:flush])
    take_claim(%{state | claimant: nil}, pid)
  end

  defp take_claim(state, pid), do: %{state | claimant: {pid, Process.monitor(pid)}}

  # -- Entries ------------------------------------------------------------------

  defp group_head(state, id, intent, context, mode) do
    intent_fields = %{"intent" => Codec.encode_intent(intent)}

    intent_fields =
      if mode, do: Map.put(intent_fields, "mode", mode_name(mode)), else: intent_fields

    [
      record(state, "intent", id, intent_fields),
      record(state, "context", id, %{"context" => Codec.encode_context(context)})
    ]
  end

  defp mode_name(:dry_run), do: "dry_run"
  defp mode_name(:armed), do: "armed"

  defp new_group(intent, context, seq) do
    %{
      intent: intent,
      context: context,
      placing: nil,
      finished?: false,
      seq: seq,
      reviewed?: false,
      post_action: nil,
      approved?: false
    }
  end

  # The state `entry_record/4` sees: whether the calling process holds the claim.
  defp gate(state, caller),
    do: Map.put(state, :claimant?, match?({^caller, _ref}, state.claimant))

  # Validate entries in order against the group's state and build their
  # records. The group state carries what the rules need: the group's own
  # intent and context (to price `placing`), whether it was reviewed, its
  # latest post-review action and whether an ASK was approved (to gate
  # `placing`), its `placing` record (an order response needs one; nothing but
  # an order response or a close may follow it) and whether a terminal record
  # has been written.
  defp apply_entries(entries, id, group, state) do
    Enum.reduce_while(entries, {:ok, [], group}, fn
      _entry, {:ok, _records, %{finished?: true}} ->
        {:halt, {:error, {:group_finished, id}}}

      entry, {:ok, records, group} ->
        case entry_record(entry, id, group, state) do
          {:ok, record, group} -> {:cont, {:ok, [record | records], group}}
          {:error, _} = error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, records, group} -> {:ok, Enum.reverse(records), group}
      error -> error
    end
  end

  defp entry_record(entry, id, %{placing: %{}}, _state)
       when is_tuple(entry) and tuple_size(entry) > 0 and elem(entry, 0) in @before_placing,
       do: {:error, {:already_placing, id}}

  defp entry_record({:verdict, phase, result}, id, group, state) when phase in @phases do
    with {:ok, encoded} <- Codec.encode_result(result) do
      fields = %{
        "phase" => Atom.to_string(phase),
        "result" => encoded,
        "rule_ids" => Enum.map(Policy.rule_ids(), &Atom.to_string/1)
      }

      group = finish_if(group, encoded["action"] == "deny")
      group = if phase == :post_review, do: %{group | post_action: encoded["action"]}, else: group
      {:ok, record(state, "verdict", id, fields), group}
    end
  end

  defp entry_record({:review, response}, id, group, state) when is_map(response) do
    record = record(state, "review", id, %{"response" => Codec.term(response)})
    {:ok, record, %{group | reviewed?: true}}
  end

  defp entry_record({:approval, decision, by}, id, group, state)
       when decision in @decisions and is_binary(by) and by != "" do
    fields = %{"decision" => Atom.to_string(decision), "by" => by}
    group = %{group | approved?: group.approved? or decision == :approved}
    {:ok, record(state, "approval", id, fields), finish_if(group, decision == :declined)}
  end

  defp entry_record({:placing}, id, group, state) do
    with :ok <- placing_allowed(id, group, state),
         {:ok, notional} <- placing_notional(group.intent, group.context) do
      record = record(state, "placing", id, %{"notional" => notional})
      {:ok, record, %{group | placing: record}}
    end
  end

  defp entry_record({:order, status, response}, id, group, state)
       when status in @order_statuses and is_map(response) do
    if group.placing do
      fields = %{"status" => Atom.to_string(status), "response" => Codec.term(response)}
      {:ok, record(state, "order", id, fields), finish_if(group, true)}
    else
      {:error, {:not_placing, id}}
    end
  end

  defp entry_record({:close, reason}, id, group, state)
       when is_atom(reason) and not is_nil(reason) do
    outcome = if group.placing, do: "unknown", else: "deny"
    fields = %{"reason" => Atom.to_string(reason), "outcome" => outcome}
    {:ok, record(state, "close", id, fields), finish_if(group, true)}
  end

  defp entry_record(entry, _id, _group, _state), do: {:error, {:invalid_entry, entry}}

  defp finish_if(group, finished?), do: %{group | finished?: finished?}

  defp placing_allowed(id, _group, %{claimant?: false}), do: {:error, {:not_claimant, id}}

  defp placing_allowed(id, %{reviewed?: true} = group, state)
       when group.post_action == "allow" or group.approved? do
    case :ets.lookup(state.table, {:intent_placing, group.intent.id}) do
      [{_key, other}] when other != id -> {:error, {:duplicate_intent, other}}
      _ -> :ok
    end
  end

  defp placing_allowed(id, _group, _state), do: {:error, {:not_reviewed, id}}

  # The notional recorded on `placing`: a decimal string, or nil for a cancel,
  # which never counts. Anything else that cannot be priced is not sent.
  defp placing_notional(%Intent{kind: :cancel}, _context), do: {:ok, nil}

  defp placing_notional(intent, context) do
    case Policy.notional(intent, context) do
      {:ok, notional} -> {:ok, Decimal.to_string(notional)}
      {:error, reason} -> {:error, {:unpriced_order, reason}}
    end
  end

  # After a successful write: keep the group open or drop it, count a
  # `placing` record and uncount a failed order. The same `index_placing/3`
  # builds the index on start, so both read the recorded notional.
  defp settle(state, id, group, records) do
    open =
      if group.finished?,
        do: Map.delete(state.open, id),
        else: Map.put(state.open, id, group)

    state = %{state | open: open}

    Enum.reduce(records, state, fn
      %{"type" => "placing"} = placing, state ->
        :ets.insert(state.table, {{:intent_placing, group.intent.id}, id})

        case index_placing(state.table, id, placing) do
          :ok -> state
          {:error, reason} -> set_status(state, {:error, reason})
        end

      %{"type" => "order", "status" => "failed"}, state ->
        :ets.delete_object(state.table, {{:intent_placing, group.intent.id}, id})
        uncount(state, id, group.placing)

      _record, state ->
        state
    end)
  end

  defp uncount(state, id, %{"at" => at}) do
    case parse_us(at) do
      {:ok, us} ->
        :ets.delete(state.table, {:order, us, id})
        state

      :error ->
        set_status(state, {:error, {:unindexable_group, id, :at}})
    end
  end

  defp fetch_open(state, id) do
    case Map.fetch(state.open, id) do
      {:ok, group} -> {:ok, group}
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

  # One scan of the journal: a damaged one is only scanned again to name the
  # offset. Closing a crashed group changes no count (an in-flight group
  # counts before and after its `unknown` close, an open one neither), so the
  # index is built from the records as read.
  defp recover(state) do
    case FileStore.read(state.handle) do
      {:ok, records} -> recover_records(state, records)
      {:error, reason} -> set_status(state, damage_or(state, reason))
    end
  end

  defp recover_records(state, records) do
    {groups, fills} = Groups.fold(records)

    with {:ok, _offsets} <- write(state, crash_closes(state, groups)),
         :ok <- index_groups(state.table, Enum.filter(groups, &Groups.counts?/1)),
         :ok <- index_intents(state.table, groups),
         :ok <- index_fills(state.table, fills) do
      set_status(state, :ok)
    else
      {:error, reason} -> set_status(state, damage_or(state, reason))
    end
  end

  defp crash_closes(state, groups) do
    for group <- groups, Groups.outcome(group) in [:open, :in_flight] do
      {reason, outcome} = Groups.crash_close(group)
      record(state, "close", group.id, %{"reason" => reason, "outcome" => outcome})
    end
  end

  defp index_groups(table, groups) do
    Enum.reduce_while(groups, :ok, fn group, :ok ->
      case index_placing(table, group.id, group.placing) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp index_intents(table, groups) do
    Enum.reduce_while(groups, :ok, fn
      %Groups{placing: nil}, :ok ->
        {:cont, :ok}

      %Groups{order: %{"status" => "failed"}}, :ok ->
        {:cont, :ok}

      %Groups{intent: %{"id" => intent_id}, id: id}, :ok when is_binary(intent_id) ->
        :ets.insert(table, {{:intent_placing, intent_id}, id})
        {:cont, :ok}

      %Groups{id: id}, :ok ->
        {:halt, {:error, {:unindexable_group, id, :intent}}}
    end)
  end

  # Count an order at its `placing` record's time and recorded notional; a
  # cancel records none and never counts.
  defp index_placing(_table, _id, %{"notional" => nil}), do: :ok

  defp index_placing(table, id, %{"notional" => notional, "at" => at}) do
    with {:ok, notional} <- parse_decimal(notional, {:unindexable_group, id, :notional}),
         {:ok, us} <- parse_us(at, {:unindexable_group, id, :at}) do
      :ets.insert(table, {{:order, us, id}, notional})
      :ok
    end
  end

  defp index_placing(_table, id, _placing), do: {:error, {:unindexable_group, id, :placing}}

  defp index_fills(table, fills) do
    Enum.reduce_while(fills, :ok, fn record, :ok ->
      unindexable = {:unindexable_fill, record["id"]}

      with %{"id" => offset, "at" => at, "fill" => %{"realized_pnl" => pnl}} <- record,
           {:ok, pnl} <- parse_decimal(pnl, unindexable),
           {:ok, us} <- parse_us(at, unindexable) do
        :ets.insert(table, {{:fill, us, offset}, pnl})
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
        _malformed -> {:halt, {:error, unindexable}}
      end
    end)
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

  # The table goes with the process: a journal that stops between `healthy/1`
  # and the read is not running.
  defp select(read) do
    read.()
  rescue
    ArgumentError -> {:error, :journal_not_running}
  end

  defp sum(table, tag, from) do
    table
    |> :ets.select([{{{tag, :"$1", :_}, :"$2"}, [{:>=, :"$1", from}], [:"$2"]}])
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  defp to_us(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  defp parse_us(at, error) do
    case parse_us(at) do
      {:ok, us} -> {:ok, us}
      :error -> {:error, error}
    end
  end

  defp parse_us(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> {:ok, to_us(datetime)}
      {:error, _} -> :error
    end
  end

  defp parse_us(_at), do: :error

  defp parse_decimal(value, error) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = decimal, ""} -> {:ok, decimal}
      _ -> {:error, error}
    end
  end

  defp parse_decimal(_value, error), do: {:error, error}
end
