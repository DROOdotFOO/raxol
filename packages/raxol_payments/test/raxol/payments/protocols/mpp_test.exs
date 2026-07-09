defmodule Raxol.Payments.Protocols.MPPTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Protocols.MPP

  describe "detect?/2" do
    test "detects WWW-Authenticate Payment header" do
      headers = [{"www-authenticate", "Payment eyJ0ZXN0IjogdHJ1ZX0="}]
      assert MPP.detect?(402, headers)
    end

    test "detects case-insensitive header" do
      headers = [{"WWW-Authenticate", "Payment eyJ0ZXN0IjogdHJ1ZX0="}]
      assert MPP.detect?(402, headers)
    end

    test "returns false for non-Payment auth scheme" do
      headers = [{"www-authenticate", "Bearer realm=test"}]
      refute MPP.detect?(402, headers)
    end

    test "returns false for non-402 status" do
      headers = [{"www-authenticate", "Payment eyJ0ZXN0IjogdHJ1ZX0="}]
      refute MPP.detect?(200, headers)
    end

    test "returns false without auth header" do
      headers = [{"content-type", "application/json"}]
      refute MPP.detect?(402, headers)
    end
  end

  describe "parse_challenge/1" do
    test "decodes challenge from auth header" do
      payload =
        Jason.encode!(%{
          "amount" => "100",
          "currency" => "USDC",
          "recipient" => "0xabcdef1234567890abcdef1234567890abcdef12",
          "methods" => ["tempo", "stripe"],
          "network" => "tempo:mainnet",
          "nonce" => "abc123"
        })

      encoded = Base.encode64(payload)
      headers = [{"www-authenticate", "Payment " <> encoded}]

      assert {:ok, challenge} = MPP.parse_challenge(headers)
      assert challenge.amount == "100"
      assert challenge.currency == "USDC"
      assert challenge.recipient == "0xabcdef1234567890abcdef1234567890abcdef12"
      assert challenge.methods == ["tempo", "stripe"]
      assert challenge.nonce == "abc123"
    end

    test "returns error for missing header" do
      assert {:error, {:missing_header, "www-authenticate"}} = MPP.parse_challenge([])
    end

    test "accepts an integer atomic amount" do
      assert {:ok, %{amount: 100}} = MPP.parse_challenge(challenge_headers(%{"amount" => 100}))
    end

    test "rejects a float amount as malformed atomic units" do
      assert {:error, {:invalid_amount, 1.5}} =
               MPP.parse_challenge(challenge_headers(%{"amount" => 1.5}))
    end

    test "rejects a decimal-string amount as malformed atomic units" do
      assert {:error, {:invalid_amount, "1.50"}} =
               MPP.parse_challenge(challenge_headers(%{"amount" => "1.50"}))
    end

    test "rejects a zero amount" do
      assert {:error, {:invalid_amount, 0}} =
               MPP.parse_challenge(challenge_headers(%{"amount" => 0}))
    end
  end

  describe "amount/1" do
    test "returns a Decimal for an all-digit atomic amount" do
      assert Decimal.equal?(MPP.amount(%{amount: "100"}), Decimal.new("100"))
    end

    test "returns a Decimal for an integer atomic amount" do
      assert Decimal.equal?(MPP.amount(%{amount: 100}), Decimal.new(100))
    end
  end

  describe "gate cap and signed amount stay the same unit" do
    defmodule StubWallet do
      def address, do: "0x1111111111111111111111111111111111111111"
      def sign_message(_message), do: {:ok, <<0::256>>}
    end

    test "amount/1 and the signed credential both carry the challenge's atomic amount" do
      # The SpendingPolicy cap reads amount/1; the on-the-wire credential carries
      # build_payment's amount. Both derive from challenge.amount verbatim, so
      # they can never diverge into different units.
      challenge = %{
        amount: 100,
        currency: "USDC",
        recipient: "0xabcdef1234567890abcdef1234567890abcdef12",
        methods: ["tempo"],
        network: "tempo:mainnet",
        nonce: "abc123"
      }

      assert Decimal.equal?(MPP.amount(challenge), Decimal.new(100))

      assert {:ok, [{"authorization", "Payment " <> encoded}]} =
               MPP.build_payment(challenge, StubWallet)

      {:ok, json} = Base.decode64(encoded)
      {:ok, credential} = Jason.decode(json)
      assert credential["amount"] == 100
    end
  end

  describe "parse_receipt/1" do
    test "decodes base64 JSON receipt" do
      payload =
        Jason.encode!(%{
          "transactionHash" => "0xcafebabe",
          "amount" => "100",
          "method" => "tempo",
          "success" => true
        })

      encoded = Base.encode64(payload)
      headers = [{"payment-receipt", encoded}]

      assert {:ok, receipt} = MPP.parse_receipt(headers)
      assert receipt.tx_hash == "0xcafebabe"
      assert receipt.amount == "100"
      assert receipt.method == "tempo"
      assert receipt.success == true
    end

    test "returns error for missing header" do
      assert {:error, :no_receipt} = MPP.parse_receipt([])
    end
  end

  # Build a `www-authenticate: Payment <base64>` header from a base challenge
  # merged with `overrides`, so a test can vary a single field (e.g. amount).
  defp challenge_headers(overrides) do
    payload =
      %{
        "amount" => 100,
        "currency" => "USDC",
        "recipient" => "0xabcdef1234567890abcdef1234567890abcdef12",
        "network" => "tempo:mainnet",
        "nonce" => "abc123"
      }
      |> Map.merge(overrides)
      |> Jason.encode!()

    [{"www-authenticate", "Payment " <> Base.encode64(payload)}]
  end
end
