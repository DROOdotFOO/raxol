defmodule Raxol.Payments.Ledger do
  @moduledoc """
  ETS-backed spend tracking for agent payment operations.

  Tracks all payments made by an agent with timestamps, enabling
  sliding-window session limits and lifetime totals. One Ledger
  GenServer runs per agent (or shared across agents if desired).

  ## Usage

      {:ok, ledger} = Ledger.start_link(name: :my_ledger)

      :ok = Ledger.record_spend(ledger, "agent_1", Decimal.new("0.05"), %{
        domain: "api.example.com",
        protocol: :x402,
        tx_hash: "0x..."
      })

      case Ledger.check_budget(ledger, "agent_1", Decimal.new("0.10"), policy) do
        :ok -> # proceed with payment
        {:over_limit, :per_request} -> # amount too high
        {:over_limit, :session} -> # session window exhausted
      end
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Payments.SpendingPolicy

  @type entry :: %{
          agent_id: term(),
          amount: Decimal.t(),
          currency: String.t(),
          timestamp_ms: integer(),
          metadata: map()
        }

  # -- Public API --

  @doc """
  Record a completed payment.
  """
  @spec record_spend(GenServer.server(), term(), Decimal.t(), map()) :: :ok
  def record_spend(server, agent_id, amount, metadata \\ %{}) do
    GenServer.cast(server, {:record, agent_id, amount, metadata})
  end

  @doc """
  Check if a payment amount fits within the spending policy.

  Returns `:ok` or `{:over_limit, limit_type}` where limit_type is
  `:per_request`, `:session`, `:lifetime`, or `:invalid_amount` (a zero,
  negative, or non-finite amount).

  Note: For concurrent use, prefer `try_spend/5` which atomically checks
  and records to prevent TOCTOU races.
  """
  @spec check_budget(
          GenServer.server(),
          term(),
          Decimal.t(),
          SpendingPolicy.t()
        ) ::
          :ok | {:over_limit, atom()}
  def check_budget(server, agent_id, amount, policy) do
    GenServer.call(server, {:check, agent_id, amount, policy})
  end

  @doc """
  Atomically check budget and record spend in a single operation.

  Prevents TOCTOU races where concurrent requests both pass `check_budget`
  before either calls `record_spend`.

  Returns `:ok` or `{:over_limit, limit_type}`.
  """
  @spec try_spend(
          GenServer.server(),
          term(),
          Decimal.t(),
          SpendingPolicy.t(),
          map()
        ) ::
          :ok | {:over_limit, atom()}
  def try_spend(server, agent_id, amount, policy, metadata \\ %{}) do
    GenServer.call(server, {:try_spend, agent_id, amount, policy, metadata})
  end

  @doc """
  Release (refund) a previously reserved amount.

  Records a compensating entry of `-amount` so a spend that was reserved via
  `try_spend/5` but then failed downstream (e.g. an intent execution error
  after signing was authorized) does not permanently consume budget. Session
  and lifetime totals net back out; per-request caps are unaffected since they
  are evaluated per call, not on the running sum.
  """
  @spec release(GenServer.server(), term(), Decimal.t(), map()) :: :ok
  def release(server, agent_id, amount, metadata \\ %{}) do
    GenServer.cast(server, {:release, agent_id, amount, metadata})
  end

  @doc """
  Get spend history for an agent.
  """
  @spec get_history(GenServer.server(), term(), keyword()) :: [entry()]
  def get_history(server, agent_id, opts \\ []) do
    GenServer.call(server, {:history, agent_id, opts})
  end

  @doc """
  Get aggregate totals for an agent.
  """
  @spec get_totals(GenServer.server(), term(), SpendingPolicy.t()) :: %{
          session: Decimal.t(),
          lifetime: Decimal.t()
        }
  def get_totals(server, agent_id, policy) do
    GenServer.call(server, {:totals, agent_id, policy})
  end

  @doc """
  Subscribe the calling process to new ledger entries.

  Every successful `try_spend` or `record_spend` sends `{:ledger_entry, entry}`
  to the subscriber. The subscription is monitored, so the Ledger cleans up
  when the subscriber dies.

  Optional `:agent_id` filters to entries for one agent.
  """
  @spec subscribe(GenServer.server(), keyword()) :: :ok
  def subscribe(server, opts \\ []) do
    GenServer.call(server, {:subscribe, self(), Keyword.get(opts, :agent_id)})
  end

  @doc """
  Freeze the ledger. While frozen, every `try_spend` / `check_budget` call
  returns `{:over_limit, :frozen}` regardless of policy caps.

  This is the kill switch for a runaway agent: flip the flag and the gate
  refuses all further spending without killing the process. `unfreeze/1`
  restores normal operation.
  """
  @spec freeze(GenServer.server()) :: :ok
  def freeze(server), do: GenServer.call(server, :freeze)

  @doc "Release the freeze flag. See `freeze/1`."
  @spec unfreeze(GenServer.server()) :: :ok
  def unfreeze(server), do: GenServer.call(server, :unfreeze)

  @doc "Return the current freeze state."
  @spec frozen?(GenServer.server()) :: boolean()
  def frozen?(server), do: GenServer.call(server, :frozen?)

  @doc """
  Spawn a printer that prints every ledger entry to `:stdio` (or another device).

  Returns the watcher pid. `Process.exit(pid, :kill)` to stop, or let the
  Ledger's death take it down via the monitor.

      iex> {:ok, ledger} = Raxol.Payments.Ledger.start_link()
      iex> Raxol.Payments.Ledger.tail(ledger)
  """
  @spec tail(GenServer.server(), keyword()) :: pid()
  def tail(server, opts \\ []) do
    agent_filter = Keyword.get(opts, :agent_id)
    device = Keyword.get(opts, :device, :stdio)

    spawn_link(fn ->
      :ok = subscribe(server, agent_id: agent_filter)
      tail_loop(device)
    end)
  end

  defp tail_loop(device) do
    receive do
      {:ledger_entry, entry} ->
        line =
          IO.ANSI.format([
            :cyan,
            "[ledger] ",
            :reset,
            inspect(entry.agent_id),
            " ",
            :bright,
            Decimal.to_string(entry.amount),
            " ",
            entry.currency,
            :reset,
            " ",
            inspect(Map.take(entry.metadata, [:protocol, :domain, :to])),
            "\n"
          ])

        IO.write(device, line)
        tail_loop(device)
    end
  end

  # -- BaseManager callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    table_name = Keyword.get(opts, :table_name, :raxol_payments_ledger)

    table =
      :ets.new(table_name, [
        :duplicate_bag,
        :protected,
        read_concurrency: true
      ])

    {:ok, %{table: table, subscribers: %{}, frozen?: false}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:record, agent_id, amount, metadata}, state) do
    entry = build_entry(agent_id, amount, metadata)
    :ets.insert(state.table, {agent_id, entry})
    notify_subscribers(state.subscribers, entry)
    {:noreply, state}
  end

  def handle_manager_cast({:release, agent_id, amount, metadata}, state) do
    release_meta = Map.put(metadata, :type, :release)
    entry = build_entry(agent_id, Decimal.negate(amount), release_meta)
    :ets.insert(state.table, {agent_id, entry})
    notify_subscribers(state.subscribers, entry)
    {:noreply, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:check, agent_id, amount, policy}, _from, state) do
    result = check_budget_or_frozen(state, agent_id, amount, policy)
    {:reply, result, state}
  end

  def handle_manager_call(
        {:try_spend, agent_id, amount, policy, metadata},
        _from,
        state
      ) do
    case check_budget_or_frozen(state, agent_id, amount, policy) do
      :ok ->
        entry = build_entry(agent_id, amount, metadata)
        :ets.insert(state.table, {agent_id, entry})
        notify_subscribers(state.subscribers, entry)

        :telemetry.execute(
          [:raxol, :payments, :spend],
          %{amount: entry.amount},
          %{
            agent_id: agent_id,
            currency: entry.currency,
            metadata: entry.metadata
          }
        )

        {:reply, :ok, state}

      {:over_limit, reason} = over ->
        :telemetry.execute(
          [:raxol, :payments, :over_budget],
          %{amount: amount},
          %{agent_id: agent_id, limit_type: reason}
        )

        {:reply, over, state}
    end
  end

  def handle_manager_call({:subscribe, pid, agent_filter}, _from, state) do
    ref = Process.monitor(pid)
    subscribers = Map.put(state.subscribers, ref, {pid, agent_filter})
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_manager_call(:freeze, _from, state) do
    :telemetry.execute([:raxol, :payments, :freeze], %{}, %{frozen?: true})
    {:reply, :ok, %{state | frozen?: true}}
  end

  def handle_manager_call(:unfreeze, _from, state) do
    :telemetry.execute([:raxol, :payments, :freeze], %{}, %{frozen?: false})
    {:reply, :ok, %{state | frozen?: false}}
  end

  def handle_manager_call(:frozen?, _from, state) do
    {:reply, state.frozen?, state}
  end

  def handle_manager_call({:history, agent_id, opts}, _from, state) do
    result =
      state.table
      |> get_entries(agent_id)
      |> filter_since(Keyword.get(opts, :since))
      |> take_last(Keyword.get(opts, :limit))

    {:reply, result, state}
  end

  def handle_manager_call({:totals, agent_id, policy}, _from, state) do
    entries = get_entries(state.table, agent_id)
    now = System.system_time(:millisecond)
    window_start = now - policy.session_window_ms

    session_total =
      entries
      |> Enum.filter(&(&1.timestamp_ms >= window_start))
      |> sum_amounts()

    lifetime_total = sum_amounts(entries)

    {:reply, %{session: session_total, lifetime: lifetime_total}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp check_budget_or_frozen(%{frozen?: true}, _agent_id, _amount, _policy),
    do: {:over_limit, :frozen}

  defp check_budget_or_frozen(state, agent_id, amount, policy),
    do: do_check_budget(state.table, agent_id, amount, policy)

  defp build_entry(agent_id, amount, metadata) do
    %{
      agent_id: agent_id,
      amount: amount,
      currency: Map.get(metadata, :currency, "USDC"),
      timestamp_ms: System.system_time(:millisecond),
      metadata: metadata
    }
  end

  defp notify_subscribers(subscribers, %{agent_id: agent_id} = entry) do
    Enum.each(subscribers, fn
      {_ref, {pid, nil}} -> send(pid, {:ledger_entry, entry})
      {_ref, {pid, ^agent_id}} -> send(pid, {:ledger_entry, entry})
      _ -> :ok
    end)
  end

  defp do_check_budget(table, agent_id, amount, policy) do
    with :ok <- check_amount_positive(amount),
         :ok <- check_per_request(amount, policy),
         entries = get_entries(table, agent_id),
         :ok <- check_session(entries, amount, policy),
         :ok <- check_lifetime(entries, amount, policy) do
      :ok
    end
  end

  # Reject non-positive or non-finite amounts before any cap check. This is the
  # ledger-side backstop for the SpendGate guard: a negative amount recorded via
  # `try_spend` would net down the session and lifetime totals, so it must never
  # be admitted regardless of caller. A finite Decimal carries an integer
  # coefficient while Infinity and NaN carry an atom (and `Decimal.compare/2`
  # raises on NaN), so `is_integer(coef)` gates them out safely.
  defp check_amount_positive(%Decimal{coef: coef} = amount) when is_integer(coef) do
    if Decimal.compare(amount, 0) == :gt,
      do: :ok,
      else: {:over_limit, :invalid_amount}
  end

  defp check_amount_positive(_amount), do: {:over_limit, :invalid_amount}

  defp check_per_request(amount, policy) do
    if Decimal.compare(amount, policy.per_request_max) == :gt,
      do: {:over_limit, :per_request},
      else: :ok
  end

  defp check_session(entries, amount, policy) do
    now = System.system_time(:millisecond)
    window_start = now - policy.session_window_ms

    session_after =
      entries
      |> Enum.filter(&(&1.timestamp_ms >= window_start))
      |> sum_amounts()
      |> Decimal.add(amount)

    if Decimal.compare(session_after, policy.session_max) == :gt,
      do: {:over_limit, :session},
      else: :ok
  end

  defp check_lifetime(entries, amount, policy) do
    lifetime_after =
      entries
      |> sum_amounts()
      |> Decimal.add(amount)

    if Decimal.compare(lifetime_after, policy.lifetime_max) == :gt,
      do: {:over_limit, :lifetime},
      else: :ok
  end

  defp filter_since(entries, nil), do: entries

  defp filter_since(entries, since_ms),
    do: Enum.filter(entries, &(&1.timestamp_ms >= since_ms))

  defp take_last(entries, nil), do: entries
  defp take_last(entries, n), do: Enum.take(entries, -n)

  defp get_entries(table, agent_id) do
    :ets.lookup(table, agent_id)
    |> Enum.map(fn {_key, entry} -> entry end)
    |> Enum.sort_by(& &1.timestamp_ms)
  end

  defp sum_amounts([]), do: Decimal.new(0)

  defp sum_amounts(entries) do
    Enum.reduce(entries, Decimal.new(0), fn entry, acc ->
      Decimal.add(acc, entry.amount)
    end)
  end
end
