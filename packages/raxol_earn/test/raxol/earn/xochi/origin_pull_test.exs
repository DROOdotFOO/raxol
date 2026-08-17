defmodule Raxol.Earn.Xochi.OriginPullTest do
  @moduledoc """
  The origin-pull allowance decision an order makes before it signs anything.

  Two properties are load-bearing enough to be pinned here rather than left to a
  funded run:

    * Permit2 has no on-chain recipient guard -- the spender picks the recipient
      at call time -- so an allowance is granted ONLY towards a spender the
      operator pinned and the quote actually served. Every other combination
      fails closed, before the approve and before the signature.
    * The approve is idempotent. A standing allowance must send no transaction,
      or every order pays for one it did not need.
  """

  use ExUnit.Case, async: true

  alias Raxol.Earn.Onchain.Permit2Approver
  alias Raxol.Earn.ProviderAdapter.Mock
  alias Raxol.Earn.Xochi.OriginPull
  alias Raxol.Payments.Xochi.Schemas.QuoteResponse

  @spender "0xE9B020941015e428876f60C1979B3fc2A38a2f53"
  @other_spender "0x97D447561fDe10E959E782a29411D8F89586d80b"
  @token "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @owner "0x468aeae798b3a6548ac2401d276f83afdc172283"
  @allowance_sig "allowance(address,address)"
  @approve_selector <<0x09, 0x5E, 0xA7, 0xB3>>

  defp quote_resp(method, pull) do
    %QuoteResponse{
      intent_id: "int_1",
      quote_id: "qte_1",
      can_solve: true,
      payment_method: method,
      pull_authorization: pull
    }
  end

  defp permit2_pull(spender) do
    %{
      "primaryType" => "PermitWitnessTransferFrom",
      "domain" => %{"name" => "Permit2", "chainId" => 8453},
      "message" => %{
        "permitted" => %{"token" => @token, "amount" => "3000000"},
        "spender" => spender,
        "nonce" => "0x" <> String.duplicate("11", 32),
        "deadline" => "1900000000"
      }
    }
  end

  defp erc3009_pull do
    %{
      "primaryType" => "ReceiveWithAuthorization",
      "domain" => %{"chainId" => 8453, "verifyingContract" => @token},
      "message" => %{"from" => @owner, "to" => @other_spender, "value" => "3000000"}
    }
  end

  defp max_word, do: "0x" <> String.duplicate("f", 64)
  defp zero_word, do: "0x" <> String.duplicate("0", 64)

  describe "allowance_plan/2 -- rails" do
    test "a quote with no origin pull needs no allowance" do
      assert {:ok, :not_needed} = OriginPull.allowance_plan(quote_resp("erc3009", nil), nil)
    end

    test "the ERC-3009 rail needs no allowance, pinned or not" do
      quote = quote_resp("erc3009", erc3009_pull())

      assert {:ok, :not_needed} = OriginPull.allowance_plan(quote, nil)
      assert {:ok, :not_needed} = OriginPull.allowance_plan(quote, @spender)
    end

    test "the rail comes from the quote, not the token: USDC can be a Permit2 pull" do
      # Same USDC address as the ERC-3009 case above -- only payment_method differs.
      quote = quote_resp("permit2", permit2_pull(@spender))

      assert {:ok, {:permit2, @spender}} = OriginPull.allowance_plan(quote, @spender)
    end

    test "an unknown rail is refused rather than signed" do
      quote = quote_resp("teleport", permit2_pull(@spender))

      assert {:error, {:unsupported_pull_method, "teleport"}} =
               OriginPull.allowance_plan(quote, @spender)
    end
  end

  describe "allowance_plan/2 -- the Permit2 spender pin" do
    test "an unpinned Permit2 pull is refused" do
      quote = quote_resp("permit2", permit2_pull(@spender))

      assert {:error, :unpinned_permit2_spender} = OriginPull.allowance_plan(quote, nil)
      assert {:error, :unpinned_permit2_spender} = OriginPull.allowance_plan(quote, "")
    end

    test "a served spender that is not the pinned one is refused, naming both" do
      quote = quote_resp("permit2", permit2_pull(@other_spender))

      assert {:error, {:pull_spender_mismatch, served, pinned}} =
               OriginPull.allowance_plan(quote, @spender)

      assert served == String.downcase(@other_spender)
      assert pinned == String.downcase(@spender)
    end

    test "the match is on the address, not its checksum casing" do
      quote = quote_resp("permit2", permit2_pull(String.downcase(@spender)))

      assert {:ok, {:permit2, _}} = OriginPull.allowance_plan(quote, String.upcase(@spender))
    end

    test "a Permit2 authorization with no spender is refused" do
      pull = put_in(permit2_pull(@spender), ["message", "spender"], nil)

      assert {:error, {:invalid_spender, :served, nil}} =
               OriginPull.allowance_plan(quote_resp("permit2", pull), @spender)
    end

    test "a malformed pin is refused as malformed, not silently mismatched" do
      quote = quote_resp("permit2", permit2_pull(@spender))

      assert {:error, {:invalid_spender, :pinned, "0xnope"}} =
               OriginPull.allowance_plan(quote, "0xnope")
    end
  end

  describe "ensure_allowance/6" do
    test "sends nothing when the rail needs no allowance" do
      adapter = Mock.new()

      assert {:ok, :not_needed} =
               OriginPull.ensure_allowance(:not_needed, adapter, 8453, @token, @owner)

      assert Mock.sent_calls(adapter) == []
    end

    test "sends nothing when the allowance is already standing" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, max_word())

      assert {:ok, :standing} =
               OriginPull.ensure_allowance({:permit2, @spender}, adapter, 8453, @token, @owner)

      assert Mock.sent_calls(adapter) == []
    end

    test "sends exactly one approve when the allowance is short" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, zero_word())

      assert {:ok, {:approved, "0x" <> _}} =
               OriginPull.ensure_allowance({:permit2, @spender}, adapter, 8453, @token, @owner)

      assert [{8453, [call]}] = Mock.sent_calls(adapter)
      assert call.to == @token
      assert <<@approve_selector::binary, _rest::binary>> = call.data
    end

    test "a short allowance under --dry-run is reported, never sent" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, zero_word())

      assert {:ok, :would_approve} =
               OriginPull.ensure_allowance({:permit2, @spender}, adapter, 8453, @token, @owner,
                 dry_run: true
               )

      assert Mock.sent_calls(adapter) == []
    end

    test "a rehearsal judges the allowance by the same threshold the funded run does" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, Permit2Approver.max_uint256())

      assert {:ok, :standing} =
               OriginPull.ensure_allowance({:permit2, @spender}, adapter, 8453, @token, @owner,
                 dry_run: true
               )
    end

    test "surfaces a failed allowance read instead of assuming an approval is needed" do
      adapter = Mock.new()

      assert {:error, {:no_canned_read, _, _}} =
               OriginPull.ensure_allowance({:permit2, @spender}, adapter, 8453, @token, @owner)

      assert Mock.sent_calls(adapter) == []
    end
  end

  describe "describe/1" do
    test "distinguishes a granted approval from a standing one" do
      assert OriginPull.describe({:approved, "0xabc"}) =~ "approve tx 0xabc"
      assert OriginPull.describe(:standing) =~ "no approve sent"
      assert OriginPull.describe(:would_approve) =~ "SHORT"
      # True of a non-pulling quote as well as an ERC-3009 one, since both reach
      # this outcome.
      assert OriginPull.describe(:not_needed) =~ "not a Permit2 pull"
    end
  end

  describe "explain/1" do
    test "an unpinned Permit2 pull names the flag and the env var that unblock it" do
      text = OriginPull.explain(:unpinned_permit2_spender)

      assert text =~ "--solver 0x<spender>"
      assert text =~ "ORDER_SOLVER"
      assert text =~ "no on-chain recipient guard"
      # The served spender is the value the pin exists to check, so the message
      # must not read as an invitation to copy it back in.
      assert text =~ "not from a quote"
    end

    test "a mismatch names both addresses and says nothing was signed" do
      text = OriginPull.explain({:pull_spender_mismatch, "0xaaa", "0xbbb"})

      assert text =~ "0xaaa"
      assert text =~ "0xbbb"
      assert text =~ "Nothing was signed"
    end

    test "an unrecognised reason is still reported, not swallowed" do
      text = OriginPull.explain({:transport, :econnrefused})

      assert text =~ "econnrefused"
      assert text =~ "Nothing was signed"
    end
  end
end
