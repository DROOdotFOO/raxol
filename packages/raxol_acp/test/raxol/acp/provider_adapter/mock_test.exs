defmodule Raxol.ACP.ProviderAdapter.MockTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.ProviderAdapter
  alias Raxol.ACP.ProviderAdapter.Mock

  describe "identity / config" do
    test "get_address/1 returns the seeded address" do
      adapter = Mock.new(address: "0xfeed")
      assert ProviderAdapter.get_address(adapter) == "0xfeed"
    end

    test "supported_chain_ids/1 returns the seeded list" do
      adapter = Mock.new(supported_chain_ids: [8453, 84_532])
      assert ProviderAdapter.supported_chain_ids(adapter) == [8453, 84_532]
    end

    test "defaults are reasonable" do
      adapter = Mock.new()
      assert is_binary(ProviderAdapter.get_address(adapter))
      assert [8453] == ProviderAdapter.supported_chain_ids(adapter)
    end
  end

  describe "send_calls/3" do
    test "records the call and returns one tx hash per call" do
      adapter = Mock.new()

      call_a = %{to: "0xabc", data: <<1, 2, 3>>, value: 0}
      call_b = %{to: "0xdef", data: <<4, 5, 6>>, value: 0}

      assert {:ok, [hash1, hash2]} = ProviderAdapter.send_calls(adapter, 8453, [call_a, call_b])
      assert hash1 != hash2
      assert String.starts_with?(hash1, "0x")
      assert byte_size(hash1) == 66

      assert [{8453, [^call_a, ^call_b]}] = Mock.sent_calls(adapter)
    end

    test "monotonic tx hashes across multiple calls" do
      adapter = Mock.new()

      {:ok, [h1]} = ProviderAdapter.send_calls(adapter, 8453, [%{to: "0x1", data: <<>>}])
      {:ok, [h2]} = ProviderAdapter.send_calls(adapter, 8453, [%{to: "0x2", data: <<>>}])

      assert h1 != h2
    end
  end

  describe "signing" do
    test "sign_message/3 records the request and returns a placeholder sig" do
      adapter = Mock.new()

      assert {:ok, <<0xDE, 0xAD>>} = ProviderAdapter.sign_message(adapter, 8453, "hello")
      assert [{:message, 8453, "hello"}] = Mock.sent_signatures(adapter)
    end

    test "sign_typed_data/3 records the typed payload" do
      adapter = Mock.new()
      typed = %{domain: %{name: "X"}, types: %{}, message: %{}}

      assert {:ok, <<0xBE, 0xEF>>} = ProviderAdapter.sign_typed_data(adapter, 8453, typed)
      assert [{:typed_data, 8453, ^typed}] = Mock.sent_signatures(adapter)
    end
  end

  describe "get_transaction_receipt/3" do
    test "returns the seeded receipt; nil for unknown hash" do
      adapter = Mock.new()
      Mock.set_receipt(adapter, "0xab", %{status: 1, gas_used: 21_000})

      assert {:ok, %{status: 1}} = ProviderAdapter.get_transaction_receipt(adapter, 8453, "0xab")
      assert {:ok, nil} = ProviderAdapter.get_transaction_receipt(adapter, 8453, "0xmissing")
    end
  end

  describe "read_contract/3" do
    test "returns the seeded value" do
      adapter = Mock.new()
      Mock.set_contract_read(adapter, "0xABC", "name()", "USD Coin")

      assert {:ok, "USD Coin"} =
               ProviderAdapter.read_contract(adapter, 8453, %{
                 address: "0xabc",
                 signature: "name()",
                 args: []
               })
    end

    test "errors when no value was seeded" do
      adapter = Mock.new()

      assert {:error, {:no_canned_read, _, _}} =
               ProviderAdapter.read_contract(adapter, 8453, %{
                 address: "0xabc",
                 signature: "missing()",
                 args: []
               })
    end

    test "address lookup is case-insensitive" do
      adapter = Mock.new()
      Mock.set_contract_read(adapter, "0xABCDEF", "x()", 1)

      assert {:ok, 1} =
               ProviderAdapter.read_contract(adapter, 8453, %{
                 address: "0xabcdef",
                 signature: "x()",
                 args: []
               })
    end
  end

  describe "get_logs/3" do
    test "returns the seeded logs" do
      adapter = Mock.new()
      Mock.set_logs(adapter, [%{topics: [<<0xAA>>]}, %{topics: [<<0xBB>>]}])

      assert {:ok, [%{topics: [<<0xAA>>]}, %{topics: [<<0xBB>>]}]} =
               ProviderAdapter.get_logs(adapter, 8453, %{})
    end
  end
end
