defmodule Raxol.Earn.Xochi.OriginPullTest do
  @moduledoc """
  The origin-pull allowance decision an order makes before it signs anything.

  Four properties are load-bearing enough to be pinned here rather than left to a
  funded run:

    * Permit2 has no on-chain recipient guard -- the spender picks the recipient
      at call time -- so an allowance is granted ONLY towards a spender the
      operator pinned and the quote actually served. Every other combination
      fails closed, before the approve and before the signature.
    * The permit is served by the counterparty, so its chain, token and amount are
      checked against the transfer the OPERATOR asked for. Otherwise the quote
      picks which balance the allowance opens, and how much of it.
    * The approve is bounded to the one intent's authorized pull, so a later bad
      signature cannot reach more of the balance than this run was spending.
    * The approve is idempotent. An allowance that already covers the pull must
      send no transaction, or every order pays for one it did not need.
  """

  use ExUnit.Case, async: true

  alias Raxol.Earn.Onchain.Permit2Approver
  alias Raxol.Earn.ProviderAdapter.Mock
  alias Raxol.Earn.Xochi.OriginPull
  alias Raxol.Payments.Xochi.Schemas.QuoteResponse

  @spender "0xE9B020941015e428876f60C1979B3fc2A38a2f53"
  @other_spender "0x97D447561fDe10E959E782a29411D8F89586d80b"
  @token "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @other_token "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2"
  @owner "0x468aeae798b3a6548ac2401d276f83afdc172283"
  @amount 3_000_000
  @allowance_sig "allowance(address,address)"
  @approve_selector <<0x09, 0x5E, 0xA7, 0xB3>>

  defp origin(overrides \\ %{}),
    do: Map.merge(%{chain_id: 8453, token: @token, amount: @amount}, overrides)

  defp permit(overrides \\ %{}),
    do: Map.merge(%{spender: @spender, chain_id: 8453, token: @token, amount: @amount}, overrides)

  defp quote_resp(method, pull) do
    %QuoteResponse{
      intent_id: "int_1",
      quote_id: "qte_1",
      can_solve: true,
      payment_method: method,
      pull_authorization: pull
    }
  end

  defp permit2_pull(spender, opts \\ []) do
    %{
      "primaryType" => "PermitWitnessTransferFrom",
      "domain" => %{"name" => "Permit2", "chainId" => Keyword.get(opts, :chain_id, 8453)},
      "message" => %{
        "permitted" => %{
          "token" => Keyword.get(opts, :token, @token),
          "amount" => Keyword.get(opts, :amount, "3000000")
        },
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
  defp word(value), do: "0x" <> String.pad_leading(Integer.to_string(value, 16), 64, "0")

  describe "allowance_plan/3 -- rails" do
    test "a quote with no origin pull needs no allowance" do
      assert {:ok, :not_needed} =
               OriginPull.allowance_plan(quote_resp("erc3009", nil), nil, origin())
    end

    test "the ERC-3009 rail needs no allowance, pinned or not" do
      quote = quote_resp("erc3009", erc3009_pull())

      assert {:ok, :not_needed} = OriginPull.allowance_plan(quote, nil, origin())
      assert {:ok, :not_needed} = OriginPull.allowance_plan(quote, @spender, origin())
    end

    test "the rail comes from the quote, not the token: USDC can be a Permit2 pull" do
      # Same USDC address as the ERC-3009 case above -- only payment_method differs.
      quote = quote_resp("permit2", permit2_pull(@spender))

      assert {:ok, {:permit2, permit()}} ==
               OriginPull.allowance_plan(quote, @spender, origin())
    end

    test "an unknown rail is refused rather than signed" do
      quote = quote_resp("teleport", permit2_pull(@spender))

      assert {:error, {:unsupported_pull_method, "teleport"}} =
               OriginPull.allowance_plan(quote, @spender, origin())
    end
  end

  describe "allowance_plan/3 -- the Permit2 spender pin" do
    test "an unpinned Permit2 pull is refused" do
      quote = quote_resp("permit2", permit2_pull(@spender))

      assert {:error, :unpinned_permit2_spender} =
               OriginPull.allowance_plan(quote, nil, origin())

      assert {:error, :unpinned_permit2_spender} = OriginPull.allowance_plan(quote, "", origin())
    end

    test "a served spender that is not the pinned one is refused, naming both" do
      quote = quote_resp("permit2", permit2_pull(@other_spender))

      assert {:error, {:pull_spender_mismatch, served, pinned}} =
               OriginPull.allowance_plan(quote, @spender, origin())

      assert served == String.downcase(@other_spender)
      assert pinned == String.downcase(@spender)
    end

    test "the match is on the address, not its checksum casing" do
      quote = quote_resp("permit2", permit2_pull(String.downcase(@spender)))

      assert {:ok, {:permit2, _}} =
               OriginPull.allowance_plan(quote, String.upcase(@spender), origin())
    end

    test "a Permit2 authorization with no spender is refused" do
      pull = put_in(permit2_pull(@spender), ["message", "spender"], nil)

      assert {:error, {:invalid_spender, :served, nil}} =
               OriginPull.allowance_plan(quote_resp("permit2", pull), @spender, origin())
    end

    test "a malformed pin is refused as malformed, not silently mismatched" do
      quote = quote_resp("permit2", permit2_pull(@spender))

      assert {:error, {:invalid_spender, :pinned, "0xnope"}} =
               OriginPull.allowance_plan(quote, "0xnope", origin())
    end

    test "a malformed envelope reaches this module's refusal, not an Access error" do
      quote = quote_resp("permit2", %{"message" => "not-a-map"})

      assert {:error, {:invalid_spender, :served, nil}} =
               OriginPull.allowance_plan(quote, @spender, origin())
    end
  end

  describe "allowance_plan/3 -- the served permit against the operator's intent" do
    test "a permit for another chain is refused" do
      quote = quote_resp("permit2", permit2_pull(@spender, chain_id: 42_161))

      assert {:error, {:pull_chain_mismatch, 42_161, 8453}} =
               OriginPull.allowance_plan(quote, @spender, origin())
    end

    test "a permit for another token is refused" do
      quote = quote_resp("permit2", permit2_pull(@spender, token: @other_token))

      assert {:error, {:pull_token_mismatch, @other_token, @token}} =
               OriginPull.allowance_plan(quote, @spender, origin())
    end

    test "a permit authorizing more than the transfer being ordered is refused" do
      quote = quote_resp("permit2", permit2_pull(@spender, amount: "3000001"))

      assert {:error, {:pull_amount_unbounded, "3000001", @amount}} =
               OriginPull.allowance_plan(quote, @spender, origin())
    end

    test "a permit for less than the ordered amount is allowed, and bounds the approve" do
      quote = quote_resp("permit2", permit2_pull(@spender, amount: "1500000"))

      assert {:ok, {:permit2, %{amount: 1_500_000}}} =
               OriginPull.allowance_plan(quote, @spender, origin())
    end

    test "a missing or unparseable chain, token or amount is refused, never defaulted" do
      for pull <- [
            permit2_pull(@spender, chain_id: nil),
            permit2_pull(@spender, token: nil),
            permit2_pull(@spender, amount: "lots")
          ] do
        assert {:error, _reason} =
                 OriginPull.allowance_plan(quote_resp("permit2", pull), @spender, origin())
      end
    end

    test "the plan carries the operator's leg, so the effect cannot act on the served one" do
      quote = quote_resp("permit2", permit2_pull(@spender))

      assert {:ok, {:permit2, %{chain_id: 8453, token: @token}}} =
               OriginPull.allowance_plan(quote, @spender, origin())
    end
  end

  describe "ensure_allowance/4" do
    test "sends nothing when the rail needs no allowance" do
      adapter = Mock.new()

      assert {:ok, :not_needed} = OriginPull.ensure_allowance(:not_needed, adapter, @owner)

      assert Mock.sent_calls(adapter) == []
    end

    test "sends nothing when the allowance already covers the pull" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, word(@amount))

      assert {:ok, :standing} =
               OriginPull.ensure_allowance({:permit2, permit()}, adapter, @owner)

      assert Mock.sent_calls(adapter) == []
    end

    test "leaves a standing max approval alone rather than replacing it" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, max_word())

      assert {:ok, :standing} =
               OriginPull.ensure_allowance({:permit2, permit()}, adapter, @owner)

      assert Mock.sent_calls(adapter) == []
    end

    test "approves exactly the intent's authorized pull, never uint256.max" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, zero_word())

      assert {:ok, {:approved, @amount, "0x" <> _}} =
               OriginPull.ensure_allowance({:permit2, permit()}, adapter, @owner)

      assert [{8453, [call]}] = Mock.sent_calls(adapter)
      assert call.to == @token
      assert <<@approve_selector::binary, args::binary>> = call.data

      # approve(address spender, uint256 amount): the amount is the second word.
      assert <<_spender::binary-size(32), granted::unsigned-big-integer-size(256)>> = args
      assert granted == @amount
      refute granted == Permit2Approver.max_uint256()
    end

    test "an allowance short of the pull is topped up to the pull, not beyond" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, word(@amount - 1))

      assert {:ok, {:approved, @amount, _hash}} =
               OriginPull.ensure_allowance({:permit2, permit()}, adapter, @owner)
    end

    test "a short allowance under --dry-run is reported with its bound, never sent" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, zero_word())

      assert {:ok, {:would_approve, @amount}} =
               OriginPull.ensure_allowance({:permit2, permit()}, adapter, @owner, dry_run: true)

      assert Mock.sent_calls(adapter) == []
    end

    test "a rehearsal judges the allowance by the same threshold the funded run does" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @token, @allowance_sig, word(@amount))

      assert {:ok, :standing} =
               OriginPull.ensure_allowance({:permit2, permit()}, adapter, @owner, dry_run: true)
    end

    test "the plan's chain and token decide where the allowance is read and granted" do
      adapter = Mock.new()
      :ok = Mock.set_contract_read(adapter, @other_token, @allowance_sig, zero_word())

      plan = {:permit2, permit(%{chain_id: 42_161, token: @other_token})}

      assert {:ok, {:approved, @amount, _hash}} =
               OriginPull.ensure_allowance(plan, adapter, @owner)

      assert [{42_161, [call]}] = Mock.sent_calls(adapter)
      assert call.to == @other_token
    end

    test "surfaces a failed allowance read instead of assuming an approval is needed" do
      adapter = Mock.new()

      assert {:error, {:no_canned_read, _, _}} =
               OriginPull.ensure_allowance({:permit2, permit()}, adapter, @owner)

      assert Mock.sent_calls(adapter) == []
    end
  end

  describe "describe/1" do
    test "distinguishes a granted approval from a standing one, and names the bound" do
      assert OriginPull.describe({:approved, 3_000_000, "0xabc"}) =~ "approve tx 0xabc"
      assert OriginPull.describe({:approved, 3_000_000, "0xabc"}) =~ "exactly 3000000 base units"
      assert OriginPull.describe(:standing) =~ "no approve sent"
      assert OriginPull.describe({:would_approve, 3_000_000}) =~ "SHORT"
      assert OriginPull.describe({:would_approve, 3_000_000}) =~ "exactly 3000000 base units"
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

    test "every cross-check refusal says what was served and what was intended" do
      chain = OriginPull.explain({:pull_chain_mismatch, 42_161, 8453})
      token = OriginPull.explain({:pull_token_mismatch, @other_token, @token})
      amount = OriginPull.explain({:pull_amount_unbounded, "9000000", 3_000_000})

      for {text, served} <- [{chain, "42161"}, {token, @other_token}, {amount, "9000000"}] do
        assert text =~ served
        assert text =~ "no allowance was granted"
      end

      assert chain =~ "8453"
      assert token =~ @token
      assert amount =~ "3000000"
    end

    test "an unrecognised reason is still reported, not swallowed" do
      text = OriginPull.explain({:transport, :econnrefused})

      assert text =~ "econnrefused"
      assert text =~ "Nothing was signed"
    end
  end
end
