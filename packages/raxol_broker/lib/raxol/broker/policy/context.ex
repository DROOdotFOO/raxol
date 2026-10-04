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
end
