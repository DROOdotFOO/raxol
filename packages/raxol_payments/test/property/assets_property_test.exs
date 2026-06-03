defmodule Raxol.Payments.AssetsPropertyTest do
  @moduledoc """
  Properties for `Raxol.Payments.Assets`. These pin the atomic <-> human
  unit conversion that every protocol's `amount/1` relies on.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.Assets

  describe "to_human/2 roundtrip" do
    property "to_human(n, d) * 10^d == n for any non-negative integer n and 1 <= d <= 30" do
      check all(
              atomic <- integer(0..1_000_000_000_000_000),
              decimals <- integer(1..30)
            ) do
        human = Assets.to_human(atomic, decimals)
        scaled = Decimal.mult(human, Decimal.new(Integer.pow(10, decimals)))

        assert Decimal.equal?(scaled, Decimal.new(atomic)),
               "decimals=#{decimals} atomic=#{atomic} produced human=#{Decimal.to_string(human)} which scales back to #{Decimal.to_string(scaled)}"
      end
    end

    property "to_human accepts string input equivalently to integer input" do
      check all(
              atomic <- integer(0..1_000_000_000),
              decimals <- integer(1..18)
            ) do
        from_int = Assets.to_human(atomic, decimals)
        from_str = Assets.to_human(Integer.to_string(atomic), decimals)
        assert Decimal.equal?(from_int, from_str)
      end
    end

    property "to_human is monotonic in atomic" do
      check all(
              a <- integer(0..1_000_000),
              b <- integer(0..1_000_000),
              decimals <- integer(1..12)
            ) do
        ha = Assets.to_human(a, decimals)
        hb = Assets.to_human(b, decimals)

        cond do
          a < b -> assert Decimal.compare(ha, hb) == :lt
          a > b -> assert Decimal.compare(ha, hb) == :gt
          true -> assert Decimal.equal?(ha, hb)
        end
      end
    end
  end

  describe "decimals/2 invariants" do
    property "decimals(...) always returns a positive integer" do
      check all(
              chain <- one_of([integer(1..1_000_000), constant(nil)]),
              addr <-
                one_of([
                  constant(nil),
                  constant(""),
                  string(:ascii, length: 42)
                ])
            ) do
        result = Assets.decimals(chain, addr)

        assert is_integer(result) and result > 0,
               "decimals/2 returned #{inspect(result)} for chain=#{inspect(chain)} addr=#{inspect(addr)}"
      end
    end

    property "decimals/2 is case-insensitive on the address" do
      # The known USDC entry on Base is the most useful target -- any case
      # of that address must resolve to 6.
      base_usdc = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

      check all(case_flips <- list_of(boolean(), length: 40)) do
        addr =
          base_usdc
          |> String.replace_prefix("0x", "")
          |> String.graphemes()
          |> Enum.zip(case_flips)
          |> Enum.map(fn {ch, flip} ->
            if flip, do: String.upcase(ch), else: ch
          end)
          |> Enum.join()
          |> then(&("0x" <> &1))

        assert Assets.decimals(8453, addr) == 6
      end
    end

    property "decimals/1 (ticker) is case-insensitive" do
      check all(flips <- list_of(boolean(), length: 4)) do
        ticker =
          "USDC"
          |> String.graphemes()
          |> Enum.zip(flips)
          |> Enum.map(fn {ch, flip} ->
            if flip, do: String.downcase(ch), else: ch
          end)
          |> Enum.join()

        assert Assets.decimals(ticker) == 6
      end
    end
  end
end
