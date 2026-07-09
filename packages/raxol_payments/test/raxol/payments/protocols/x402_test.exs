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

  describe "build_payment/2 USDC domain resolution" do
    # Captures the domain passed to sign_typed_data so we can assert that
    # build_payment looks up the per-chain USDC name/version rather than
    # using a hardcoded "USD Coin".
    defmodule CaptureWallet do
      @moduledoc false
      @behaviour Raxol.Payments.Wallet
      @impl true
      def address, do: "0x" <> String.duplicate("ab", 20)
      @impl true
      def chain_id, do: 8453
      @impl true
      def sign_message(_msg), do: {:ok, <<0::512>>}
      @impl true
      def sign_typed_data(domain, _types, message) do
        Process.put(:captured_domain, domain)
        Process.put(:captured_message, message)
        {:ok, <<0::512>>}
      end

      @impl true
      def sign_hash(_digest), do: {:ok, <<0::520>>}
    end

    defp challenge_for(chain_id, currency) do
      %{
        price: 1_000_000,
        currency: currency,
        network: "eip155:#{chain_id}",
        pay_to: "0x" <> String.duplicate("cd", 20),
        nonce: "0x" <> String.duplicate("12", 32),
        valid_after: 0,
        valid_before: 9_999_999_999,
        extra: %{}
      }
    end

    test "Base mainnet (8453) resolves to 'USD Coin'" do
      challenge =
        challenge_for(8453, "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")

      assert {:ok, _} = X402.build_payment(challenge, CaptureWallet)

      assert %{
               name: "USD Coin",
               version: "2",
               chainId: 8453,
               verifyingContract: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
             } = Process.get(:captured_domain)
    end

    test "Base Sepolia (84532) resolves to 'USDC' instead of hardcoded 'USD Coin'" do
      challenge =
        challenge_for(84_532, "0x036CbD53842c5426634e7929541eC2318f3dCF7e")

      assert {:ok, _} = X402.build_payment(challenge, CaptureWallet)

      assert %{
               name: "USDC",
               version: "2",
               chainId: 84_532,
               verifyingContract: "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
             } = Process.get(:captured_domain)
    end

    test "Ethereum Sepolia (11155111) resolves to 'USDC'" do
      challenge =
        challenge_for(11_155_111, "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238")

      assert {:ok, _} = X402.build_payment(challenge, CaptureWallet)

      assert %{name: "USDC", version: "2", chainId: 11_155_111} =
               Process.get(:captured_domain)
    end

    test "Optimism Sepolia (11155420) resolves to 'USDC'" do
      challenge =
        challenge_for(11_155_420, "0x5fd84259d66Cd46123540766Be93DFE6D43130D7")

      assert {:ok, _} = X402.build_payment(challenge, CaptureWallet)

      assert %{name: "USDC", version: "2", chainId: 11_155_420} =
               Process.get(:captured_domain)
    end

    test "Arbitrum Sepolia (421614) resolves to 'USD Coin' (verified on-chain)" do
      challenge =
        challenge_for(421_614, "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d")

      assert {:ok, _} = X402.build_payment(challenge, CaptureWallet)

      assert %{name: "USD Coin", version: "2", chainId: 421_614} =
               Process.get(:captured_domain)
    end
  end

  describe "build_payment/2 signed value binding" do
    defmodule ValueWallet do
      @moduledoc false
      @behaviour Raxol.Payments.Wallet
      @impl true
      def address, do: "0x" <> String.duplicate("ab", 20)
      @impl true
      def chain_id, do: 8453
      @impl true
      def sign_message(_msg), do: {:ok, <<0::512>>}
      @impl true
      def sign_typed_data(_domain, _types, message) do
        Process.put(:captured_message, message)
        {:ok, <<0::512>>}
      end

      @impl true
      def sign_hash(_digest), do: {:ok, <<0::520>>}
    end

    defp priced_challenge(price) do
      %{
        price: price,
        currency: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        network: "eip155:8453",
        pay_to: "0x" <> String.duplicate("cd", 20),
        nonce: "0x" <> String.duplicate("12", 32),
        valid_after: 0,
        valid_before: 9_999_999_999,
        extra: %{}
      }
    end

    test "signs exactly the atomic integer price the gate reads" do
      # amount/1 (the gate) reads price as atomic units; the signed value must be
      # that same atomic integer, so the gate and the signature can never diverge.
      challenge = priced_challenge(1_000_000)
      assert {:ok, _} = X402.build_payment(challenge, ValueWallet)
      assert Process.get(:captured_message).value == 1_000_000
    end

    test "signs the integer parsed from an all-digit string price" do
      challenge = priced_challenge("250000")
      assert {:ok, _} = X402.build_payment(challenge, ValueWallet)
      assert Process.get(:captured_message).value == 250_000
    end

    test "refuses to sign a float price (would diverge from the gated amount)" do
      assert {:error, {:invalid_price, _}} =
               X402.build_payment(priced_challenge(0.05), ValueWallet)
    end

    test "refuses to sign a decimal-string price" do
      assert {:error, {:invalid_price, _}} =
               X402.build_payment(priced_challenge("0.05"), ValueWallet)
    end
  end

  describe "parse_challenge/1 rejects malformed atomic amounts" do
    defp challenge_header(price) do
      body =
        %{
          "maxAmountRequired" => price,
          "payTo" => "0x" <> String.duplicate("cd", 20),
          "asset" => "0x" <> String.duplicate("ef", 20),
          "network" => "eip155:8453"
        }
        |> Jason.encode!()
        |> Base.encode64()

      [{"payment-required", body}]
    end

    test "accepts a positive integer-string price" do
      assert {:ok, %{price: "1000000"}} = X402.parse_challenge(challenge_header("1000000"))
    end

    test "rejects a float price" do
      assert {:error, {:invalid_amount, _}} = X402.parse_challenge(challenge_header(0.05))
    end

    test "rejects a decimal-string price" do
      assert {:error, {:invalid_amount, _}} = X402.parse_challenge(challenge_header("0.05"))
    end

    test "rejects a zero price" do
      assert {:error, {:invalid_amount, _}} = X402.parse_challenge(challenge_header(0))
    end
  end
end
