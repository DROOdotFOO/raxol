defmodule Raxol.Payments.Relay.SchemasTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Relay.Schemas
  alias Raxol.Payments.Relay.Schemas.{QuoteRequest, QuoteResponse, ExecuteRequest, StatusResponse}

  @tron Schemas.tron_chain_id()
  @tron_addr "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @evm_addr "0x" <> String.duplicate("ab", 20)
  @usdt_trc20 "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"
  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  defp evm_to_tron_request(overrides \\ %{}) do
    base = %QuoteRequest{
      transfer_id: "t_1",
      from_chain_id: 8453,
      to_chain_id: @tron,
      from_token: @usdc_base,
      to_token: @usdt_trc20,
      from_amount: "500000",
      from_address: @evm_addr,
      to_address: @tron_addr
    }

    struct(base, overrides)
  end

  describe "tron_chain?/1" do
    test "recognizes the Tron mainnet chain id" do
      assert Schemas.tron_chain?(@tron)
      refute Schemas.tron_chain?(8453)
    end
  end

  describe "QuoteRequest.validate/1" do
    test "accepts an EVM -> Tron route with matching address formats" do
      assert :ok = QuoteRequest.validate(evm_to_tron_request())
    end

    test "rejects a same-chain route" do
      req = evm_to_tron_request(%{to_chain_id: 8453, to_address: @evm_addr})
      assert {:error, {:invalid_route, _}} = QuoteRequest.validate(req)
    end

    test "rejects a route with no Tron leg" do
      req = evm_to_tron_request(%{to_chain_id: 42_161, to_address: @evm_addr})
      assert {:error, {:invalid_route, _}} = QuoteRequest.validate(req)
    end

    test "rejects an EVM address on the Tron leg" do
      req = evm_to_tron_request(%{to_address: @evm_addr})
      assert {:error, {:invalid_to_address, _}} = QuoteRequest.validate(req)
    end

    test "rejects a Tron address on the EVM leg" do
      req = evm_to_tron_request(%{from_address: @tron_addr})
      assert {:error, {:invalid_from_address, _}} = QuoteRequest.validate(req)
    end
  end

  describe "QuoteRequest.to_json/1" do
    test "emits snake_case fields and omits nil deadline / empty metadata" do
      json = QuoteRequest.to_json(evm_to_tron_request())

      assert json["transfer_id"] == "t_1"
      assert json["to_chain_id"] == @tron
      assert json["to_address"] == @tron_addr
      assert json["slippage_bps"] == 50
      refute Map.has_key?(json, "deadline")
      refute Map.has_key?(json, "metadata")
    end
  end

  describe "QuoteResponse.from_json/1" do
    test "parses the Relay quote shape" do
      resp =
        QuoteResponse.from_json(%{
          "transfer_id" => "t_1",
          "quote_id" => "q_1",
          "can_fill" => true,
          "to_amount" => "499000",
          "expiry" => 1_900_000_000,
          "deposit_address" => @tron_addr,
          "instant_settlement" => true
        })

      assert resp.quote_id == "q_1"
      assert resp.can_fill == true
      assert resp.to_amount == "499000"
      assert resp.deposit_address == @tron_addr
      assert resp.instant_settlement == true
    end

    test "defaults can_fill to false" do
      resp = QuoteResponse.from_json(%{"transfer_id" => "t", "quote_id" => "q"})
      assert resp.can_fill == false
    end
  end

  describe "ExecuteRequest.to_json/1" do
    test "carries only transfer_id and quote_id (no signature)" do
      json = ExecuteRequest.to_json(%ExecuteRequest{transfer_id: "t_1", quote_id: "q_1"})
      assert json == %{"transfer_id" => "t_1", "quote_id" => "q_1"}
    end
  end

  describe "StatusResponse.from_json/1" do
    test "parses statuses and marks terminal ones" do
      for {s, terminal} <- [
            {"pending", false},
            {"executing", false},
            {"confirming", false},
            {"completed", true},
            {"failed", true},
            {"refunded", true}
          ] do
        status = StatusResponse.from_json(%{"transfer_id" => "t", "status" => s})
        assert StatusResponse.terminal?(status) == terminal
      end
    end

    test "parses the refunded status and its reason (camelCase and snake_case)" do
      for key <- ["refundReason", "refund_reason"] do
        status =
          StatusResponse.from_json(%{
            "transfer_id" => "t",
            "status" => "refunded",
            key => "reverted on Tron"
          })

        assert status.status == :refunded
        assert status.refund_reason == "reverted on Tron"
        assert StatusResponse.terminal?(status)
      end
    end

    test "parses tx hash and error" do
      status =
        StatusResponse.from_json(%{
          "transfer_id" => "t",
          "status" => "completed",
          "tx_hash" => "abc123",
          "actual_to_amount" => "499000"
        })

      assert status.status == :completed
      assert status.tx_hash == "abc123"
      assert status.actual_to_amount == "499000"
    end

    test "unknown status is non-terminal" do
      status = StatusResponse.from_json(%{"transfer_id" => "t", "status" => "weird"})
      assert status.status == :unknown
      refute StatusResponse.terminal?(status)
    end
  end
end
