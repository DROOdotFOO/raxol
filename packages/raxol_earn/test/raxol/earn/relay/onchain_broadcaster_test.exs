defmodule Raxol.Earn.Relay.OnchainBroadcasterTest do
  # async: false -- `configure/1` writes application env (global).
  use ExUnit.Case, async: false

  alias Raxol.Earn.ProviderAdapter.Mock
  alias Raxol.Earn.Relay.OnchainBroadcaster

  @token "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @to "0x" <> String.duplicate("ab", 20)

  describe "transfer_call/3" do
    test "builds the ERC-20 transfer calldata (selector + address + amount)" do
      call = OnchainBroadcaster.transfer_call(@token, @to, 500_000)

      assert call.to == @token
      assert call.value == 0
      assert byte_size(call.data) == 4 + 32 + 32

      hex = Base.encode16(call.data, case: :lower)
      # transfer(address,uint256) selector
      assert String.starts_with?(hex, "a9059cbb")
      # recipient address, left-padded to 32 bytes
      assert hex =~ "000000000000000000000000" <> String.duplicate("ab", 20)
      # amount 500000 = 0x7a120, right-aligned in the last word
      assert String.ends_with?(
               hex,
               "000000000000000000000000000000000000000000000000000000000007a120"
             )
    end
  end

  describe "send_deposit/1" do
    test "broadcasts the transfer through the provider and returns the tx hash" do
      provider = Mock.new()

      params = %{
        transfer_id: "t_1",
        chain_id: 8453,
        token: @token,
        to: @to,
        amount_atomic: "500000",
        provider: provider
      }

      assert {:ok, hash} = OnchainBroadcaster.send_deposit(params)
      assert is_binary(hash)

      assert [{8453, [call]}] = Mock.sent_calls(provider)
      assert call.to == @token
      assert call.value == 0
      assert String.starts_with?(Base.encode16(call.data, case: :lower), "a9059cbb")
    end

    test "uses the configured provider when the call carries none" do
      provider = Mock.new()
      on_exit(fn -> Application.delete_env(:raxol_earn, :relay_broadcaster_provider) end)

      assert :ok = OnchainBroadcaster.configure(provider)

      assert {:ok, _hash} =
               OnchainBroadcaster.send_deposit(%{
                 transfer_id: "t_1",
                 chain_id: 8453,
                 token: @token,
                 to: @to,
                 amount_atomic: "500000"
               })

      assert [{8453, _calls}] = Mock.sent_calls(provider)
    end

    test "errors when no provider is configured" do
      Application.delete_env(:raxol_earn, :relay_broadcaster_provider)

      assert {:error, :no_broadcaster_provider} =
               OnchainBroadcaster.send_deposit(%{
                 transfer_id: "t_1",
                 chain_id: 8453,
                 token: @token,
                 to: @to,
                 amount_atomic: "500000"
               })
    end

    test "errors on a non-positive or malformed amount" do
      provider = Mock.new()
      base = %{transfer_id: "t", chain_id: 8453, token: @token, to: @to, provider: provider}

      assert {:error, {:invalid_amount, "0"}} =
               OnchainBroadcaster.send_deposit(Map.put(base, :amount_atomic, "0"))

      assert {:error, {:invalid_amount, "abc"}} =
               OnchainBroadcaster.send_deposit(Map.put(base, :amount_atomic, "abc"))
    end
  end
end
