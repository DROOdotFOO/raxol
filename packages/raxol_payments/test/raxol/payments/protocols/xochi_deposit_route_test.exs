defmodule Raxol.Payments.Protocols.XochiDepositRouteTest do
  # #400: a Tron-origin deposit-route quote returns a bare deposit_address; raxol
  # verifies the deposit_attestation against the pinned signer before surfacing
  # it, and fails closed otherwise. raxol never sends the Tron funds.
  use ExUnit.Case, async: true

  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Xochi.Capabilities
  alias Raxol.Payments.Xochi.DepositAttestation
  alias Raxol.Payments.Xochi.Schemas.{DepositRouteRequest, QuoteResponse}
  alias Raxol.Payments.Protocols.Xochi

  @tron_usdt "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @tron_wallet "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
  @deposit_addr "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
  @evm_recipient "0x" <> String.duplicate("ab", 20)

  @intent_id "xi_dep_1"
  @quote_id "xq_dep_1"
  @from_amount "1000000"

  @priv <<7::256>>

  defp request do
    %DepositRouteRequest{
      wallet: @tron_wallet,
      from_chain_id: 728_126_428,
      to_chain_id: 8453,
      from_token: @tron_usdt,
      to_token: @evm_recipient,
      from_amount: @from_amount,
      recipient_address: @evm_recipient
    }
  end

  defp signer_address do
    {:ok, <<_prefix::8, xy::binary-size(64)>>} = ExSecp256k1.create_public_key(@priv)
    <<_first12::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(xy)
    "0x" <> Base.encode16(addr, case: :lower)
  end

  # Sign the deposit attestation over the exact binding fields, as Riddler does.
  defp attestation(deposit_address \\ @deposit_addr) do
    msg =
      DepositAttestation.message(%{
        intent_id: @intent_id,
        quote_id: @quote_id,
        from_chain_id: 728_126_428,
        from_token: @tron_usdt,
        from_amount: @from_amount,
        deposit_address: deposit_address
      })

    digest =
      ("\x19Ethereum Signed Message:\n" <> Integer.to_string(byte_size(msg)) <> msg)
      |> ExKeccak.hash_256()

    {:ok, sig} = ExSecp256k1.sign(digest, @priv)
    "0x" <> Base.encode16(EIP712.pack_signature(sig), case: :lower)
  end

  # Stub /api/intent/quote with a deposit-route quote body.
  defp quote_plug(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  defp config(body) do
    %{base_url: "https://xochi.test", req_options: [plug: quote_plug(body)]}
  end

  defp deposit_quote_body(overrides \\ %{}) do
    Map.merge(
      %{
        "intent_id" => @intent_id,
        "quote_id" => @quote_id,
        "can_solve" => true,
        "to_amount" => "995000",
        "deposit_address" => @deposit_addr,
        "deposit_attestation" => attestation(),
        "deposit_deadline" => 1_900_000_000
      },
      overrides
    )
  end

  describe "deposit_route_quote/3" do
    test "verifies the attestation and returns deposit instructions" do
      opts = [deposit_attestation_signer: signer_address()]

      assert {:ok, instructions} =
               Xochi.deposit_route_quote(config(deposit_quote_body()), request(), opts)

      assert instructions.intent_id == @intent_id
      assert instructions.deposit_address == @deposit_addr
      assert instructions.deposit_deadline == 1_900_000_000
      assert instructions.from_chain_id == 728_126_428
      assert instructions.from_token == @tron_usdt
      assert instructions.from_amount == @from_amount
      assert instructions.recipient_address == @evm_recipient
      assert instructions.to_amount == "995000"
    end

    test "fails closed when the deposit_address was swapped (attestation over the real one)" do
      # The endpoint serves a different deposit address than the one the signer
      # attested -- the attestation no longer recovers to the pinned signer.
      body = deposit_quote_body(%{"deposit_address" => "TXswapped000000000000000000000000000"})
      opts = [deposit_attestation_signer: signer_address()]

      assert {:error, :attestation_mismatch} =
               Xochi.deposit_route_quote(config(body), request(), opts)
    end

    test "fails closed when the attestation is from a different signer" do
      other = "0x000000000000000000000000000000000000dead"

      assert {:error, :attestation_mismatch} =
               Xochi.deposit_route_quote(config(deposit_quote_body()), request(),
                 deposit_attestation_signer: other
               )
    end

    test "fails closed when no signer is pinned (capabilities publishes none)" do
      assert {:error, :deposit_signer_unavailable} =
               Xochi.deposit_route_quote(config(deposit_quote_body()), request(),
                 capabilities: Capabilities.fallback()
               )
    end

    test "fails closed when the quote carries no attestation" do
      body = deposit_quote_body(%{"deposit_attestation" => nil})

      assert {:error, :missing_attestation} =
               Xochi.deposit_route_quote(config(body), request(),
                 deposit_attestation_signer: signer_address()
               )
    end

    test "rejects a non-deposit-route quote (an EVM pull quote has no deposit_address)" do
      body =
        deposit_quote_body(%{"deposit_address" => nil, "eip712" => %{"domain" => %{}}})

      assert {:error, :not_a_deposit_route} =
               Xochi.deposit_route_quote(config(body), request(),
                 deposit_attestation_signer: signer_address()
               )
    end

    test "surfaces an unsolvable quote as an error" do
      body = deposit_quote_body(%{"can_solve" => false, "reason" => "no liquidity"})

      assert {:error, {:not_solvable, "no liquidity"}} =
               Xochi.deposit_route_quote(config(body), request(),
                 deposit_attestation_signer: signer_address()
               )
    end
  end

  describe "verify_deposit_route/4 (pure verify over a fetched quote)" do
    test "returns instructions for a valid attestation" do
      quote = QuoteResponse.from_json(deposit_quote_body())

      assert {:ok, instructions} =
               Xochi.verify_deposit_route(%{base_url: "https://xochi.test"}, request(), quote,
                 deposit_attestation_signer: signer_address()
               )

      assert instructions.deposit_address == @deposit_addr
    end
  end
end
