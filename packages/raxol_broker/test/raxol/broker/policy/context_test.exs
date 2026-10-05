defmodule Raxol.Broker.Policy.ContextTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.PolicyFile
  alias Raxol.Broker.Test.Hostile

  defp context(overrides \\ []) do
    {:ok, policy} = PolicyFile.new(Decimal.new("1000"), Decimal.new("5000"))

    struct!(
      %Context{
        policy: policy,
        portfolio_value: Decimal.new("100000"),
        start_of_day_value: Decimal.new("100000"),
        day_pnl: Decimal.new("-12.5"),
        positions: %{"MSFT" => Decimal.new("4000")},
        quotes: %{"AAPL" => Decimal.new("200")},
        today_notional: Decimal.new("0"),
        orders_last_minute: 0,
        market_session: :regular,
        review_warnings: [%{"code" => "pdt", "text" => "pattern day trader"}]
      },
      overrides
    )
  end

  test "a plain context round-trips unchanged" do
    assert {:ok, context()} == Context.normalize(context())
    assert {:ok, %Context{}} == Context.normalize(%Context{})
  end

  test "a hostile struct in any field is refused without running its callbacks" do
    for field <- [:quotes, :positions, :policy, :review_warnings, :day_pnl] do
      assert {:error, {:not_plain, [^field]}} =
               Context.normalize(context([{field, Hostile.new()}]))
    end

    assert {:error, {:not_plain, [:quotes, "AAPL"]}} =
             Context.normalize(context(quotes: %{"AAPL" => Hostile.new()}))

    assert {:error, {:not_plain, [:review_warnings, 0]}} =
             Context.normalize(context(review_warnings: [Hostile.new()]))

    assert {:error, {:not_plain, [:policy, 0, 1]}} =
             Context.normalize(context(policy: [max_notional_per_order: Hostile.new()]))

    refute_received {:hostile, _callback}
  end

  test "forged decimals, floats, pids and functions are refused" do
    assert {:error, {:not_plain, [:quotes, "AAPL"]}} =
             Context.normalize(
               context(quotes: %{"AAPL" => %Decimal{sign: 1, coef: :inf, exp: 0}})
             )

    assert {:error, {:not_plain, [:portfolio_value]}} =
             Context.normalize(context(portfolio_value: %Decimal{sign: 1, coef: "1", exp: 0}))

    assert {:error, {:not_plain, [:today_notional]}} =
             Context.normalize(context(today_notional: 1.0))

    assert {:error, {:not_plain, [:review_warnings, 0]}} =
             Context.normalize(context(review_warnings: [self()]))

    assert {:error, {:not_plain, [:market_session]}} =
             Context.normalize(context(market_session: fn -> :regular end))
  end

  test "plain values of the wrong shape are refused" do
    assert {:error, {:invalid, :quotes}} = Context.normalize(context(quotes: [{"AAPL", 1}]))
    assert {:error, {:invalid, :quotes}} = Context.normalize(context(quotes: %{"AAPL" => 1}))

    assert {:error, {:invalid, :positions}} =
             Context.normalize(context(positions: Decimal.new(1)))

    assert {:error, {:invalid, :today_notional}} = Context.normalize(context(today_notional: 0))

    assert {:error, {:invalid, :orders_last_minute}} =
             Context.normalize(context(orders_last_minute: -1))

    assert {:error, {:invalid, :market_session}} =
             Context.normalize(context(market_session: :weekend))
  end

  test "anything that is not a context is refused" do
    assert {:error, :not_a_context} = Context.normalize(%{policy: nil})
    assert {:error, :not_a_context} = Context.normalize(Hostile.new())
    assert {:error, :not_a_context} = Context.normalize(nil)
    refute_received {:hostile, _callback}
  end
end
