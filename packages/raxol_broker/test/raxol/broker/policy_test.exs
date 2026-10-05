defmodule Raxol.Broker.PolicyTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.{Intent, Policy, PolicyFile}
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Hostile

  defp d(value), do: Decimal.new(value)

  defp policy(overrides \\ []) do
    {:ok, policy} = PolicyFile.new(d("1000"), d("5000"))

    policy
    |> Keyword.merge(order_types: [:market, :limit, :stop_limit, :stop_market])
    |> Keyword.merge(overrides)
  end

  defp context(overrides \\ []) do
    struct!(
      %Context{
        policy: policy(),
        portfolio_value: d("100000"),
        start_of_day_value: d("100000"),
        day_pnl: d("0"),
        positions: %{},
        quotes: %{"AAPL" => d("200")},
        today_notional: d("0"),
        orders_last_minute: 0,
        market_session: :regular,
        review_warnings: []
      },
      overrides
    )
  end

  defp buy_usd(amount, provenance \\ :strategy) do
    {:ok, intent} = Intent.buy_usd("AAPL", d(amount), provenance: provenance)
    intent
  end

  defp deny_rule({:deny, {rule, _detail}}), do: rule
  defp deny_rule(other), do: flunk("expected a deny, got #{inspect(other)}")

  describe "notional caps are inclusive" do
    test "max_notional_per_order: at the cap allows, one cent over denies" do
      assert {:allow, _} = Policy.evaluate(buy_usd("1000"), context())

      assert {:deny, {:max_notional_per_order, %{notional: notional}}} =
               Policy.evaluate(buy_usd("1000.01"), context())

      assert Decimal.equal?(notional, d("1000.01"))
    end

    test "daily_notional_cap counts today's notional plus this order" do
      ctx = context(today_notional: d("4500"))

      assert {:allow, _} = Policy.evaluate(buy_usd("500"), ctx)
      assert :daily_notional_cap = deny_rule(Policy.evaluate(buy_usd("500.01"), ctx))
    end

    test "sells count against the caps" do
      {:ok, sell} = Intent.sell("AAPL", d("5.0001"), provenance: :strategy)
      assert :max_notional_per_order = deny_rule(Policy.evaluate(sell, context()))

      {:ok, sell} = Intent.sell("AAPL", d("5"), provenance: :strategy)
      assert {:allow, _} = Policy.evaluate(sell, context())
    end

    test "limit orders are priced at the limit, not the quote" do
      {:ok, limit} = Intent.limit(:buy, "AAPL", d("10"), d("100"), provenance: :strategy)
      assert {:allow, _} = Policy.evaluate(limit, context())

      {:ok, limit} = Intent.limit(:buy, "AAPL", d("10"), d("100.01"), provenance: :strategy)
      assert :max_notional_per_order = deny_rule(Policy.evaluate(limit, context()))
    end

    test "stop-market orders are priced at the stop" do
      {:ok, stop} = Intent.stop_market(:sell, "AAPL", d("4"), d("250"), provenance: :strategy)
      assert {:allow, _} = Policy.evaluate(stop, context())

      {:ok, stop} = Intent.stop_market(:sell, "AAPL", d("4"), d("250.01"), provenance: :strategy)
      assert :max_notional_per_order = deny_rule(Policy.evaluate(stop, context()))
    end
  end

  describe "pricing" do
    test "a share-quantity market order without a quote is denied" do
      {:ok, intent} = Intent.buy_shares("MSFT", d("1"), provenance: :strategy)

      assert {:deny, {:pricing, {:missing_context, {:quote, "MSFT"}}}} =
               Policy.evaluate(intent, context())
    end
  end

  describe "position weight is post-trade and applies to buys" do
    test "at the limit allows, one cent over denies" do
      ctx =
        context(
          policy: policy(max_position_weight: d("0.1"), max_notional_per_order: d("2000")),
          positions: %{"AAPL" => d("9000")}
        )

      assert {:allow, _} = Policy.evaluate(buy_usd("1000"), ctx)

      assert {:deny, {:max_position_weight, %{weight: weight}}} =
               Policy.evaluate(buy_usd("1000.01"), ctx)

      assert Decimal.gt?(weight, d("0.1"))
    end

    test "a sell of an overweight position is allowed" do
      ctx =
        context(
          policy: policy(max_position_weight: d("0.1")),
          positions: %{"AAPL" => d("50000")}
        )

      {:ok, sell} = Intent.sell("AAPL", d("1"), provenance: :strategy)
      assert {:allow, _} = Policy.evaluate(sell, ctx)
    end

    test "without a portfolio value the rule denies" do
      ctx = context(policy: policy(max_position_weight: d("0.1")), portfolio_value: nil)

      assert {:deny, {:max_position_weight, {:missing_context, :portfolio_value}}} =
               Policy.evaluate(buy_usd("1"), ctx)
    end
  end

  describe "symbols" do
    test "denylist wins and allowlist excludes everything else" do
      ctx = context(policy: policy(symbols_deny: ["AAPL"]))
      assert {:deny, {:symbol, {:denied, "AAPL"}}} = Policy.evaluate(buy_usd("1"), ctx)

      ctx = context(policy: policy(symbols_allow: ["MSFT"]))
      assert {:deny, {:symbol, {:not_allowed, "AAPL"}}} = Policy.evaluate(buy_usd("1"), ctx)

      ctx = context(policy: policy(symbols_allow: ["AAPL"]))
      assert {:allow, _} = Policy.evaluate(buy_usd("1"), ctx)
    end
  end

  describe "order types" do
    test "an options intent is denied regardless of size when options are off" do
      {:ok, option} = Intent.option(:buy, "AAPL", d("0.01"), provenance: :human)

      assert {:deny, {:order_type, :options}} = Policy.evaluate(option, context())

      ctx = context(policy: policy(options: true))
      assert {:allow, _} = Policy.evaluate(option, ctx)
    end

    test "advanced orders are denied until enabled" do
      {:ok, advanced} = Intent.advanced(:buy, "AAPL", d("1"), provenance: :human)

      assert {:deny, {:order_type, :advanced}} = Policy.evaluate(advanced, context())

      assert {:allow, _} =
               Policy.evaluate(advanced, context(policy: policy(advanced_orders: true)))
    end

    test "a market order is denied when only limit orders are allowed" do
      ctx = context(policy: policy(order_types: [:limit]))
      assert {:deny, {:order_type, :market}} = Policy.evaluate(buy_usd("1"), ctx)
    end
  end

  describe "after-hours market orders" do
    test "denied outside the regular session unless enabled; limit orders unaffected" do
      ctx = context(market_session: :extended)
      assert {:deny, {:after_hours_market, :extended}} = Policy.evaluate(buy_usd("1"), ctx)

      {:ok, limit} = Intent.limit(:buy, "AAPL", d("1"), d("1"), provenance: :strategy)
      assert {:allow, _} = Policy.evaluate(limit, ctx)

      ctx = context(market_session: :closed, policy: policy(after_hours_market: true))
      assert {:allow, _} = Policy.evaluate(buy_usd("1"), ctx)
    end

    test "an unknown session denies a market order" do
      assert {:deny, {:after_hours_market, {:missing_context, :market_session}}} =
               Policy.evaluate(buy_usd("1"), context(market_session: nil))
    end
  end

  describe "order rate" do
    test "the Nth order in a minute is allowed, the N+1th denied" do
      ctx = context(policy: policy(max_orders_per_minute: 3), orders_last_minute: 2)
      assert {:allow, _} = Policy.evaluate(buy_usd("1"), ctx)

      ctx = %{ctx | orders_last_minute: 3}
      assert :order_rate = deny_rule(Policy.evaluate(buy_usd("1"), ctx))
    end
  end

  describe "drawdown breaker" do
    test "a loss exactly at the halt share allows, any more denies" do
      ctx = context(policy: policy(drawdown_halt: d("0.05")), day_pnl: d("-5000"))
      assert {:allow, _} = Policy.evaluate(buy_usd("1"), ctx)

      ctx = %{ctx | day_pnl: d("-5000.01")}
      assert :drawdown_breaker = deny_rule(Policy.evaluate(buy_usd("1"), ctx))
    end

    test "gains never trip the breaker" do
      ctx = context(policy: policy(drawdown_halt: d("0.01")), day_pnl: d("90000"))
      assert {:allow, _} = Policy.evaluate(buy_usd("1"), ctx)
    end
  end

  describe "asks" do
    test "review warnings turn an allow into an ask" do
      assert {:ask, [{:review_warning, _prompt}]} =
               Policy.evaluate(buy_usd("1"), context(review_warnings: ["low liquidity"]))
    end

    test "an untrusted intent $1 under llm_ask_above asks" do
      ctx = context(policy: policy(llm_ask_above: d("100")))

      assert {:ask, asks} = Policy.evaluate(buy_usd("99", {:untrusted, :news}), ctx)
      assert asks[:untrusted_provenance] == "Intent derived from untrusted input (news)."

      assert {:ask, asks} = Policy.evaluate(buy_usd("99", {:untrusted, "email"}), ctx)
      assert asks[:untrusted_provenance] == "Intent derived from untrusted input (email)."
    end

    test "an llm intent asks above the threshold only" do
      ctx = context(policy: policy(llm_ask_above: d("100")))

      assert {:allow, _} = Policy.evaluate(buy_usd("100", :llm), ctx)
      assert {:ask, [{:llm_ask_above, _}]} = Policy.evaluate(buy_usd("100.01", :llm), ctx)
    end

    test "with llm_ask_above unset every llm intent asks" do
      assert {:ask, [{:llm_ask_above, _}]} = Policy.evaluate(buy_usd("0.01", :llm), context())
    end

    test "strategy and human intents never ask on provenance" do
      for provenance <- [:strategy, :human] do
        assert {:allow, _} = Policy.evaluate(buy_usd("1", provenance), context())
      end
    end

    test "a deny wins over any ask" do
      ctx = context(review_warnings: ["x"], market_session: :extended)

      assert {:deny, {:after_hours_market, :extended}} =
               Policy.evaluate(buy_usd("1", {:untrusted, :news}), ctx)
    end
  end

  describe "fail closed" do
    test "an invalid policy denies before any rule runs" do
      assert {:deny, {:policy_file, {:invalid_policy, :not_a_keyword_list}}} =
               Policy.evaluate(buy_usd("1"), context(policy: nil))

      assert {:deny, {:policy_file, {:invalid_value, :max_notional_per_order, _}}} =
               Policy.evaluate(
                 buy_usd("1"),
                 context(policy: Keyword.put(policy(), :max_notional_per_order, d("-1")))
               )
    end

    test "a context field of the wrong type denies" do
      assert {:deny, {:context, {:invalid, :today_notional}}} =
               Policy.evaluate(buy_usd("1"), context(today_notional: 0))

      assert {:deny, {:context, {:not_plain, [:quotes, "AAPL"]}}} =
               Policy.evaluate(buy_usd("1"), context(quotes: %{"AAPL" => d("NaN")}))
    end

    test "caller data with its own protocol implementations denies without running them" do
      for field <- [:quotes, :positions, :policy, :review_warnings] do
        assert {:deny, {:context, {:not_plain, [^field]}}} =
                 Policy.evaluate(buy_usd("1"), context([{field, Hostile.new()}]))
      end

      assert {:deny, {:context, {:not_plain, [:quotes, "AAPL"]}}} =
               Policy.evaluate(buy_usd("1"), context(quotes: %{"AAPL" => Hostile.new()}))

      intent = buy_usd("1")
      {:ok, option} = Intent.option(:buy, "AAPL", d("1"), provenance: :human)

      for hostile_intent <- [
            %{intent | provenance: {:untrusted, Hostile.new()}},
            %{intent | symbol: Hostile.new()},
            %{option | params: %{"leg" => Hostile.new()}}
          ] do
        assert {:deny, {:intent, {:not_plain, _path}}} =
                 Policy.evaluate(hostile_intent, context())
      end

      assert {:deny, {:intent, :not_an_intent}} = Policy.evaluate(Hostile.new(), context())
      assert {:deny, {:context, :not_a_context}} = Policy.evaluate(intent, Hostile.new())
      refute_received {:hostile, _callback}
    end

    test "forged decimals and floats in the intent deny" do
      intent = buy_usd("1")

      assert {:deny, {:intent, {:not_plain, [:notional]}}} =
               Policy.evaluate(
                 %{intent | notional: %Decimal{sign: 1, coef: :inf, exp: 0}},
                 context()
               )

      assert {:deny, {:intent, {:not_plain, [:notional]}}} =
               Policy.evaluate(%{intent | notional: 1.0}, context())
    end

    test "missing today's notional denies" do
      assert {:deny, {:daily_notional_cap, {:missing_context, :today_notional}}} =
               Policy.evaluate(buy_usd("1"), context(today_notional: nil))
    end
  end

  test "cancels are allowed even when every rule would deny" do
    {:ok, cancel} = Intent.cancel("order-1", provenance: {:untrusted, "email"})

    ctx =
      context(
        policy: policy(drawdown_halt: d("0.01")),
        day_pnl: d("-99999"),
        market_session: :closed,
        today_notional: d("999999")
      )

    assert {:allow, ^cancel} = Policy.evaluate(cancel, ctx)
  end
end
