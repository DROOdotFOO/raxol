defmodule Raxol.Broker.Policy do
  @moduledoc """
  Decides whether an intent may proceed: ALLOW, ASK a human, or DENY.

  `evaluate/2` reads only the intent and its `Raxol.Broker.Policy.Context`;
  it does no I/O and gives the same answer for the same inputs. Each rule is a
  `Raxol.Agent.Authorization.Policy` run through
  `Raxol.Agent.Authorization.Engine`, so precedence is the engine's: any DENY
  wins, otherwise any ASK, otherwise ALLOW. Rules run in the order of
  `rule_ids/0` and the first DENY stops evaluation.

  | Rule id | Verdict |
  | --- | --- |
  | `:pricing` | DENY when the order's USD notional cannot be computed (a market order in shares with no quote) |
  | `:symbol` | DENY a symbol in `symbols_deny`, or outside `symbols_allow` when set |
  | `:order_type` | DENY an order type missing from `order_types`; options unless `options: true`; advanced orders unless `advanced_orders: true` |
  | `:after_hours_market` | DENY market and stop-market orders outside the regular session unless `after_hours_market: true` |
  | `:drawdown_breaker` | DENY when today's loss is more than `drawdown_halt` of the start-of-day value |
  | `:order_rate` | DENY when `max_orders_per_minute` orders were already placed in the last minute |
  | `:max_notional_per_order` | DENY a notional above the cap |
  | `:daily_notional_cap` | DENY when today's notional plus this order is above the cap |
  | `:max_position_weight` | DENY a buy that would leave the position above that share of the portfolio |
  | `:review_warning` | ASK when the order's review returned any warning |
  | `:untrusted_provenance` | ASK for every intent with `{:untrusted, source}` provenance |
  | `:llm_ask_above` | ASK for an `:llm` or untrusted intent above `llm_ask_above`, or for every one when it is `:unset` |

  Caps are inclusive: an order exactly at a cap is allowed. Notional counts
  both buys and sells. Rules whose policy key is `:unset` abstain. A rule that
  needs a context field left `nil` denies with `{:missing_context, field}`.
  Cancels are always allowed: they cannot add exposure, and the kill switch
  depends on them.

  An invalid policy or a context field of the wrong type is a DENY before any
  rule runs, with rule id `:policy_file` or `:context`.
  """

  alias Raxol.Agent.Authorization.{Engine, Verdict}
  alias Raxol.Agent.Authorization.Policy, as: Rule
  alias Raxol.Broker.{Intent, PolicyFile}
  alias Raxol.Broker.Policy.Context

  @phase :order
  @market_types [:market, :stop_market]
  @zero Decimal.new(0)

  @rule_ids [
    :pricing,
    :symbol,
    :order_type,
    :after_hours_market,
    :drawdown_breaker,
    :order_rate,
    :max_notional_per_order,
    :daily_notional_cap,
    :max_position_weight,
    :review_warning,
    :untrusted_provenance,
    :llm_ask_above
  ]

  @type rule_id ::
          :pricing
          | :symbol
          | :order_type
          | :after_hours_market
          | :drawdown_breaker
          | :order_rate
          | :max_notional_per_order
          | :daily_notional_cap
          | :max_position_weight
          | :review_warning
          | :untrusted_provenance
          | :llm_ask_above

  @type result ::
          {:allow, Intent.t()}
          | {:ask, [{rule_id(), String.t()}]}
          | {:deny, {rule_id() | :policy_file | :context, term()}}

  @doc "Rule ids in evaluation order."
  @spec rule_ids() :: [rule_id()]
  def rule_ids, do: @rule_ids

  @doc """
  Evaluate `intent` against `context`.

  Returns `{:allow, intent}`, `{:ask, [{rule_id, prompt}]}` listing every rule
  that asked, or `{:deny, {rule_id, detail}}` for the first rule that denied.
  """
  @spec evaluate(Intent.t(), Context.t()) :: result()
  def evaluate(%Intent{kind: :cancel} = intent, %Context{}), do: {:allow, intent}

  def evaluate(%Intent{} = intent, %Context{} = context) do
    with {:ok, policy} <- validate_policy(context.policy),
         :ok <- validate_context(context) do
      input = %{
        intent: intent,
        context: context,
        policy: Map.new(policy),
        notional: notional(intent, context)
      }

      rules()
      |> Engine.evaluate(@phase, input, Engine.new())
      |> to_result(intent)
    end
  end

  defp to_result(%Engine.Decision{action: :allow}, intent), do: {:allow, intent}
  defp to_result(%Engine.Decision{action: :deny, reason: reason}, _intent), do: {:deny, reason}

  defp to_result(%Engine.Decision{action: :ask, asks: asks}, _intent),
    do: {:ask, Enum.map(asks, &{&1.policy, &1.prompt})}

  defp validate_policy(policy) do
    case PolicyFile.validate(policy) do
      {:ok, policy} -> {:ok, policy}
      {:error, reason} -> {:deny, {:policy_file, reason}}
    end
  end

  # -- Context shape ----------------------------------------------------------

  @decimal_fields [:portfolio_value, :start_of_day_value, :day_pnl, :today_notional]

  defp validate_context(%Context{} = context) do
    invalid =
      Enum.find(@decimal_fields, &(not optional_decimal?(Map.fetch!(context, &1)))) ||
        cond do
          not price_map?(context.positions) -> :positions
          not price_map?(context.quotes) -> :quotes
          not optional_count?(context.orders_last_minute) -> :orders_last_minute
          context.market_session not in [nil, :regular, :extended, :closed] -> :market_session
          not is_list(context.review_warnings) -> :review_warnings
          true -> nil
        end

    if invalid, do: {:deny, {:context, {:invalid, invalid}}}, else: :ok
  end

  defp optional_decimal?(nil), do: true
  defp optional_decimal?(value), do: finite_decimal?(value)

  defp finite_decimal?(%Decimal{coef: coefficient}), do: is_integer(coefficient)
  defp finite_decimal?(_value), do: false

  defp price_map?(map) when is_map(map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and finite_decimal?(value) end)

  defp price_map?(_value), do: false

  defp optional_count?(nil), do: true
  defp optional_count?(value), do: is_integer(value) and value >= 0

  # -- Notional ---------------------------------------------------------------

  @doc """
  The USD notional of `intent` as the policy computes it: the stated amount,
  `qty` x limit or stop, or `qty` x the context quote for market orders in
  shares. `{:error, reason}` when it cannot be computed, including for cancels.
  The journal uses it to count what an order spent against the daily cap.
  """
  @spec notional(Intent.t(), Context.t()) :: {:ok, Decimal.t()} | {:error, term()}
  def notional(%Intent{kind: kind, notional: notional}, _context)
      when kind in [:buy_usd, :option, :advanced],
      do: positive(notional, :notional)

  def notional(%Intent{kind: kind, qty: qty, limit: limit}, _context)
      when kind in [:limit, :stop_limit],
      do: product(qty, limit, :limit)

  def notional(%Intent{kind: :stop_market, qty: qty, stop: stop}, _context),
    do: product(qty, stop, :stop)

  def notional(%Intent{kind: kind, qty: qty, symbol: symbol}, %Context{quotes: quotes})
      when kind in [:buy_shares, :sell] do
    case Map.fetch(quotes, symbol) do
      {:ok, price} -> product(qty, price, {:quote, symbol})
      :error -> {:error, {:missing_context, {:quote, symbol}}}
    end
  end

  def notional(%Intent{kind: kind}, _context), do: {:error, {:unknown_kind, kind}}

  defp product(qty, price, price_field) do
    with {:ok, qty} <- positive(qty, :qty),
         {:ok, price} <- positive(price, price_field) do
      {:ok, Decimal.mult(qty, price)}
    end
  end

  defp positive(%Decimal{} = value, field) do
    if finite_decimal?(value) and Decimal.gt?(value, 0),
      do: {:ok, value},
      else: {:error, {:invalid, field}}
  end

  defp positive(_value, field), do: {:error, {:invalid, field}}

  # -- Rules ------------------------------------------------------------------

  # Built from @rule_ids so the evaluation order and rule_ids/0 cannot drift.
  defp rules do
    Enum.map(@rule_ids, fn id ->
      Rule.new(name: id, phases: [@phase], scope: :once, evaluate: &run(id, &1))
    end)
  end

  defp run(:pricing, input), do: pricing(input)
  defp run(:symbol, input), do: symbol(input)
  defp run(:order_type, input), do: order_type(input)
  defp run(:after_hours_market, input), do: after_hours_market(input)
  defp run(:drawdown_breaker, input), do: drawdown_breaker(input)
  defp run(:order_rate, input), do: order_rate(input)
  defp run(:max_notional_per_order, input), do: max_notional_per_order(input)
  defp run(:daily_notional_cap, input), do: daily_notional_cap(input)
  defp run(:max_position_weight, input), do: max_position_weight(input)
  defp run(:review_warning, input), do: review_warning(input)
  defp run(:untrusted_provenance, input), do: untrusted_provenance(input)
  defp run(:llm_ask_above, input), do: llm_ask_above(input)

  defp deny(rule, detail), do: Verdict.deny({rule, detail})

  defp pricing(%{notional: {:ok, _notional}}), do: Verdict.allow()
  defp pricing(%{notional: {:error, reason}}), do: deny(:pricing, reason)

  defp symbol(%{intent: %Intent{symbol: symbol}, policy: policy}) do
    cond do
      symbol in policy.symbols_deny -> deny(:symbol, {:denied, symbol})
      policy.symbols_allow == :unset -> Verdict.allow()
      symbol in policy.symbols_allow -> Verdict.allow()
      true -> deny(:symbol, {:not_allowed, symbol})
    end
  end

  defp order_type(%{intent: %Intent{kind: :option}, policy: %{options: true}}),
    do: Verdict.allow()

  defp order_type(%{intent: %Intent{kind: :option}}), do: deny(:order_type, :options)

  defp order_type(%{intent: %Intent{kind: :advanced}, policy: %{advanced_orders: true}}),
    do: Verdict.allow()

  defp order_type(%{intent: %Intent{kind: :advanced}}), do: deny(:order_type, :advanced)

  defp order_type(%{intent: intent, policy: policy}) do
    type = type_of(intent)
    if type in policy.order_types, do: Verdict.allow(), else: deny(:order_type, type)
  end

  defp after_hours_market(%{intent: intent, context: context, policy: policy}) do
    cond do
      type_of(intent) not in @market_types -> Verdict.allow()
      policy.after_hours_market -> Verdict.allow()
      context.market_session == :regular -> Verdict.allow()
      is_nil(context.market_session) -> deny(:after_hours_market, missing(:market_session))
      true -> deny(:after_hours_market, context.market_session)
    end
  end

  defp drawdown_breaker(%{policy: %{drawdown_halt: :unset}}), do: Verdict.allow()

  defp drawdown_breaker(%{context: context, policy: %{drawdown_halt: halt}}) do
    cond do
      is_nil(context.start_of_day_value) ->
        deny(:drawdown_breaker, missing(:start_of_day_value))

      is_nil(context.day_pnl) ->
        deny(:drawdown_breaker, missing(:day_pnl))

      not Decimal.gt?(context.start_of_day_value, 0) ->
        deny(:drawdown_breaker, {:invalid_context, :start_of_day_value})

      true ->
        loss = Decimal.max(Decimal.negate(context.day_pnl), @zero)
        drawdown = Decimal.div(loss, context.start_of_day_value)

        if Decimal.gt?(drawdown, halt),
          do: deny(:drawdown_breaker, %{drawdown: drawdown, halt: halt}),
          else: Verdict.allow()
    end
  end

  defp order_rate(%{policy: %{max_orders_per_minute: :unset}}), do: Verdict.allow()

  defp order_rate(%{context: %Context{orders_last_minute: nil}}),
    do: deny(:order_rate, missing(:orders_last_minute))

  defp order_rate(%{context: %Context{orders_last_minute: count}, policy: policy}) do
    max = policy.max_orders_per_minute

    if count >= max,
      do: deny(:order_rate, %{orders_last_minute: count, max: max}),
      else: Verdict.allow()
  end

  defp max_notional_per_order(%{notional: {:ok, notional}, policy: policy}) do
    cap = policy.max_notional_per_order

    if Decimal.gt?(notional, cap),
      do: deny(:max_notional_per_order, %{notional: notional, cap: cap}),
      else: Verdict.allow()
  end

  defp daily_notional_cap(%{context: %Context{today_notional: nil}}),
    do: deny(:daily_notional_cap, missing(:today_notional))

  defp daily_notional_cap(%{notional: {:ok, notional}, context: context, policy: policy}) do
    cap = policy.daily_notional_cap
    total = Decimal.add(context.today_notional, notional)

    if Decimal.gt?(total, cap),
      do:
        deny(:daily_notional_cap, %{today: context.today_notional, notional: notional, cap: cap}),
      else: Verdict.allow()
  end

  defp max_position_weight(%{policy: %{max_position_weight: :unset}}), do: Verdict.allow()
  defp max_position_weight(%{intent: %Intent{side: :sell}}), do: Verdict.allow()

  defp max_position_weight(%{context: %Context{portfolio_value: nil}}),
    do: deny(:max_position_weight, missing(:portfolio_value))

  defp max_position_weight(%{intent: intent, notional: {:ok, notional}} = input) do
    %{context: context, policy: %{max_position_weight: max}} = input

    if Decimal.gt?(context.portfolio_value, 0) do
      held = Map.get(context.positions, intent.symbol, @zero)
      weight = Decimal.div(Decimal.add(held, notional), context.portfolio_value)

      if Decimal.gt?(weight, max),
        do: deny(:max_position_weight, %{weight: weight, max: max}),
        else: Verdict.allow()
    else
      deny(:max_position_weight, {:invalid_context, :portfolio_value})
    end
  end

  defp review_warning(%{context: %Context{review_warnings: []}}), do: Verdict.allow()

  defp review_warning(%{context: %Context{review_warnings: warnings}}),
    do: Verdict.ask("Order review returned #{length(warnings)} warning(s).")

  defp untrusted_provenance(%{intent: %Intent{provenance: {:untrusted, source}}}),
    do: Verdict.ask("Intent derived from untrusted input (#{inspect(source)}).")

  defp untrusted_provenance(_input), do: Verdict.allow()

  defp llm_ask_above(%{intent: %Intent{provenance: provenance}} = input)
       when provenance == :llm or
              (is_tuple(provenance) and elem(provenance, 0) == :untrusted) do
    %{notional: {:ok, notional}, policy: %{llm_ask_above: threshold}} = input

    cond do
      threshold == :unset ->
        Verdict.ask("Model-originated order; llm_ask_above is unset.")

      Decimal.gt?(notional, threshold) ->
        Verdict.ask(
          "Model-originated order of $#{Decimal.to_string(notional, :normal)} " <>
            "exceeds llm_ask_above $#{Decimal.to_string(threshold, :normal)}."
        )

      true ->
        Verdict.allow()
    end
  end

  defp llm_ask_above(_input), do: Verdict.allow()

  defp type_of(%Intent{kind: kind}) when kind in [:buy_usd, :buy_shares, :sell], do: :market
  defp type_of(%Intent{kind: kind}), do: kind

  defp missing(field), do: {:missing_context, field}
end
