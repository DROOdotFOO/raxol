defmodule Raxol.Payments.Actions.SpendGateTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.{Ledger, SpendingPolicy}

  defp start_ledger do
    ledger = start_supervised!({Ledger, [name: nil]})
    ledger
  end

  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("1.00"),
      session_max: Decimal.new("5.00"),
      lifetime_max: Decimal.new("10.00"),
      session_window_ms: 3_600_000,
      approved_domains: ["xochi.example.com"]
    }
  end

  defp context(extra) do
    Map.merge(%{agent_id: "agent_1"}, extra)
  end

  describe "authorize/3 with no policy" do
    test "allows when policy is absent" do
      assert :ok = SpendGate.authorize(context(%{}), Decimal.new("9999"))
    end
  end

  describe "authorize/3 domain target" do
    test "approves and records when domain approved and under limits" do
      ledger = start_ledger()
      ctx = context(%{policy: policy(), ledger: ledger})

      assert :ok =
               SpendGate.authorize(ctx, Decimal.new("0.50"),
                 target: {:domain, "xochi.example.com"}
               )

      totals = Ledger.get_totals(ledger, "agent_1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0.50"))
    end

    test "denies and does NOT record when domain not approved" do
      ledger = start_ledger()
      ctx = context(%{policy: policy(), ledger: ledger})

      assert {:error, {:deny, {:domain_not_approved, "evil.example.com"}}} =
               SpendGate.authorize(ctx, Decimal.new("0.10"),
                 target: {:domain, "evil.example.com"}
               )

      totals = Ledger.get_totals(ledger, "agent_1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "denies over per_request and does NOT record" do
      ledger = start_ledger()
      ctx = context(%{policy: policy(), ledger: ledger})

      assert {:error, {:over_budget, :per_request}} =
               SpendGate.authorize(ctx, Decimal.new("2.00"),
                 target: {:domain, "xochi.example.com"}
               )

      totals = Ledger.get_totals(ledger, "agent_1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end
  end

  describe "authorize/3 address target" do
    test "skips domain approval but applies confirmation threshold" do
      ledger = start_ledger()

      pol = %{policy() | require_confirmation_above: Decimal.new("0.10")}

      ctx = context(%{policy: pol, ledger: ledger})

      # over threshold, no on_confirm -> denied
      assert {:error, {:requires_confirmation, _}} =
               SpendGate.authorize(ctx, Decimal.new("0.50"), target: {:address, "0xabc"})

      # under threshold -> allowed even with no approved domain match
      assert :ok =
               SpendGate.authorize(ctx, Decimal.new("0.05"), target: {:address, "0xabc"})
    end

    test "address target with on_confirm approve proceeds" do
      ledger = start_ledger()
      pol = %{policy() | require_confirmation_above: Decimal.new("0.10")}

      ctx =
        context(%{
          policy: pol,
          ledger: ledger,
          on_confirm: fn _amount, _target -> :approve end
        })

      assert :ok =
               SpendGate.authorize(ctx, Decimal.new("0.50"), target: {:address, "0xabc"})
    end
  end

  describe "release/2" do
    test "release nets out a prior authorize on totals" do
      ledger = start_ledger()
      ctx = context(%{policy: policy(), ledger: ledger})

      :ok =
        SpendGate.authorize(ctx, Decimal.new("0.75"), target: {:domain, "xochi.example.com"})

      :ok = SpendGate.release(ctx, Decimal.new("0.75"))

      totals = Ledger.get_totals(ledger, "agent_1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end
  end
end
