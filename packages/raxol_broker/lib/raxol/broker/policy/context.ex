defmodule Raxol.Broker.Policy.Context do
  @moduledoc """
  Everything `Raxol.Broker.Policy.evaluate/2` may read besides the intent.

  The policy does no I/O; whoever builds the context fetches the data. A rule
  that needs a field left `nil` denies with `{:missing_context, field}`, so an
  incomplete context can never let an order through.

    * `policy` -- a keyword list accepted by `Raxol.Broker.PolicyFile.validate/1`.
    * `portfolio_value` -- current total account value in USD.
    * `start_of_day_value` -- account value at the start of the exchange day.
    * `day_pnl` -- today's realized plus unrealized P&L in USD (losses negative).
    * `positions` -- `%{symbol => market value in USD}`.
    * `quotes` -- `%{symbol => last price in USD}`, used to price market orders
      given in shares.
    * `today_notional` -- USD notional already ordered today, both sides.
    * `orders_last_minute` -- orders placed in the trailing 60 seconds.
    * `market_session` -- `:regular`, `:extended`, or `:closed`. Holidays and
      half days make this a data question, so the context builder answers it.
    * `review_warnings` -- warnings returned by the order's `review_*` call;
      empty before review.
  """

  alias Raxol.Broker.Plain

  @type t :: %__MODULE__{
          policy: keyword() | nil,
          portfolio_value: Decimal.t() | nil,
          start_of_day_value: Decimal.t() | nil,
          day_pnl: Decimal.t() | nil,
          positions: %{optional(String.t()) => Decimal.t()},
          quotes: %{optional(String.t()) => Decimal.t()},
          today_notional: Decimal.t() | nil,
          orders_last_minute: non_neg_integer() | nil,
          market_session: :regular | :extended | :closed | nil,
          review_warnings: [term()]
        }

  defstruct policy: nil,
            portfolio_value: nil,
            start_of_day_value: nil,
            day_pnl: nil,
            positions: %{},
            quotes: %{},
            today_notional: nil,
            orders_last_minute: nil,
            market_session: nil,
            review_warnings: []

  @fields [
    :policy,
    :portfolio_value,
    :start_of_day_value,
    :day_pnl,
    :positions,
    :quotes,
    :today_notional,
    :orders_last_minute,
    :market_session,
    :review_warnings
  ]
  @decimal_fields [:portfolio_value, :start_of_day_value, :day_pnl, :today_notional]

  @doc """
  Rebuild `term` as a context from validated plain fields.

  Accepts any term and never raises or dispatches a protocol on it. Every
  field passes `Raxol.Broker.Plain`, then a shape check: `policy` is `nil` or
  a list, the money fields are `nil` or decimals, `positions` and `quotes` are
  plain maps of string to decimal, `orders_last_minute` is `nil` or a
  non-negative integer, `market_session` is `nil`, `:regular`, `:extended` or
  `:closed`, and `review_warnings` is a list. Errors never echo the value.
  """
  @spec normalize(term()) ::
          {:ok, t()}
          | {:error, :not_a_context | {:invalid, atom()} | {:not_plain, Plain.path()}}
  def normalize(%{__struct__: __MODULE__} = context), do: normalize(@fields, context, [])
  def normalize(_term), do: {:error, :not_a_context}

  defp normalize([], _context, acc), do: {:ok, struct!(__MODULE__, acc)}

  defp normalize([field | rest], context, acc) do
    value = if is_map_key(context, field), do: :maps.get(field, context)

    case Plain.normalize(value) do
      {:ok, value} ->
        if shape?(field, value),
          do: normalize(rest, context, [{field, value} | acc]),
          else: {:error, {:invalid, field}}

      {:error, {:not_plain, path}} ->
        {:error, {:not_plain, [field | path]}}
    end
  end

  defp shape?(:policy, value), do: is_nil(value) or is_list(value)
  defp shape?(field, value) when field in @decimal_fields, do: is_nil(value) or decimal?(value)
  defp shape?(field, value) when field in [:positions, :quotes], do: price_map?(value)
  defp shape?(:orders_last_minute, nil), do: true
  defp shape?(:orders_last_minute, value), do: is_integer(value) and value >= 0
  defp shape?(:market_session, value), do: value in [nil, :regular, :extended, :closed]
  defp shape?(:review_warnings, value), do: is_list(value)

  defp decimal?(%{__struct__: Decimal}), do: true
  defp decimal?(_value), do: false

  defp price_map?(value) when is_map(value) and not is_map_key(value, :__struct__),
    do:
      :lists.all(fn {key, price} -> is_binary(key) and decimal?(price) end, :maps.to_list(value))

  defp price_map?(_value), do: false
end
