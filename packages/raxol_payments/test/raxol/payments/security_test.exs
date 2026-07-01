defmodule Raxol.Payments.SecurityTest do
  @moduledoc """
  Security-focused edge case tests for raxol_payments.

  Covers input validation in X402/MPP parse_challenge, Ledger zero/negative
  amount handling, and SpendingPolicy boundary conditions.
  """

  use ExUnit.Case, async: true

  alias Raxol.Payments.Protocols.X402
  alias Raxol.Payments.Protocols.MPP
  alias Raxol.Payments.Ledger
  alias Raxol.Payments.SpendingPolicy

  @valid_address "0x" <> String.duplicate("ab", 20)

  # -- X402 Helpers --

  defp x402_headers(payload) do
    encoded = payload |> Jason.encode!() |> Base.encode64()
    [{"payment-required", encoded}]
  end

  defp valid_x402_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "maxAmountRequired" => "1.50",
        "payTo" => @valid_address,
        "asset" => "0x" <> String.duplicate("cd", 20),
        "network" => "eip155:8453"
      },
      overrides
    )
  end

  # -- MPP Helpers --

  defp mpp_headers(payload) do
    encoded = payload |> Jason.encode!() |> Base.encode64()
    [{"www-authenticate", "Payment " <> encoded}]
  end

  defp valid_mpp_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "amount" => "1.50",
        "recipient" => @valid_address,
        "currency" => "USDC",
        "network" => "eip155:8453"
      },
      overrides
    )
  end

  # =================================================================
  # X402 parse_challenge
  # =================================================================

  describe "X402 parse_challenge rejects zero price" do
    test "integer zero" do
      headers = x402_headers(valid_x402_payload(%{"maxAmountRequired" => 0}))
      assert {:error, _} = X402.parse_challenge(headers)
    end

    test "string zero" do
      headers = x402_headers(valid_x402_payload(%{"maxAmountRequired" => "0"}))
      assert {:error, _} = X402.parse_challenge(headers)
    end
  end

  describe "X402 parse_challenge rejects negative price" do
    test "negative integer" do
      headers = x402_headers(valid_x402_payload(%{"maxAmountRequired" => -1}))
      assert {:error, _} = X402.parse_challenge(headers)
    end

    test "negative string" do
      headers = x402_headers(valid_x402_payload(%{"maxAmountRequired" => "-1"}))
      assert {:error, _} = X402.parse_challenge(headers)
    end
  end

  describe "X402 parse_challenge rejects missing price" do
    test "no maxAmountRequired or price key" do
      payload = valid_x402_payload() |> Map.delete("maxAmountRequired")
      headers = x402_headers(payload)
      assert {:error, _} = X402.parse_challenge(headers)
    end
  end

  describe "X402 parse_challenge rejects invalid address" do
    test "too short" do
      headers = x402_headers(valid_x402_payload(%{"payTo" => "0xdead"}))
      assert {:error, {:invalid_address, _}} = X402.parse_challenge(headers)
    end

    test "missing 0x prefix" do
      headers = x402_headers(valid_x402_payload(%{"payTo" => String.duplicate("ab", 20)}))
      assert {:error, {:invalid_address, _}} = X402.parse_challenge(headers)
    end

    test "non-hex characters" do
      headers = x402_headers(valid_x402_payload(%{"payTo" => "0x" <> String.duplicate("zz", 20)}))
      assert {:error, {:invalid_address, _}} = X402.parse_challenge(headers)
    end

    test "too long" do
      headers = x402_headers(valid_x402_payload(%{"payTo" => "0x" <> String.duplicate("ab", 21)}))
      assert {:error, {:invalid_address, _}} = X402.parse_challenge(headers)
    end
  end

  describe "X402 parse_challenge rejects missing pay_to" do
    test "no payTo or pay_to key" do
      payload = valid_x402_payload() |> Map.delete("payTo")
      headers = x402_headers(payload)
      assert {:error, _} = X402.parse_challenge(headers)
    end
  end

  describe "X402 parse_challenge accepts valid challenges" do
    test "string price" do
      headers = x402_headers(valid_x402_payload(%{"maxAmountRequired" => "1.50"}))
      assert {:ok, challenge} = X402.parse_challenge(headers)
      assert challenge.price == "1.50"
      assert challenge.pay_to == @valid_address
    end

    test "integer price" do
      headers = x402_headers(valid_x402_payload(%{"maxAmountRequired" => 100}))
      assert {:ok, challenge} = X402.parse_challenge(headers)
      assert challenge.price == 100
    end

    test "float price" do
      headers = x402_headers(valid_x402_payload(%{"maxAmountRequired" => 1.5}))
      assert {:ok, challenge} = X402.parse_challenge(headers)
      assert challenge.price == 1.5
    end

    test "uses price key as fallback" do
      payload =
        valid_x402_payload()
        |> Map.delete("maxAmountRequired")
        |> Map.put("price", "2.00")

      headers = x402_headers(payload)
      assert {:ok, challenge} = X402.parse_challenge(headers)
      assert challenge.price == "2.00"
    end

    test "uses pay_to key as fallback" do
      payload =
        valid_x402_payload()
        |> Map.delete("payTo")
        |> Map.put("pay_to", @valid_address)

      headers = x402_headers(payload)
      assert {:ok, _} = X402.parse_challenge(headers)
    end

    test "valid Ethereum address (mixed case)" do
      addr = "0xAaBbCcDdEeFf00112233445566778899aAbBcCdD"
      headers = x402_headers(valid_x402_payload(%{"payTo" => addr}))
      assert {:ok, challenge} = X402.parse_challenge(headers)
      assert challenge.pay_to == addr
    end
  end

  # =================================================================
  # MPP parse_challenge
  # =================================================================

  describe "MPP parse_challenge rejects zero amount" do
    test "integer zero" do
      headers = mpp_headers(valid_mpp_payload(%{"amount" => 0}))
      assert {:error, _} = MPP.parse_challenge(headers)
    end

    test "string zero" do
      headers = mpp_headers(valid_mpp_payload(%{"amount" => "0"}))
      assert {:error, _} = MPP.parse_challenge(headers)
    end
  end

  describe "MPP parse_challenge rejects negative amount" do
    test "negative integer" do
      headers = mpp_headers(valid_mpp_payload(%{"amount" => -5}))
      assert {:error, _} = MPP.parse_challenge(headers)
    end

    test "negative string" do
      headers = mpp_headers(valid_mpp_payload(%{"amount" => "-5"}))
      assert {:error, _} = MPP.parse_challenge(headers)
    end
  end

  describe "MPP parse_challenge rejects missing fields" do
    test "missing amount" do
      payload = valid_mpp_payload() |> Map.delete("amount")
      headers = mpp_headers(payload)
      assert {:error, _} = MPP.parse_challenge(headers)
    end

    test "missing recipient" do
      payload = valid_mpp_payload() |> Map.delete("recipient")
      headers = mpp_headers(payload)
      assert {:error, _} = MPP.parse_challenge(headers)
    end
  end

  describe "MPP parse_challenge accepts valid challenge" do
    test "string amount with recipient" do
      headers = mpp_headers(valid_mpp_payload())
      assert {:ok, challenge} = MPP.parse_challenge(headers)
      assert challenge.amount == "1.50"
      assert challenge.recipient == @valid_address
    end

    test "integer amount" do
      headers = mpp_headers(valid_mpp_payload(%{"amount" => 100}))
      assert {:ok, challenge} = MPP.parse_challenge(headers)
      assert challenge.amount == 100
    end

    test "uses pay_to as fallback for recipient" do
      payload =
        valid_mpp_payload()
        |> Map.delete("recipient")
        |> Map.put("pay_to", @valid_address)

      headers = mpp_headers(payload)
      assert {:ok, challenge} = MPP.parse_challenge(headers)
      assert challenge.recipient == @valid_address
    end
  end

  # =================================================================
  # Ledger zero/negative amounts
  # =================================================================

  describe "Ledger try_spend with zero amount" do
    setup do
      table_name = :"security_ledger_zero_#{:erlang.unique_integer([:positive])}"
      {:ok, ledger} = Ledger.start_link(table_name: table_name)
      policy = SpendingPolicy.dev()
      %{ledger: ledger, policy: policy}
    end

    test "zero amount is rejected and records nothing", %{ledger: ledger, policy: policy} do
      # A spend must be strictly positive: zero is not a real payment and must
      # not be admitted to the ledger.
      assert {:over_limit, :invalid_amount} =
               Ledger.try_spend(ledger, "agent_1", Decimal.new("0"), policy)

      assert Ledger.get_history(ledger, "agent_1") == []
    end
  end

  describe "Ledger try_spend with negative amount" do
    setup do
      table_name = :"security_ledger_neg_#{:erlang.unique_integer([:positive])}"
      {:ok, ledger} = Ledger.start_link(table_name: table_name)
      policy = SpendingPolicy.dev()
      %{ledger: ledger, policy: policy}
    end

    test "negative amount is rejected before any cap check", %{
      ledger: ledger,
      policy: policy
    } do
      # A negative amount slips under every cap (Decimal.compare("-1", "0.10")
      # == :lt) and, if recorded, nets the running total down to free budget
      # headroom. The ledger rejects it outright.
      assert {:over_limit, :invalid_amount} =
               Ledger.try_spend(ledger, "agent_1", Decimal.new("-1"), policy)

      assert Ledger.get_history(ledger, "agent_1") == []
    end

    test "negative spend cannot reduce the session total", %{ledger: ledger, policy: policy} do
      # Record a legitimate spend first
      Ledger.record_spend(ledger, "agent_1", Decimal.new("0.05"), %{})
      # Small delay to ensure cast completes before call
      Process.sleep(10)

      totals_before = Ledger.get_totals(ledger, "agent_1", policy)
      assert Decimal.compare(totals_before.lifetime, Decimal.new("0.05")) == :eq

      # A negative try_spend is rejected, so the total is unchanged.
      assert {:over_limit, :invalid_amount} =
               Ledger.try_spend(ledger, "agent_1", Decimal.new("-0.02"), policy)

      totals_after = Ledger.get_totals(ledger, "agent_1", policy)
      assert Decimal.compare(totals_after.lifetime, Decimal.new("0.05")) == :eq
    end
  end

  # =================================================================
  # SpendingPolicy edge cases
  # =================================================================

  describe "SpendingPolicy.domain_approved? with empty string domain" do
    test "empty string matches nothing in approved list" do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1"),
        session_max: Decimal.new("10"),
        lifetime_max: Decimal.new("100"),
        approved_domains: ["api.example.com"]
      }

      # "" ends_with? "api.example.com" is false
      refute SpendingPolicy.domain_approved?(policy, "")
    end

    test "empty string approved entry is ignored (no longer matches everything)" do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1"),
        session_max: Decimal.new("10"),
        lifetime_max: Decimal.new("100"),
        approved_domains: [""]
      }

      # Fixed: empty string entries are skipped during matching
      refute SpendingPolicy.domain_approved?(policy, "evil.com")
    end
  end

  describe "SpendingPolicy.domain_approved? with empty list" do
    test "empty list rejects all domains" do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1"),
        session_max: Decimal.new("10"),
        lifetime_max: Decimal.new("100"),
        approved_domains: []
      }

      refute SpendingPolicy.domain_approved?(policy, "api.example.com")
      refute SpendingPolicy.domain_approved?(policy, "")
    end
  end

  describe "SpendingPolicy.requires_confirmation? with zero amount" do
    test "zero does not exceed threshold" do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1"),
        session_max: Decimal.new("10"),
        lifetime_max: Decimal.new("100"),
        require_confirmation_above: Decimal.new("0.00")
      }

      # Decimal.compare("0", "0.00") == :eq, not :gt
      refute SpendingPolicy.requires_confirmation?(policy, Decimal.new("0"))
    end

    test "amount just above zero requires confirmation when threshold is zero" do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1"),
        session_max: Decimal.new("10"),
        lifetime_max: Decimal.new("100"),
        require_confirmation_above: Decimal.new("0")
      }

      assert SpendingPolicy.requires_confirmation?(policy, Decimal.new("0.01"))
    end
  end
end
