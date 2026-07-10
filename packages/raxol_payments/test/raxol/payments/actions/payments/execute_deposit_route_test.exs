defmodule Raxol.Payments.Actions.Payments.ExecuteDepositRouteTest do
  # #400: the deposit-route action fetches a Tron-origin quote and verifies its
  # deposit_attestation before returning the deposit instructions. raxol never
  # sends the funds; the agent's own Tron wallet funds the verified address.
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments
  alias Raxol.Payments.Actions.Payments.ExecuteDepositRoute
  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Xochi.Capabilities
  alias Raxol.Payments.Xochi.DepositAttestation

  @tron_usdt "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @tron_wallet "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
  @deposit_addr "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
  @evm_recipient "0x" <> String.duplicate("ab", 20)

  @intent_id "xi_dep_1"
  @quote_id "xq_dep_1"
  @amount "1000000"
  @priv <<9::256>>

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        wallet: @tron_wallet,
        from_chain_id: 728_126_428,
        to_chain_id: 8453,
        from_token: @tron_usdt,
        to_token: @evm_recipient,
        amount_atomic: @amount,
        recipient_address: @evm_recipient,
        slippage_bps: 50
      },
      overrides
    )
  end

  defp signer_address do
    {:ok, <<_prefix::8, xy::binary-size(64)>>} = ExSecp256k1.create_public_key(@priv)
    <<_first12::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(xy)
    "0x" <> Base.encode16(addr, case: :lower)
  end

  defp attestation do
    msg =
      DepositAttestation.message(%{
        intent_id: @intent_id,
        quote_id: @quote_id,
        from_chain_id: 728_126_428,
        from_token: @tron_usdt,
        from_amount: @amount,
        deposit_address: @deposit_addr
      })

    digest =
      ("\x19Ethereum Signed Message:\n" <> Integer.to_string(byte_size(msg)) <> msg)
      |> ExKeccak.hash_256()

    {:ok, sig} = ExSecp256k1.sign(digest, @priv)
    "0x" <> Base.encode16(EIP712.pack_signature(sig), case: :lower)
  end

  defp config do
    body = %{
      "intent_id" => @intent_id,
      "quote_id" => @quote_id,
      "can_solve" => true,
      "to_amount" => "995000",
      "deposit_address" => @deposit_addr,
      "deposit_attestation" => attestation(),
      "deposit_deadline" => 1_900_000_000
    }

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    %{base_url: "https://xochi.test", req_options: [plug: plug]}
  end

  describe "run/2" do
    test "verifies the attestation and returns the deposit instructions" do
      ctx = %{xochi_config: config(), deposit_attestation_signer: signer_address()}

      assert {:ok, result} = ExecuteDepositRoute.run(params(), ctx)
      assert result.intent_id == @intent_id
      assert result.deposit_address == @deposit_addr
      assert result.deposit_deadline == 1_900_000_000
      assert result.from_amount == @amount
      assert result.recipient_address == @evm_recipient
    end

    test "fails closed when the attestation does not recover to the pinned signer" do
      ctx = %{
        xochi_config: config(),
        deposit_attestation_signer: "0x000000000000000000000000000000000000dead"
      }

      assert {:error, :attestation_mismatch} = ExecuteDepositRoute.run(params(), ctx)
    end

    test "fails closed when no signer is pinned" do
      ctx = %{xochi_config: config(), capabilities: Capabilities.fallback()}
      assert {:error, :deposit_signer_unavailable} = ExecuteDepositRoute.run(params(), ctx)
    end

    test "rejects an EVM origin (deposit routes are non-EVM only)" do
      ctx = %{xochi_config: config(), deposit_attestation_signer: signer_address()}

      assert {:error, {:unsupported_origin_vm, _}} =
               ExecuteDepositRoute.run(params(%{from_chain_id: 8453}), ctx)
    end

    test "errors when :xochi_config is absent from the context" do
      assert {:error, {:missing_context, :xochi_config}} =
               ExecuteDepositRoute.run(params(), %{})
    end
  end

  describe "registration" do
    test "is registered in the payment action set" do
      assert ExecuteDepositRoute in Payments.actions()
    end

    test "exposes the payment_execute_deposit_route tool name" do
      assert ExecuteDepositRoute.__action_meta__().name == "payment_execute_deposit_route"
    end
  end
end
