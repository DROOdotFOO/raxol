defmodule Raxol.Payments.PolicyGateTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.{PolicyGate, SpendingPolicy}

  describe "evaluate/4 domain gate" do
    test "allows any domain when approved_domains is nil" do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1"),
        session_max: Decimal.new("1"),
        lifetime_max: Decimal.new("1"),
        approved_domains: nil
      }

      assert :ok =
               PolicyGate.evaluate(policy, Decimal.new("0.01"), "anything.com")
    end

    test "denies unapproved domain" do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1"),
        session_max: Decimal.new("1"),
        lifetime_max: Decimal.new("1"),
        approved_domains: ["api.example.com"]
      }

      assert {:deny, {:domain_not_approved, "evil.com"}} =
               PolicyGate.evaluate(policy, Decimal.new("0.01"), "evil.com")
    end

    test "approves a subdomain of an approved domain" do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1"),
        session_max: Decimal.new("1"),
        lifetime_max: Decimal.new("1"),
        approved_domains: ["example.com"]
      }

      assert :ok =
               PolicyGate.evaluate(
                 policy,
                 Decimal.new("0.01"),
                 "api.example.com"
               )
    end
  end

  describe "evaluate/4 confirmation gate" do
    setup do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        require_confirmation_above: Decimal.new("5.00")
      }

      %{policy: policy}
    end

    test "allows when amount is at or below threshold", %{policy: policy} do
      assert :ok =
               PolicyGate.evaluate(
                 policy,
                 Decimal.new("3.00"),
                 "api.example.com"
               )

      assert :ok =
               PolicyGate.evaluate(
                 policy,
                 Decimal.new("5.00"),
                 "api.example.com"
               )
    end

    test "denies when amount exceeds threshold and no callback is given", %{
      policy: policy
    } do
      assert {:deny, {:requires_confirmation, _amount, "api.example.com"}} =
               PolicyGate.evaluate(
                 policy,
                 Decimal.new("10.00"),
                 "api.example.com"
               )
    end

    test "approves when on_confirm returns :approve", %{policy: policy} do
      assert :ok =
               PolicyGate.evaluate(
                 policy,
                 Decimal.new("10.00"),
                 "api.example.com",
                 on_confirm: fn _amount, _domain -> :approve end
               )
    end

    test "denies when on_confirm returns :deny", %{policy: policy} do
      assert {:deny, {:requires_confirmation, _amount, "api.example.com"}} =
               PolicyGate.evaluate(
                 policy,
                 Decimal.new("10.00"),
                 "api.example.com",
                 on_confirm: fn _amount, _domain -> :deny end
               )
    end

    test "denies when on_confirm returns anything else", %{policy: policy} do
      assert {:deny, {:requires_confirmation, _amount, "api.example.com"}} =
               PolicyGate.evaluate(
                 policy,
                 Decimal.new("10.00"),
                 "api.example.com",
                 on_confirm: fn _amount, _domain -> :maybe end
               )
    end

    test "receives the amount and domain it will gate", %{policy: policy} do
      parent = self()

      callback = fn amount, domain ->
        send(parent, {:saw, amount, domain})
        :approve
      end

      assert :ok =
               PolicyGate.evaluate(
                 policy,
                 Decimal.new("10.00"),
                 "api.example.com", on_confirm: callback)

      assert_received {:saw, %Decimal{} = amount, "api.example.com"}
      assert Decimal.equal?(amount, Decimal.new("10.00"))
    end
  end

  describe "evaluate/4 ordering" do
    test "domain check fires before confirmation" do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        approved_domains: ["allowed.com"],
        require_confirmation_above: Decimal.new("1.00")
      }

      assert {:deny, {:domain_not_approved, "evil.com"}} =
               PolicyGate.evaluate(policy, Decimal.new("100.00"), "evil.com",
                 on_confirm: fn _, _ -> :approve end
               )
    end
  end
end
