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
  `:per_request`, `:session`, or `:lifetime`.

  Note: For concurrent use, prefer `try_spend/5` which atomically checks
  and records to prevent TOCTOU races.
  """
  @spec check_budget(GenServer.server(), term(), Decimal.t(), SpendingPolicy.t()) ::
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
  @spec try_spend(GenServer.server(), term(), Decimal.t(), SpendingPolicy.t(), map()) ::
          :ok | {:over_limit, atom()}
  def try_spend(server, agent_id, amount, policy, metadata \\ %{}) do
    GenServer.call(server, {:try_spend, agent_id, amount, policy, metadata})
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

    {:ok, %{table: table}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:record, agent_id, amount, metadata}, state) do
    entry = %{
      agent_id: agent_id,
      amount: amount,
      currency: Map.get(metadata, :currency, "USDC"),
      timestamp_ms: System.system_time(:millisecond),
      metadata: metadata
    }

    :ets.insert(state.table, {agent_id, entry})
    {:noreply, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:check, agent_id, amount, policy}, _from, state) do
    result = do_check_budget(state.table, agent_id, amount, policy)
    {:reply, result, state}
  end

  def handle_manager_call({:try_spend, agent_id, amount, policy, metadata}, _from, state) do
    case do_check_budget(state.table, agent_id, amount, policy) do
      :ok ->
        entry = %{
          agent_id: agent_id,
          amount: amount,
          currency: Map.get(metadata, :currency, "USDC"),
          timestamp_ms: System.system_time(:millisecond),
          metadata: metadata
        }

        :ets.insert(state.table, {agent_id, entry})
        {:reply, :ok, state}

      {:over_limit, _} = over ->
        {:reply, over, state}
    end
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

  # -- Private --

  defp do_check_budget(table, agent_id, amount, policy) do
    with :ok <- check_per_request(amount, policy),
         entries = get_entries(table, agent_id),
         :ok <- check_session(entries, amount, policy),
         :ok <- check_lifetime(entries, amount, policy) do
      :ok
    end
  end

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
  defp filter_since(entries, since_ms), do: Enum.filter(entries, &(&1.timestamp_ms >= since_ms))

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
