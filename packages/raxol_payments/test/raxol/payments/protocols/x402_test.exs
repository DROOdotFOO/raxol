defmodule Raxol.Payments.Protocols.X402Test do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Protocols.X402

  describe "detect?/2" do
    test "detects payment-required header" do
      headers = [{"payment-required", "eyJ0ZXN0IjogdHJ1ZX0="}]
      assert X402.detect?(402, headers)
    end

    test "detects case-insensitive header" do
      headers = [{"Payment-Required", "eyJ0ZXN0IjogdHJ1ZX0="}]
      assert X402.detect?(402, headers)
    end

    test "returns false for non-402 status" do
      headers = [{"payment-required", "eyJ0ZXN0IjogdHJ1ZX0="}]
      refute X402.detect?(200, headers)
    end

    test "returns false without payment-required header" do
      headers = [{"content-type", "application/json"}]
      refute X402.detect?(402, headers)
    end
  end

  describe "parse_challenge/1" do
    test "decodes base64 JSON challenge" do
      payload =
        Jason.encode!(%{
          "maxAmountRequired" => "1000000",
          "asset" => "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          "network" => "eip155:8453",
          "payTo" => "0x1234567890abcdef1234567890abcdef12345678",
          "nonce" => "0xabc123",
          "validBefore" => 1_700_000_000
        })

      encoded = Base.encode64(payload)
      headers = [{"payment-required", encoded}]

      assert {:ok, challenge} = X402.parse_challenge(headers)
      assert challenge.price == "1000000"
      assert challenge.currency == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      assert challenge.network == "eip155:8453"
      assert challenge.pay_to == "0x1234567890abcdef1234567890abcdef12345678"
      assert challenge.nonce == "0xabc123"
      assert challenge.valid_before == 1_700_000_000
    end

    test "returns error for missing header" do
      assert {:error, {:missing_header, "payment-required"}} =
               X402.parse_challenge([])
    end
  end

  describe "amount/1" do
    test "normalizes USDC atomic units to human decimals on Base" do
      challenge = %{
        price: 1_000_000,
        currency: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        network: "eip155:8453"
      }

      assert Decimal.equal?(X402.amount(challenge), Decimal.new("1"))
    end

    test "10_000 USDC atomic = 0.01 human" do
      challenge = %{
        price: 10_000,
        currency: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        network: "eip155:8453"
      }

      assert Decimal.equal?(X402.amount(challenge), Decimal.new("0.01"))
    end

    test "WETH (18 decimals) on Base normalizes correctly" do
      challenge = %{
        price: Integer.pow(10, 18),
        currency: "0x4200000000000000000000000000000000000006",
        network: "eip155:8453"
      }

      assert Decimal.equal?(X402.amount(challenge), Decimal.new("1"))
    end

    test "unknown asset defaults to 6 decimals (USDC-safe)" do
      challenge = %{
        price: 1_000_000,
        currency: "0x" <> String.duplicate("dd", 20),
        network: "eip155:8453"
      }

      assert Decimal.equal?(X402.amount(challenge), Decimal.new("1"))
    end

    test "accepts string price" do
      challenge = %{
        price: "10000",
        currency: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        network: "eip155:8453"
      }

      assert Decimal.equal?(X402.amount(challenge), Decimal.new("0.01"))
    end
  end

  describe "parse_receipt/1" do
    test "decodes base64 JSON receipt" do
      payload =
        Jason.encode!(%{
          "transactionHash" => "0xdeadbeef",
          "network" => "eip155:8453",
          "success" => true
        })

      encoded = Base.encode64(payload)
      headers = [{"x-payment-response", encoded}]

      assert {:ok, receipt} = X402.parse_receipt(headers)
      assert receipt.tx_hash == "0xdeadbeef"
      assert receipt.network == "eip155:8453"
      assert receipt.success == true
    end

    test "returns error for missing header" do
      assert {:error, :no_receipt} = X402.parse_receipt([])
    end
  end
end
