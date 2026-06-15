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

  describe "post_execute/3 with Pay directive" do
    test "records payment using agent_id field", %{ledger: ledger} do
      pay =
        Pay.new(
          amount: Decimal.new("0.02"),
          domain: "api.test.com",
          agent_id: :pay_test,
          perform: fn -> {:ok, :ignored} end
        )

      assert {:ok, :result} = SpendingHook.post_execute(pay, :result, %{})

      :timer.sleep(10)
      entries = Ledger.get_history(ledger, :pay_test)
      assert length(entries) == 1
    end

    test "passes through without Pay", %{ledger: ledger} do
      assert {:ok, :result} = SpendingHook.post_execute(:something_else, :result, %{})
      assert Ledger.get_history(ledger, :test) == []
    end
  end
end
