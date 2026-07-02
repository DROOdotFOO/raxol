defmodule Raxol.Payments.ChainReader.StubTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # The Stub is the no-mock substrate every accounting test injects, so its
  # contract is worth pinning: what you seed is exactly what comes back, and an
  # unseeded key is :not_found. Exercised through the ChainReader facade (the
  # public interface production calls), never the callbacks directly.
  alias Raxol.Payments.ChainReader
  alias Raxol.Payments.ChainReader.Stub

  @receipt %{gas_used: 21_000, effective_gas_price: 1_000_000_000, status: :success}

  describe "get_receipt/3" do
    test "returns a seeded receipt" do
      reader = Stub.new(receipts: %{{1, "0xabc"} => @receipt})
      assert {:ok, @receipt} = ChainReader.get_receipt(reader, 1, "0xabc")
    end

    test "passes :pending through" do
      reader = Stub.new(receipts: %{{1, "0xabc"} => :pending})
      assert {:ok, :pending} = ChainReader.get_receipt(reader, 1, "0xabc")
    end

    test "passes a seeded error through unchanged" do
      reader = Stub.new(receipts: %{{1, "0xabc"} => {:error, :node_unavailable}})
      assert {:error, :node_unavailable} = ChainReader.get_receipt(reader, 1, "0xabc")
    end

    test "an unseeded (chain, tx) is :not_found" do
      reader = Stub.new(receipts: %{{1, "0xabc"} => @receipt})
      # Right tx, wrong chain: the key is the full tuple.
      assert {:error, :not_found} = ChainReader.get_receipt(reader, 10, "0xabc")
      assert {:error, :not_found} = ChainReader.get_receipt(reader, 1, "0xdifferent")
    end
  end

  describe "get_balance/3" do
    test "returns a seeded native balance" do
      reader = Stub.new(balances: %{{1, "0xowner"} => 5_000})
      assert {:ok, 5_000} = ChainReader.get_balance(reader, 1, "0xowner")
    end

    test "an unseeded native balance is :not_found" do
      assert {:error, :not_found} = ChainReader.get_balance(Stub.new(), 1, "0xowner")
    end
  end

  describe "get_erc20_balance/4" do
    test "returns a seeded token balance keyed by (chain, token, owner)" do
      reader = Stub.new(erc20: %{{1, "0xtoken", "0xowner"} => 1_000_000})
      assert {:ok, 1_000_000} = ChainReader.get_erc20_balance(reader, 1, "0xtoken", "0xowner")
    end

    test "an unseeded token balance is :not_found" do
      assert {:error, :not_found} = ChainReader.get_erc20_balance(Stub.new(), 1, "0xt", "0xo")
    end
  end

  describe "new/1" do
    test "an empty stub is :not_found for every reader call" do
      reader = Stub.new()
      assert {:error, :not_found} = ChainReader.get_receipt(reader, 1, "0x0")
      assert {:error, :not_found} = ChainReader.get_balance(reader, 1, "0x0")
      assert {:error, :not_found} = ChainReader.get_erc20_balance(reader, 1, "0x0", "0x1")
    end
  end

  describe "properties" do
    property "faithfully returns every seeded balance and :not_found for anything unseeded" do
      check all(
              balances <- map_of(balance_key(), integer(0..1_000_000_000)),
              probe <- balance_key()
            ) do
        reader = Stub.new(balances: balances)

        for {{chain, addr}, wei} <- balances do
          assert {:ok, ^wei} = ChainReader.get_balance(reader, chain, addr),
                 "seeded (#{chain}, #{addr}) did not return #{wei}"
        end

        unless Map.has_key?(balances, probe) do
          {chain, addr} = probe
          assert {:error, :not_found} = ChainReader.get_balance(reader, chain, addr)
        end
      end
    end
  end

  defp balance_key,
    do: tuple({integer(1..10), string(:alphanumeric, min_length: 1, max_length: 8)})
end
