defmodule Raxol.Earn.Onchain.Permit2ApproverTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Onchain.Permit2Approver
  alias Raxol.Earn.ProviderAdapter.Mock

  @token "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2"
  @owner "0x" <> String.duplicate("ab", 20)
  @allowance_sig "allowance(address,address)"
  # ERC-20 approve(address,uint256) selector.
  @approve_selector <<0x09, 0x5E, 0xA7, 0xB3>>

  defp max_word, do: "0x" <> String.duplicate("f", 64)
  defp zero_word, do: "0x" <> String.duplicate("0", 64)

  describe "permit2_address/0" do
    test "is taken from the payments protocol rather than restated" do
      assert Permit2Approver.permit2_address() ==
               Raxol.Payments.Protocols.Permit2.verifying_contract()
    end

    test "is the universal Permit2 deployment" do
      # This address decides three things at once: the spender an approve grants
      # to, the `verifyingContract` a served pull must declare, and the contract
      # `PullPreflight` reads DOMAIN_SEPARATOR() from. Pinning the external fact
      # belongs in a test; a second copy in production code is what the
      # preflight exists to catch.
      assert Permit2Approver.permit2_address() ==
               "0x000000000022D473030F116dDEE9F6B43aC78BA3"
    end
  end

  describe "approve_call/2" do
    test "encodes approve(Permit2, max) targeting the token" do
      call = Permit2Approver.approve_call(@token)

      assert call.to == @token
      assert call.value == 0
      assert <<@approve_selector::binary, args::binary>> = call.data
      # spender word (Permit2, left-padded) then the amount word (uint256.max).
      assert byte_size(args) == 64
      <<_pad::binary-size(12), spender::binary-size(20), amount::unsigned-big-256>> = args

      permit2 =
        Permit2Approver.permit2_address()
        |> String.replace_prefix("0x", "")
        |> Base.decode16!(case: :mixed)

      assert spender == permit2
      assert amount == Permit2Approver.max_uint256()
    end

    test "encodes a custom approve amount" do
      call = Permit2Approver.approve_call(@token, 1_000_000)

      <<@approve_selector::binary, _spender::binary-size(32), amount::unsigned-big-256>> =
        call.data

      assert amount == 1_000_000
    end
  end

  describe "allowance/4" do
    test "reads and decodes a hex allowance word" do
      adapter = Mock.new()

      :ok =
        Mock.set_contract_read(
          adapter,
          @token,
          @allowance_sig,
          "0x" <> String.pad_leading("64", 64, "0")
        )

      assert {:ok, 100} = Permit2Approver.allowance(adapter, 8453, @token, @owner)
    end

    test "decodes an empty '0x' word as zero" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, "0x")

      assert {:ok, 0} = Permit2Approver.allowance(adapter, 8453, @token, @owner)
    end

    test "accepts an integer canned value" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, 42)

      assert {:ok, 42} = Permit2Approver.allowance(adapter, 8453, @token, @owner)
    end

    test "surfaces the provider read error" do
      adapter = Mock.new()

      assert {:error, {:no_canned_read, _, _}} =
               Permit2Approver.allowance(adapter, 8453, @token, @owner)
    end
  end

  describe "ensure_allowance/5" do
    test "is a no-op when a standing max approval exists" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, max_word())

      assert {:ok, :sufficient} = Permit2Approver.ensure_allowance(adapter, 8453, @token, @owner)
      assert Mock.sent_calls(adapter) == []
    end

    test "broadcasts a max approve when the allowance is short" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, zero_word())

      assert {:ok, {:approved, "0x" <> _}} =
               Permit2Approver.ensure_allowance(adapter, 8453, @token, @owner)

      assert [{8453, [call]}] = Mock.sent_calls(adapter)
      assert call.to == @token
      assert <<@approve_selector::binary, _rest::binary>> = call.data
    end

    test "min_allowance lets a finite allowance count as sufficient" do
      adapter = Mock.new()
      # 1_000_000 atomic allowance is enough for a 1 USDC transfer.
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, 1_000_000)

      assert {:ok, :sufficient} =
               Permit2Approver.ensure_allowance(adapter, 8453, @token, @owner,
                 min_allowance: 1_000_000
               )

      assert Mock.sent_calls(adapter) == []
    end
  end

  # Real approve + allowance read-back against a Base fork. Opt-in; needs
  # foundry (anvil + cast) on PATH.
  describe "live approve on a Base fork" do
    @describetag :live_chain

    setup do
      rpc = Raxol.Earn.Test.AnvilHarness.start!(port: 8_613)
      account = Raxol.Earn.Test.AnvilHarness.anvil_account(0)

      provider =
        Raxol.Earn.ProviderAdapter.JSONRPC.new(
          chains: %{8453 => rpc},
          private_key: account.private_key,
          fee_overrides: %{
            8453 => %{max_priority_fee_per_gas: 1_000_000_000, max_fee_per_gas: 2_000_000_000}
          }
        )

      %{provider: provider, owner: account.address}
    end

    test "approves Permit2 and reads the new allowance back", %{provider: provider, owner: owner} do
      assert {:ok, 0} = Permit2Approver.allowance(provider, 8453, @token, owner)

      assert {:ok, {:approved, "0x" <> _}} =
               Permit2Approver.ensure_allowance(provider, 8453, @token, owner)

      assert {:ok, after_allowance} = Permit2Approver.allowance(provider, 8453, @token, owner)
      assert after_allowance == Permit2Approver.max_uint256()

      # Idempotent: a standing max approval broadcasts nothing further.
      assert {:ok, :sufficient} = Permit2Approver.ensure_allowance(provider, 8453, @token, owner)
    end
  end
end
