defmodule Raxol.Payments.Prices.StaticTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.Prices.Static

  describe "price_fn/1" do
    test "a known symbol resolves to its price as a Decimal" do
      price_fn = Static.price_fn(%{"ETH" => "1700", "POL" => "0.07"})

      assert Decimal.equal?(price_fn.("ETH"), Decimal.new("1700"))
      assert Decimal.equal?(price_fn.("POL"), Decimal.new("0.07"))
    end

    test "an unknown symbol resolves to nil" do
      price_fn = Static.price_fn(%{"ETH" => "1700"})
      assert price_fn.("UNKNOWN") == nil
    end

    test "an empty map resolves everything to nil" do
      price_fn = Static.price_fn(%{})
      assert price_fn.("ETH") == nil
    end

    test "normalizes integer, float, string, and Decimal inputs to Decimal" do
      price_fn =
        Static.price_fn(%{
          "i" => 5,
          "f" => 0.5,
          "s" => "5",
          "d" => Decimal.new("5")
        })

      assert Decimal.equal?(price_fn.("i"), Decimal.new(5))
      assert Decimal.equal?(price_fn.("f"), Decimal.from_float(0.5))
      assert Decimal.equal?(price_fn.("s"), Decimal.new("5"))
      assert Decimal.equal?(price_fn.("d"), Decimal.new("5"))
    end
  end

  describe "properties" do
    property "resolves every seeded symbol to its price and unseeded symbols to nil" do
      check all(
              prices <- map_of(symbol(), integer(0..1_000_000)),
              probe <- symbol()
            ) do
        price_fn = Static.price_fn(prices)

        for {symbol, value} <- prices do
          assert Decimal.equal?(price_fn.(symbol), Decimal.new(value)),
                 "seeded #{symbol} did not resolve to #{value}"
        end

        unless Map.has_key?(prices, probe) do
          assert price_fn.(probe) == nil
        end
      end
    end

    property "value representation is invariant: an integer and its string form yield equal Decimals" do
      check all(n <- integer(0..1_000_000), sym <- symbol()) do
        from_int = Static.price_fn(%{sym => n}).(sym)
        from_str = Static.price_fn(%{sym => Integer.to_string(n)}).(sym)

        assert Decimal.equal?(from_int, from_str)
      end
    end
  end

  defp symbol, do: string(:alphanumeric, min_length: 1, max_length: 8)
end
