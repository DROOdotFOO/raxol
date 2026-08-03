defmodule Raxol.Earn.Hooks.FundTransferTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Hooks.FundTransfer

  describe "encode_set_budget_data/2" do
    test "encodes transfer_amount + destination as two 32-byte words" do
      destination = "0x" <> String.duplicate("ab", 20)

      data = FundTransfer.encode_set_budget_data(1_000_000, destination)

      assert byte_size(data) == 64

      <<amount::unsigned-big-256, addr_word::binary-size(32)>> = data
      assert amount == 1_000_000

      <<_padding::binary-size(12), addr_bytes::binary-size(20)>> = addr_word
      assert "0x" <> Base.encode16(addr_bytes, case: :lower) == destination
    end

    test "round-trips through decode_set_budget_data/1" do
      destination = "0x" <> String.duplicate("cd", 20)

      data = FundTransfer.encode_set_budget_data(5_000_000, destination)

      assert {:ok, %{transfer_amount: 5_000_000, destination: ^destination}} =
               FundTransfer.decode_set_budget_data(data)
    end

    test "zero transfer_amount is valid" do
      data = FundTransfer.encode_set_budget_data(0, "0x" <> String.duplicate("ab", 20))
      assert byte_size(data) == 64
    end
  end

  describe "decode_set_budget_data/1" do
    test "rejects data of the wrong length" do
      assert {:error, {:invalid_set_budget_data, 1}} = FundTransfer.decode_set_budget_data(<<1>>)
      # 63 bytes (off by one)
      assert {:error, {:invalid_set_budget_data, 63}} =
               FundTransfer.decode_set_budget_data(<<0::unsigned-big-504>>)

      # 65 bytes (one byte too many)
      assert {:error, {:invalid_set_budget_data, 65}} =
               FundTransfer.decode_set_budget_data(<<0::unsigned-big-520>>)
    end
  end

  describe "encode_fund_data/0 + encode_submit_data/0" do
    test "both return empty bytes for the basic FundTransfer flow" do
      assert FundTransfer.encode_fund_data() == <<>>
      assert FundTransfer.encode_submit_data() == <<>>
    end
  end
end
