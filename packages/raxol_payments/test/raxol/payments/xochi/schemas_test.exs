defmodule Raxol.Payments.Xochi.SchemasTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.Schemas.{
    QuoteRequest,
    QuoteResponse,
    ExecuteRequest,
    ExecuteResponse,
    IntentStatus
  }

  describe "QuoteRequest.to_json/1" do
    test "converts struct to camelCase JSON map" do
      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public",
        slippage_bps: 100,
        gasless: true
      }

      json = QuoteRequest.to_json(req)

      assert json["wallet"] == "0xabc"
      assert json["from_chain_id"] == 1
      assert json["to_chain_id"] == 8453
      assert json["from_amount"] == "1000000"
      assert json["settlement_preference"] == "public"
      assert json["slippage_bps"] == 100
      assert json["gasless"] == true
      assert is_integer(json["deadline"])
    end

    test "includes trust_score when set" do
      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public",
        trust_score: 75
      }

      json = QuoteRequest.to_json(req)
      assert json["trust_score"] == 75
    end

    test "omits trust_score when nil" do
      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      json = QuoteRequest.to_json(req)
      refute Map.has_key?(json, "trust_score")
    end

    test "includes attestations when non-empty" do
      attestation = %{
        type_code: 0x01,
        issuer: "0xoracle",
        subject: "0xsubject",
        issued_at: 1000,
        expires_at: 2000,
        signature: "0xsig",
        payload: <<0xDE, 0xAD>>
      }

      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public",
        attestations: [attestation]
      }

      json = QuoteRequest.to_json(req)
      assert [att] = json["attestations"]
      assert att["typeCode"] == 0x01
      assert att["issuer"] == "0xoracle"
      assert att["payload"] == "dead"
    end

    test "omits attestations when empty" do
      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      json = QuoteRequest.to_json(req)
      refute Map.has_key?(json, "attestations")
    end

    test "includes stealth pub keys when set" do
      spending = "0x02" <> String.duplicate("ab", 32)
      viewing = "0x03" <> String.duplicate("cd", 32)

      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "stealth",
        stealth_spending_pub_key: spending,
        stealth_viewing_pub_key: viewing
      }

      json = QuoteRequest.to_json(req)
      assert json["stealth_spending_pub_key"] == spending
      assert json["stealth_viewing_pub_key"] == viewing
    end

    test "omits stealth pub keys when nil" do
      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      json = QuoteRequest.to_json(req)
      refute Map.has_key?(json, "stealth_spending_pub_key")
      refute Map.has_key?(json, "stealth_viewing_pub_key")
    end
  end

  @valid_addr "0x" <> String.duplicate("ab", 20)

  describe "QuoteRequest.validate/1" do
    test "valid request returns :ok" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "public"
      }

      assert :ok = QuoteRequest.validate(req)
    end

    test "invalid wallet address returns error" do
      req = %QuoteRequest{
        wallet: "not_an_address",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "public"
      }

      assert {:error, {:invalid_wallet, _}} = QuoteRequest.validate(req)
    end

    test "invalid token address returns error" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xshort",
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "public"
      }

      assert {:error, {:invalid_from_token, _}} = QuoteRequest.validate(req)
    end

    test "chain ID of 0 returns error" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 0,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "public"
      }

      assert {:error, {:invalid_chain_id, _}} = QuoteRequest.validate(req)
    end

    test "stealth settlement without pub keys returns error" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "stealth"
      }

      assert {:error, {:stealth_keys_required, _}} = QuoteRequest.validate(req)
    end

    test "stealth settlement with compressed pub keys returns :ok" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "stealth",
        stealth_spending_pub_key: "0x02" <> String.duplicate("ab", 32),
        stealth_viewing_pub_key: "0x03" <> String.duplicate("cd", 32)
      }

      assert :ok = QuoteRequest.validate(req)
    end

    test "stealth settlement with malformed pub keys returns error" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "stealth",
        stealth_spending_pub_key: "0x04deadbeef",
        stealth_viewing_pub_key: "0x03" <> String.duplicate("cd", 32)
      }

      assert {:error, {:stealth_keys_required, _}} = QuoteRequest.validate(req)
    end
  end

  describe "QuoteResponse.from_json/1" do
    test "parses JSON response" do
      json = %{
        "intentId" => "intent_123",
        "quoteId" => "quote_456",
        "canSolve" => true,
        "toAmount" => "995000",
        "minToAmount" => "990000",
        "xochiFee" => "3000",
        "xochiFeeRate" => "0.30",
        "estimatedGasCost" => "0.50",
        "expiry" => "2026-04-06T12:30:30Z",
        "gasless" => false,
        "settlementOptions" => [%{"type" => "public", "available" => true}],
        "eip712Data" => %{"domain" => %{}}
      }

      resp = QuoteResponse.from_json(json)

      assert resp.intent_id == "intent_123"
      assert resp.quote_id == "quote_456"
      assert resp.can_solve == true
      assert resp.to_amount == "995000"
      assert resp.xochi_fee == "3000"
      assert resp.eip712_data == %{"domain" => %{}}
      assert length(resp.settlement_options) == 1
    end

    test "defaults can_solve to false" do
      json = %{"intentId" => "i", "quoteId" => "q"}
      resp = QuoteResponse.from_json(json)
      assert resp.can_solve == false
    end

    test "parses the live snake_case shape with eip712 and payment_method" do
      json = %{
        "intent_id" => "xi_1",
        "quote_id" => "xq_1",
        "can_solve" => true,
        "to_amount" => "24925000",
        "min_to_amount" => "24800375",
        "payment_method" => "erc3009",
        "fee" => %{"fee_amount" => "75000", "total_bps" => 30},
        "eip712" => %{"domain" => %{"name" => "Xochi"}, "types" => %{}, "message" => %{}},
        "settlement_options" => ["public"]
      }

      resp = QuoteResponse.from_json(json)

      assert resp.intent_id == "xi_1"
      assert resp.quote_id == "xq_1"
      assert resp.can_solve == true
      assert resp.to_amount == "24925000"
      assert resp.payment_method == "erc3009"

      assert resp.eip712_data == %{
               "domain" => %{"name" => "Xochi"},
               "types" => %{},
               "message" => %{}
             }

      assert resp.xochi_fee == "75000"
      assert resp.settlement_options == ["public"]
    end

    test "an unfillable snake_case quote carries reason as error" do
      json = %{
        "intent_id" => "i",
        "quote_id" => "q",
        "can_solve" => false,
        "reason" => "no liquidity"
      }

      resp = QuoteResponse.from_json(json)
      assert resp.can_solve == false
      assert resp.error == "no liquidity"
    end
  end

  describe "ExecuteRequest.to_json/1" do
    test "converts to JSON with required fields" do
      req = %ExecuteRequest{
        intent_id: "intent_123",
        quote_id: "quote_456",
        signature: "0xdeadbeef",
        nonce: 42
      }

      json = ExecuteRequest.to_json(req)

      assert json["intent_id"] == "intent_123"
      assert json["quote_id"] == "quote_456"
      assert json["signature"] == "0xdeadbeef"
      assert json["nonce"] == 42
      refute Map.has_key?(json, "pull_signature")
    end

    test "includes optional fields when set" do
      req = %ExecuteRequest{
        intent_id: "i",
        quote_id: "q",
        signature: "0x",
        nonce: 1,
        pull_signature: "0xpull",
        aztec_proof: "0xproof"
      }

      json = ExecuteRequest.to_json(req)
      assert json["pull_signature"] == "0xpull"
      assert json["aztec_proof"] == "0xproof"
    end
  end

  describe "ExecuteResponse.from_json/1" do
    test "parses JSON response" do
      json = %{
        "success" => true,
        "intentId" => "intent_123",
        "status" => "executing",
        "txHash" => "0xabc"
      }

      resp = ExecuteResponse.from_json(json)
      assert resp.success == true
      assert resp.intent_id == "intent_123"
      assert resp.status == :executing
      assert resp.tx_hash == "0xabc"
    end

    test "parses stealth settlement fields" do
      json = %{
        "success" => true,
        "intentId" => "i",
        "status" => "settling",
        "stealthAddress" => "0xstealth",
        "ephemeralPubKey" => "0xeph",
        "viewTag" => 42
      }

      resp = ExecuteResponse.from_json(json)
      assert resp.stealth_address == "0xstealth"
      assert resp.ephemeral_pub_key == "0xeph"
      assert resp.view_tag == 42
    end
  end

  describe "IntentStatus.from_json/1" do
    test "parses JSON status" do
      json = %{
        "intentId" => "intent_123",
        "status" => "bridging",
        "txHash" => "0xabc",
        "updatedAt" => "2026-04-06T12:00:00Z",
        "terminal" => false
      }

      status = IntentStatus.from_json(json)
      assert status.intent_id == "intent_123"
      assert status.status == :bridging
      assert status.tx_hash == "0xabc"
      assert status.terminal == false
    end

    test "detects terminal statuses" do
      for s <- ["completed", "failed", "expired"] do
        json = %{"intentId" => "i", "status" => s}
        status = IntentStatus.from_json(json)
        assert IntentStatus.terminal?(status), "expected #{s} to be terminal"
      end
    end

    test "non-terminal statuses" do
      for s <- ["pending", "executing", "bridging", "settling"] do
        json = %{"intentId" => "i", "status" => s}
        status = IntentStatus.from_json(json)
        refute IntentStatus.terminal?(status), "expected #{s} to be non-terminal"
      end
    end

    test "parses PXE shielded settlement fields" do
      json = %{
        "intentId" => "intent_pxe",
        "status" => "completed",
        "settlementType" => "shielded",
        "noteCommitment" => "0xcommit123",
        "nullifierHash" => "0xnull456",
        "l2TxHash" => "0xl2tx789"
      }

      status = IntentStatus.from_json(json)
      assert status.settlement_type == :shielded
      assert status.note_commitment == "0xcommit123"
      assert status.nullifier_hash == "0xnull456"
      assert status.l2_tx_hash == "0xl2tx789"
    end

    test "parses stealth settlement type" do
      json = %{
        "intentId" => "i",
        "status" => "completed",
        "settlementType" => "stealth"
      }

      status = IntentStatus.from_json(json)
      assert status.settlement_type == :stealth
    end

    test "nil settlement type when not present" do
      json = %{"intentId" => "i", "status" => "pending"}
      status = IntentStatus.from_json(json)
      assert status.settlement_type == nil
    end

    test "shielded? returns true for shielded settlement_type" do
      json = %{
        "intentId" => "i",
        "status" => "completed",
        "settlementType" => "shielded"
      }

      status = IntentStatus.from_json(json)
      assert IntentStatus.shielded?(status)
    end

    test "shielded? returns true when note_commitment present" do
      json = %{
        "intentId" => "i",
        "status" => "completed",
        "noteCommitment" => "0xcommit"
      }

      status = IntentStatus.from_json(json)
      assert IntentStatus.shielded?(status)
    end

    test "shielded? returns false for public settlement" do
      json = %{
        "intentId" => "i",
        "status" => "completed",
        "settlementType" => "public"
      }

      status = IntentStatus.from_json(json)
      refute IntentStatus.shielded?(status)
    end

    test "parses attestation_status verified" do
      json = %{"intentId" => "i", "status" => "completed", "attestationStatus" => "verified"}
      status = IntentStatus.from_json(json)
      assert status.attestation_status == :verified
    end

    test "parses attestation_status rejected" do
      json = %{"intentId" => "i", "status" => "failed", "attestationStatus" => "rejected"}
      status = IntentStatus.from_json(json)
      assert status.attestation_status == :rejected
    end

    test "parses attestation_status not_required" do
      json = %{"intentId" => "i", "status" => "completed", "attestationStatus" => "not_required"}
      status = IntentStatus.from_json(json)
      assert status.attestation_status == :not_required
    end

    test "attestation_status nil when not present" do
      json = %{"intentId" => "i", "status" => "pending"}
      status = IntentStatus.from_json(json)
      assert status.attestation_status == nil
    end
  end
end
