defmodule Raxol.Payments.Prices.Static do
  @moduledoc """
  A `price_fn` backed by a fixed symbol -> USD map, for tests and for runs where
  the operator supplies prices out of band.

      price_fn = Raxol.Payments.Prices.Static.price_fn(%{"ETH" => "1700", "POL" => "0.07"})
      price_fn.("ETH")     #=> Decimal.new("1700")
      price_fn.("UNKNOWN") #=> nil
  """

  @doc "Build a `(symbol -> Decimal.t() | nil)` from a symbol -> price map."
  @spec price_fn(%{String.t() => Decimal.t() | number() | String.t()}) ::
          (String.t() -> Decimal.t() | nil)
  def price_fn(prices) when is_map(prices) do
    normalized = Map.new(prices, fn {symbol, value} -> {symbol, to_decimal(value)} end)
    fn symbol -> Map.get(normalized, symbol) end
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(f) when is_float(f), do: Decimal.from_float(f)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)
end
