defmodule Raxol.Payments.SpendingHookTest do
  use ExUnit.Case, async: false

  alias Raxol.Payments.{Ledger, SpendingHook, SpendingPolicy}
  alias Raxol.Payments.Directive.Pay

  setup do
    {:ok, ledger} =
      Ledger.start_link(table_name: :"hook_ledger_#{:erlang.unique_integer()}")

    policy = SpendingPolicy.dev()

    SpendingHook.set_config(%{
      ledger: ledger,
      policy: policy
    })

    %{ledger: ledger, policy: policy}
  end

  describe "pre_execute/2 with Pay directive" do
    test "denies Pay with unapproved domain" do
      config = SpendingHook.get_config()
      policy = %{config.policy | approved_domains: ["allowed.com"]}
      SpendingHook.set_config(%{config | policy: policy})

      pay =
        Pay.new(
          amount: Decimal.new("0.01"),
          domain: "evil.com",
          perform: fn -> {:ok, :ignored} end
        )

      assert {:deny, {:domain_not_approved, "evil.com"}} =
               SpendingHook.pre_execute(pay, %{agent_id: :test})
    end

    test "denies Pay over per-request budget" do
      pay =
        Pay.new(
          amount: Decimal.new("999.00"),
          domain: "api.test.com",
          perform: fn -> {:ok, :ignored} end
        )

      assert {:deny, {:over_budget, :per_request, _}} =
               SpendingHook.pre_execute(pay, %{agent_id: :test})
    end

    test "allows Pay within budget" do
      pay =
        Pay.new(
          amount: Decimal.new("0.01"),
          domain: "api.test.com",
          perform: fn -> {:ok, :ignored} end
        )

      assert {:ok, ^pay} = SpendingHook.pre_execute(pay, %{agent_id: :test})
    end

    test "denies above confirmation threshold when no on_confirm is set" do
      config = SpendingHook.get_config()

      policy = %{
        config.policy
        | per_request_max: Decimal.new("1000"),
          session_max: Decimal.new("1000"),
          lifetime_max: Decimal.new("1000"),
          require_confirmation_above: Decimal.new("5")
      }

      SpendingHook.set_config(%{config | policy: policy})

      pay =
        Pay.new(
          amount: Decimal.new("10.00"),
          domain: "api.test.com",
          perform: fn -> {:ok, :ignored} end
        )

      assert {:deny, {:requires_confirmation, _amount, "api.test.com"}} =
               SpendingHook.pre_execute(pay, %{agent_id: :test})
    end

    test "allows above threshold when on_confirm approves" do
      config = SpendingHook.get_config()

      policy = %{
        config.policy
        | per_request_max: Decimal.new("1000"),
          session_max: Decimal.new("1000"),
          lifetime_max: Decimal.new("1000"),
          require_confirmation_above: Decimal.new("5")
      }

      SpendingHook.set_config(
        config
        |> Map.put(:policy, policy)
        |> Map.put(:on_confirm, fn _amount, _domain -> :approve end)
      )

      pay =
        Pay.new(
          amount: Decimal.new("10.00"),
          domain: "api.test.com",
          perform: fn -> {:ok, :ignored} end
        )

      assert {:ok, ^pay} = SpendingHook.pre_execute(pay, %{agent_id: :test})
    end

    test "denies above threshold when on_confirm denies" do
      config = SpendingHook.get_config()

      policy = %{
        config.policy
        | per_request_max: Decimal.new("1000"),
          session_max: Decimal.new("1000"),
          lifetime_max: Decimal.new("1000"),
          require_confirmation_above: Decimal.new("5")
      }

      SpendingHook.set_config(
        config
        |> Map.put(:policy, policy)
        |> Map.put(:on_confirm, fn _amount, _domain -> :deny end)
      )

      pay =
        Pay.new(
          amount: Decimal.new("10.00"),
          domain: "api.test.com",
          perform: fn -> {:ok, :ignored} end
        )

      assert {:deny, {:requires_confirmation, _, _}} =
               SpendingHook.pre_execute(pay, %{agent_id: :test})
    end
  end

  describe "atomic reserve + refund" do
    test "the spend is reserved once in pre_execute, not double-counted in post", %{
      ledger: ledger
    } do
      pay =
        Pay.new(
          amount: Decimal.new("0.02"),
          domain: "api.test.com",
          agent_id: :pay_test,
          perform: fn -> {:ok, :ignored} end
        )

      assert {:ok, ^pay} = SpendingHook.pre_execute(pay, %{})
      assert {:ok, :result} = SpendingHook.post_execute(pay, :result, %{})

      entries = Ledger.get_history(ledger, :pay_test)
      assert length(entries) == 1
      assert Decimal.equal?(hd(entries).amount, Decimal.new("0.02"))
    end

    test "post_execute refunds the reservation when the command failed", %{ledger: ledger} do
      pay =
        Pay.new(
          amount: Decimal.new("0.03"),
          domain: "api.test.com",
          agent_id: :fail_test,
          perform: fn -> {:error, :boom} end
        )

      assert {:ok, ^pay} = SpendingHook.pre_execute(pay, %{})
      assert {:ok, {:error, :boom}} = SpendingHook.post_execute(pay, {:error, :boom}, %{})

      # Reserve + refund net to zero, so a failed payment does not consume budget.
      totals = Ledger.get_totals(ledger, :fail_test, SpendingPolicy.dev())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "the reservation counts against the session cap immediately (no TOCTOU window)", %{
      ledger: ledger
    } do
      # pre_execute reserves atomically via try_spend, so a second Pay sees the
      # first's spend without waiting for a post_execute record. Fill the 1.00
      # session cap (dev policy) with reservations, then the next is denied.
      for _ <- 1..10 do
        pay =
          Pay.new(
            amount: Decimal.new("0.10"),
            domain: "api.test.com",
            agent_id: :seq,
            perform: fn -> {:ok, :ignored} end
          )

        assert {:ok, ^pay} = SpendingHook.pre_execute(pay, %{})
      end

      over =
        Pay.new(
          amount: Decimal.new("0.10"),
          domain: "api.test.com",
          agent_id: :seq,
          perform: fn -> {:ok, :ignored} end
        )

      assert {:deny, {:over_budget, :session, _}} = SpendingHook.pre_execute(over, %{})

      totals = Ledger.get_totals(ledger, :seq, SpendingPolicy.dev())
      assert Decimal.equal?(totals.session, Decimal.new("1.00"))
    end

    test "passes through without Pay", %{ledger: ledger} do
      assert {:ok, :result} = SpendingHook.post_execute(:something_else, :result, %{})
      assert Ledger.get_history(ledger, :test) == []
    end
  end
end
