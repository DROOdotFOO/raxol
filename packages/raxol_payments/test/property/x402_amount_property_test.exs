defmodule Raxol.Payments.Protocols.X402AmountPropertyTest do
  @moduledoc """
  Property: `X402.amount/1` is the inverse of atomic-amount construction
  for every known asset in `Raxol.Payments.Assets`. This pins the
  atomic->human normalization that the entire policy gate depends on
  for x402 flows.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.Assets
  alias Raxol.Payments.Protocols.X402

  # Known {chain_id, address, decimals} triples we want covered.
  @known_assets [
    {8453, "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", 6},
    {8453, "0xd9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca", 6},
    {8453, "0x4200000000000000000000000000000000000006", 18},
    {1, "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", 6},
    {1, "0x6b175474e89094c44da98b954eedeac495271d0f", 18},
    {10, "0x0b2c639c533813f4aa9d7837caf62653d097ff85", 6},
    {42_161, "0xaf88d065e77c8cc2239327c5edb3a432268e5831", 6},
    {137, "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359", 6}
  ]

  defp known_asset_generator do
    @known_assets
    |> Enum.map(&constant/1)
    |> one_of()
  end

  property "X402.amount/1 inverts construction for every known asset" do
    check all(
            {chain_id, contract, decimals} <- known_asset_generator(),
            atomic <- integer(0..1_000_000_000_000)
          ) do
      challenge = %{
        price: atomic,
        currency: contract,
        network: "eip155:#{chain_id}"
      }

      human = X402.amount(challenge)
      scaled = Decimal.mult(human, Decimal.new(Integer.pow(10, decimals)))

      assert Decimal.equal?(scaled, Decimal.new(atomic)),
             "asset chain=#{chain_id} contract=#{contract} atomic=#{atomic}: human=#{Decimal.to_string(human)} scaled back to #{Decimal.to_string(scaled)}"
    end
  end

  property "X402.amount/1 accepts string and integer price equivalently" do
    check all(
            {_, contract, _} <- known_asset_generator(),
            atomic <- integer(1..1_000_000)
          ) do
      from_int =
        X402.amount(%{
          price: atomic,
          currency: contract,
          network: "eip155:8453"
        })

      from_str =
        X402.amount(%{
          price: Integer.to_string(atomic),
          currency: contract,
          network: "eip155:8453"
        })

      assert Decimal.equal?(from_int, from_str)
    end
  end

  property "X402.amount/1 with unknown contract falls back to 6 decimals (USDC-safe)" do
    check all(
            atomic <- integer(0..1_000_000_000),
            fake_addr <- string(:ascii, length: 40)
          ) do
      challenge = %{
        price: atomic,
        currency: "0x" <> fake_addr,
        network: "eip155:8453"
      }

      human = X402.amount(challenge)
      scaled = Decimal.mult(human, Decimal.new(Integer.pow(10, 6)))

      assert Decimal.equal?(scaled, Decimal.new(atomic))
    end
  end

  property "X402.amount/1 result agrees with Assets.to_human/2 (consistency oracle)" do
    check all(
            {chain_id, contract, _decimals} <- known_asset_generator(),
            atomic <- integer(0..1_000_000)
          ) do
      challenge = %{
        price: atomic,
        currency: contract,
        network: "eip155:#{chain_id}"
      }

      direct = Assets.to_human(atomic, Assets.decimals(chain_id, contract))

      assert Decimal.equal?(X402.amount(challenge), direct)
    end
  end
end
