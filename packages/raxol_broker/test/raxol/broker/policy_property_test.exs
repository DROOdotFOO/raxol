defmodule Raxol.Broker.PolicyPropertyTest do
  @moduledoc """
  Builds an order that every rule allows, then applies a random set of
  perturbations, each of which makes exactly one rule deny or ask. The
  verdict must follow from the set alone: DENY by the first denying rule in
  `Policy.rule_ids/0` order whenever any deny perturbation is present, else
  ASK listing exactly the asking rules, else ALLOW.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Broker.{Intent, Policy, PolicyFile}
  alias Raxol.Broker.Policy.Context

  @deny_perturbations [
    :symbol,
    :order_type,
    :after_hours_market,
    :drawdown_breaker,
    :order_rate,
    :max_notional_per_order,
    :daily_notional_cap,
    :max_position_weight
  ]
  @ask_perturbations [:review_warning, :untrusted_provenance, :llm]
  @perturbations @deny_perturbations ++ @ask_perturbations

  property "evaluate/2 is deterministic and a single deny is never downgraded" do
    check all(
            cents <- integer(1..100_000),
            flags <- list_of(boolean(), length: length(@perturbations)),
            max_runs: 500
          ) do
      perturbations = for {p, true} <- Enum.zip(@perturbations, flags), do: p
      notional = Decimal.div(Decimal.new(cents), 100)
      {intent, context} = build(notional, perturbations)

      result = Policy.evaluate(intent, context)
      assert result == Policy.evaluate(intent, context)
      assert_expected(result, intent, perturbations)
    end
  end

  defp assert_expected(result, intent, perturbations) do
    denies = Enum.filter(Policy.rule_ids(), &(&1 in perturbations and &1 in @deny_perturbations))
    asks = expected_asks(perturbations)

    case {denies, asks} do
      {[first | _], _} ->
        assert {:deny, {^first, _detail}} = result

      {[], []} ->
        assert {:allow, ^intent} = result

      {[], asks} ->
        assert {:ask, verdicts} = result
        assert Enum.map(verdicts, &elem(&1, 0)) == asks
    end
  end

  # `:llm` lowers `llm_ask_above` below the notional; the rule then asks for
  # both model-originated and untrusted provenance.
  defp expected_asks(perturbations) do
    Enum.filter(Policy.rule_ids(), fn
      :review_warning -> :review_warning in perturbations
      :untrusted_provenance -> :untrusted_provenance in perturbations
      :llm_ask_above -> :llm in perturbations
      _rule -> false
    end)
  end

  defp build(notional, perturbations) do
    {:ok, policy} = PolicyFile.new(Decimal.new("1000"), Decimal.new("5000"))

    policy =
      Keyword.merge(policy,
        order_types: [:market, :limit],
        max_position_weight: Decimal.new("0.5"),
        max_orders_per_minute: 10,
        drawdown_halt: Decimal.new("0.1"),
        llm_ask_above: Decimal.new("1000")
      )

    context = %Context{
      policy: policy,
      portfolio_value: Decimal.new("100000"),
      start_of_day_value: Decimal.new("100000"),
      day_pnl: Decimal.new("0"),
      positions: %{},
      quotes: %{},
      today_notional: Decimal.new("0"),
      orders_last_minute: 0,
      market_session: :regular,
      review_warnings: []
    }

    provenance =
      cond do
        :untrusted_provenance in perturbations -> {:untrusted, :news}
        :llm in perturbations -> :llm
        true -> :strategy
      end

    {:ok, intent} = Intent.buy_usd("AAPL", notional, provenance: provenance)

    context = Enum.reduce(perturbations, context, &perturb(&1, &2, notional))
    {intent, context}
  end

  defp perturb(:symbol, ctx, _notional),
    do: put_policy(ctx, :symbols_deny, ["AAPL"])

  defp perturb(:order_type, ctx, _notional), do: put_policy(ctx, :order_types, [:limit])
  defp perturb(:after_hours_market, ctx, _notional), do: %{ctx | market_session: :extended}
  defp perturb(:drawdown_breaker, ctx, _notional), do: %{ctx | day_pnl: Decimal.new("-10000.01")}
  defp perturb(:order_rate, ctx, _notional), do: %{ctx | orders_last_minute: 10}

  defp perturb(:max_notional_per_order, ctx, notional),
    do: put_policy(ctx, :max_notional_per_order, Decimal.sub(notional, Decimal.new("0.001")))

  defp perturb(:daily_notional_cap, ctx, notional),
    do: %{ctx | today_notional: Decimal.sub(Decimal.new("5000.01"), notional)}

  defp perturb(:max_position_weight, ctx, _notional),
    do: %{ctx | positions: %{"AAPL" => Decimal.new("50000")}}

  defp perturb(:review_warning, ctx, _notional), do: %{ctx | review_warnings: [:low_liquidity]}

  # Provenance perturbations change the intent, not the context; the LLM
  # threshold is lowered so the model-originated order is above it.
  defp perturb(:llm, ctx, notional),
    do: put_policy(ctx, :llm_ask_above, Decimal.sub(notional, Decimal.new("0.001")))

  defp perturb(:untrusted_provenance, ctx, _notional), do: ctx

  defp put_policy(%Context{policy: policy} = ctx, key, value),
    do: %{ctx | policy: Keyword.put(policy, key, value)}
end
