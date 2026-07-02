defmodule Raxol.Payments.SettlementLedger do
  @moduledoc """
  ETS-backed post-settlement P&L ledger: one entry per completed cross-chain fill,
  recording the fee collected (in the fee token) against the native gas the fill
  burned, so a corridor's margin and a chain's native-token drain can be measured
  after the fact.

  This exists because a small cross-chain fill can quote as solvable yet lose money
  once destination gas lands -- e.g. a `$1` fill to Ethereum L1 pays far more in ETH
  gas than it earns in USDC spread, and the loss is denominated in ETH (a one-way
  drain), not USDC. `can_solve` catches this only at quote time; this ledger
  quantifies it after settlement and feeds `Raxol.Payments.RebalanceAdvisor`.

  Mirrors `Raxol.Payments.Ledger` (`BaseManager` + ETS, caller-started). One
  deliberate difference: the table is a `:set` keyed by `intent_id` (Ledger uses a
  `:duplicate_bag` keyed by `agent_id`) so `:ets.insert_new/2` gives O(1)
  idempotency -- a re-poll of the same settlement must not double-record. Do not
  "align" this back to a `:duplicate_bag`.

  There is no price oracle in `raxol_payments`, so gas (native units) and fee (fee
  token) are stored raw; USD margin is computed only in the aggregations, and only
  when an injectable `:price_fn` (and `:usdc_price`) is supplied. Without a price,
  aggregations still return raw `fee_by_currency` / `gas_by_chain` totals and a
  `usd_margin` of `nil`.

  ## Usage

      {:ok, ledger} = SettlementLedger.start_link(name: :my_settlements)

      {:ok, :recorded} =
        SettlementLedger.record_settlement(ledger, %{
          intent_id: "xi_abc",
          from_chain_id: 8453,
          to_chain_id: 1,
          token_symbol: "USDC",
          fee_collected: "2205",
          fee_currency: "USDC",
          fee_decimals: 6,
          gas_native: 107_675_364_531_212,
          gas_chain_id: 1,
          gas_symbol: "ETH",
          gas_status: :confirmed,
          tx_hash: "0x...",
          settlement_type: :public
        })

      SettlementLedger.report(ledger, price_fn: fn "ETH" -> Decimal.new("1700") end)
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Payments.Assets

  @type gas_status :: :confirmed | :pending | :no_public_tx | :error

  @type entry :: %{
          intent_id: String.t(),
          from_chain_id: pos_integer() | nil,
          to_chain_id: pos_integer() | nil,
          token_symbol: String.t() | nil,
          token_address: String.t() | nil,
          fee_collected: Decimal.t(),
          fee_currency: String.t(),
          fee_decimals: pos_integer(),
          from_amount: Decimal.t() | nil,
          from_symbol: String.t() | nil,
          from_decimals: pos_integer() | nil,
          to_amount: Decimal.t() | nil,
          to_symbol: String.t() | nil,
          to_decimals: pos_integer() | nil,
          gas_native: Decimal.t() | nil,
          gas_chain_id: pos_integer() | nil,
          gas_symbol: String.t() | nil,
          gas_decimals: pos_integer(),
          gas_status: gas_status(),
          estimated_gas_cost: String.t() | nil,
          tx_hash: String.t() | nil,
          settlement_type: atom() | nil,
          timestamp_ms: integer(),
          usd_margin: Decimal.t() | nil,
          metadata: map()
        }

  @typedoc "Aggregated margin over a set of entries."
  @type aggregate :: %{
          count: non_neg_integer(),
          gas_unknown_count: non_neg_integer(),
          fee_by_currency: %{String.t() => Decimal.t()},
          gas_by_chain: %{pos_integer() => Decimal.t()},
          usd_revenue: Decimal.t() | nil,
          usd_fee: Decimal.t() | nil,
          usd_gas: Decimal.t() | nil,
          usd_margin: Decimal.t() | nil
        }

  @stablecoins ["USDC", "USDT", "USDBC", "PYUSD", "DAI"]

  # -- Public API --

  @doc """
  Record a completed fill. Idempotent by `intent_id`: a second record for the same
  intent returns `{:ok, :duplicate}` and does not overwrite or re-emit telemetry.
  """
  @spec record_settlement(GenServer.server(), map()) :: {:ok, :recorded | :duplicate}
  def record_settlement(server, input) when is_map(input) do
    GenServer.call(server, {:record, input})
  end

  @doc """
  Backfill `gas_native` for an intent whose receipt mined after the entry was
  recorded (the `:pending` path). Fills only when the stored `gas_native` is `nil`;
  otherwise a no-op. `opts` may carry `:gas_status` (default `:confirmed`).
  """
  @spec amend_gas(GenServer.server(), String.t(), integer() | Decimal.t(), keyword()) ::
          {:ok, :amended | :noop} | :error
  def amend_gas(server, intent_id, gas_native, opts \\ []) do
    GenServer.call(server, {:amend_gas, intent_id, gas_native, opts})
  end

  @doc "Fetch one settlement by intent id."
  @spec get_settlement(GenServer.server(), String.t()) :: {:ok, entry()} | :error
  def get_settlement(server, intent_id) do
    GenServer.call(server, {:get, intent_id})
  end

  @doc """
  List settlements, newest last. `opts` filters: `:from_chain_id`, `:to_chain_id`,
  `:settlement_type`, `:since_ms`.
  """
  @spec list_settlements(GenServer.server(), keyword()) :: [entry()]
  def list_settlements(server, opts \\ []) do
    GenServer.call(server, {:list, opts})
  end

  @doc """
  Margin aggregate per `{from_chain_id, to_chain_id}` corridor. Pricing opts
  (`:price_fn`, `:usdc_price`) flow into USD fields; filter opts flow to
  `list_settlements/2`.
  """
  @spec margin_by_corridor(GenServer.server(), keyword()) ::
          %{{pos_integer(), pos_integer()} => aggregate()}
  def margin_by_corridor(server, opts \\ []) do
    server
    |> list_settlements(filter_opts(opts))
    |> group_by(&{&1.from_chain_id, &1.to_chain_id}, opts)
  end

  @doc "Margin aggregate per destination chain (`to_chain_id`)."
  @spec margin_by_destination(GenServer.server(), keyword()) :: %{pos_integer() => aggregate()}
  def margin_by_destination(server, opts \\ []) do
    server
    |> list_settlements(filter_opts(opts))
    |> group_by(& &1.to_chain_id, opts)
  end

  @doc "Total native-token drain (wei) per chain the solver filled on."
  @spec native_drain_by_chain(GenServer.server(), keyword()) :: %{pos_integer() => Decimal.t()}
  def native_drain_by_chain(server, opts \\ []) do
    server
    |> list_settlements(filter_opts(opts))
    |> Enum.reject(&is_nil(&1.gas_native))
    |> Enum.reduce(%{}, fn e, acc ->
      Map.update(acc, e.gas_chain_id, e.gas_native, &Decimal.add(&1, e.gas_native))
    end)
  end

  @doc """
  One aggregate over all (filtered) settlements. A negative `usd_margin` is the
  cumulative subsidy the solver has spent keeping those corridors live.
  """
  @spec cumulative_subsidy(GenServer.server(), keyword()) :: aggregate()
  def cumulative_subsidy(server, opts \\ []) do
    server
    |> list_settlements(filter_opts(opts))
    |> aggregate(opts)
  end

  @doc "A structured margin report: corridors, destinations, native drain, and totals."
  @spec report(GenServer.server(), keyword()) :: %{
          corridors: map(),
          destinations: map(),
          drain: map(),
          totals: aggregate()
        }
  def report(server, opts \\ []) do
    %{
      corridors: margin_by_corridor(server, opts),
      destinations: margin_by_destination(server, opts),
      drain: native_drain_by_chain(server, opts),
      totals: cumulative_subsidy(server, opts)
    }
  end

  # -- BaseManager callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    table_name = Keyword.get(opts, :table_name, :raxol_payments_settlements)

    # :set keyed by intent_id: insert_new/2 makes re-recording an O(1) no-op.
    table = :ets.new(table_name, [:set, :protected, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:record, input}, _from, state) do
    entry = build_entry(input)

    if :ets.insert_new(state.table, {entry.intent_id, entry}) do
      emit_settlement(entry)
      {:reply, {:ok, :recorded}, state}
    else
      {:reply, {:ok, :duplicate}, state}
    end
  end

  def handle_manager_call({:amend_gas, intent_id, gas_native, opts}, _from, state) do
    result =
      case :ets.lookup(state.table, intent_id) do
        [{^intent_id, %{gas_native: nil} = entry}] ->
          updated = %{
            entry
            | gas_native: to_decimal(gas_native),
              gas_status: Keyword.get(opts, :gas_status, :confirmed)
          }

          :ets.insert(state.table, {intent_id, updated})
          {:ok, :amended}

        [{^intent_id, _entry}] ->
          {:ok, :noop}

        [] ->
          :error
      end

    {:reply, result, state}
  end

  def handle_manager_call({:get, intent_id}, _from, state) do
    case :ets.lookup(state.table, intent_id) do
      [{^intent_id, entry}] -> {:reply, {:ok, entry}, state}
      [] -> {:reply, :error, state}
    end
  end

  def handle_manager_call({:list, opts}, _from, state) do
    entries =
      state.table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.filter(&matches?(&1, opts))
      |> Enum.sort_by(& &1.timestamp_ms)

    {:reply, entries, state}
  end

  # -- Entry construction --

  defp build_entry(input) do
    fee_decimals = Map.get(input, :fee_decimals, 6)
    gas_chain_id = Map.get(input, :gas_chain_id) || Map.get(input, :to_chain_id)

    %{
      intent_id: Map.fetch!(input, :intent_id),
      from_chain_id: Map.get(input, :from_chain_id),
      to_chain_id: Map.get(input, :to_chain_id),
      token_symbol: Map.get(input, :token_symbol),
      token_address: Map.get(input, :token_address),
      fee_collected: to_decimal(Map.get(input, :fee_collected, 0)),
      fee_currency: Map.get(input, :fee_currency, "USDC"),
      fee_decimals: fee_decimals,
      from_amount: to_decimal_or_nil(Map.get(input, :from_amount)),
      from_symbol: Map.get(input, :from_symbol),
      from_decimals: Map.get(input, :from_decimals),
      to_amount: to_decimal_or_nil(Map.get(input, :to_amount)),
      to_symbol: Map.get(input, :to_symbol),
      to_decimals: Map.get(input, :to_decimals),
      gas_native: to_decimal_or_nil(Map.get(input, :gas_native)),
      gas_chain_id: gas_chain_id,
      gas_symbol: Map.get(input, :gas_symbol) || Assets.native_symbol(gas_chain_id),
      gas_decimals: Map.get(input, :gas_decimals) || Assets.native_decimals(gas_chain_id),
      gas_status: Map.get(input, :gas_status, :no_public_tx),
      estimated_gas_cost: Map.get(input, :estimated_gas_cost),
      tx_hash: Map.get(input, :tx_hash),
      settlement_type: Map.get(input, :settlement_type),
      timestamp_ms: Map.get(input, :timestamp_ms, System.system_time(:millisecond)),
      usd_margin: nil,
      metadata: Map.get(input, :metadata, %{})
    }
  end

  defp emit_settlement(entry) do
    :telemetry.execute(
      [:raxol, :payments, :settlement],
      %{fee_atomic: entry.fee_collected, gas_wei: entry.gas_native},
      %{
        intent_id: entry.intent_id,
        from_chain_id: entry.from_chain_id,
        to_chain_id: entry.to_chain_id,
        token_symbol: entry.token_symbol,
        gas_chain_id: entry.gas_chain_id,
        gas_symbol: entry.gas_symbol,
        gas_status: entry.gas_status,
        settlement_type: entry.settlement_type
      }
    )
  end

  # -- Filtering --

  defp filter_opts(opts),
    do: Keyword.take(opts, [:from_chain_id, :to_chain_id, :settlement_type, :since_ms])

  defp matches?(entry, opts) do
    Enum.all?(opts, fn
      {:from_chain_id, id} -> entry.from_chain_id == id
      {:to_chain_id, id} -> entry.to_chain_id == id
      {:settlement_type, t} -> entry.settlement_type == t
      {:since_ms, ms} -> entry.timestamp_ms >= ms
      _ -> true
    end)
  end

  # -- Aggregation (pure; runs in the caller) --

  defp group_by(entries, key_fun, opts) do
    entries
    |> Enum.group_by(key_fun)
    |> Map.new(fn {key, group} -> {key, aggregate(group, opts)} end)
  end

  defp aggregate(entries, opts) do
    price_fn = Keyword.get(opts, :price_fn, fn _sym -> nil end)
    usdc_price = Keyword.get(opts, :usdc_price, Decimal.new(1))

    entries
    |> Enum.reduce(empty_aggregate(), fn e, acc ->
      revenue_usd = revenue_usd(e, usdc_price, price_fn)
      fee_usd = fee_usd(e, usdc_price, price_fn)
      gas_usd = gas_usd(e, price_fn)

      %{
        count: acc.count + 1,
        gas_unknown_count: acc.gas_unknown_count + unknown_gas(e),
        fee_by_currency:
          Map.update(
            acc.fee_by_currency,
            e.fee_currency,
            e.fee_collected,
            &Decimal.add(&1, e.fee_collected)
          ),
        gas_by_chain: add_gas(acc.gas_by_chain, e),
        usd_revenue: add_or_keep(acc.usd_revenue, revenue_usd),
        usd_fee: add_or_keep(acc.usd_fee, fee_usd),
        usd_gas: add_or_keep(acc.usd_gas, gas_usd)
      }
    end)
    |> finalize_margin()
  end

  defp empty_aggregate do
    %{
      count: 0,
      gas_unknown_count: 0,
      fee_by_currency: %{},
      gas_by_chain: %{},
      usd_revenue: nil,
      usd_fee: nil,
      usd_gas: nil
    }
  end

  # Solver revenue in USD is the delivered spread: usd(from_amount) - usd(to_amount).
  # Present only when both legs are known and priced (stables at usdc_price; other
  # assets via price_fn). This is the multi-asset generalization of "fee = spread".
  defp revenue_usd(e, usdc_price, price_fn) do
    from = leg_usd(e.from_amount, e.from_symbol, e.from_decimals, usdc_price, price_fn)
    to = leg_usd(e.to_amount, e.to_symbol, e.to_decimals, usdc_price, price_fn)

    case {from, to} do
      {%Decimal{} = f, %Decimal{} = t} -> Decimal.sub(f, t)
      _ -> nil
    end
  end

  defp leg_usd(nil, _symbol, _decimals, _usdc_price, _price_fn), do: nil
  defp leg_usd(_amount, _symbol, nil, _usdc_price, _price_fn), do: nil

  defp leg_usd(amount, symbol, decimals, usdc_price, price_fn) do
    price = if symbol in @stablecoins, do: usdc_price, else: price_fn.(symbol)
    mult_or_nil(Assets.to_human(amount, decimals), price)
  end

  defp unknown_gas(%{gas_native: nil}), do: 1
  defp unknown_gas(_), do: 0

  defp add_gas(acc, %{gas_native: nil}), do: acc

  defp add_gas(acc, %{gas_chain_id: chain, gas_native: wei}),
    do: Map.update(acc, chain, wei, &Decimal.add(&1, wei))

  defp fee_usd(entry, usdc_price, price_fn) do
    price =
      if entry.fee_currency in @stablecoins,
        do: usdc_price,
        else: price_fn.(entry.fee_currency)

    mult_or_nil(Assets.to_human(entry.fee_collected, entry.fee_decimals), price)
  end

  defp gas_usd(%{gas_native: nil}, _price_fn), do: nil

  defp gas_usd(entry, price_fn) do
    mult_or_nil(
      Assets.to_human(entry.gas_native, entry.gas_decimals),
      price_fn.(entry.gas_symbol)
    )
  end

  # Margin is the solver spread (usd_revenue) net of gas. Falls back to the venue
  # fee only when the revenue legs were not recorded (e.g. an entry booked before
  # from/to amounts were captured), so an old-shape entry still yields a number.
  defp finalize_margin(agg) do
    basis = agg.usd_revenue || agg.usd_fee

    margin =
      if is_nil(basis) or is_nil(agg.usd_gas),
        do: nil,
        else: Decimal.sub(basis, agg.usd_gas)

    Map.put(agg, :usd_margin, margin)
  end

  defp mult_or_nil(_human, nil), do: nil
  defp mult_or_nil(human, %Decimal{} = price), do: Decimal.mult(human, price)

  defp add_or_keep(acc, nil), do: acc
  defp add_or_keep(nil, val), do: val
  defp add_or_keep(%Decimal{} = acc, %Decimal{} = val), do: Decimal.add(acc, val)

  defp to_decimal_or_nil(nil), do: nil
  defp to_decimal_or_nil(v), do: to_decimal(v)

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)
end
