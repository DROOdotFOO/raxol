defmodule Raxol.Payments.SpendingHookTest do
  use ExUnit.Case, async: false

  alias Raxol.Payments.{SpendingHook, SpendingPolicy, Ledger}
  alias Raxol.Core.Runtime.Command

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

  describe "pre_execute/2" do
    test "allows non-payment commands" do
      command = %Command{type: :none, data: nil}

      assert {:ok, ^command} =
               SpendingHook.pre_execute(command, %{agent_id: :test})
    end

    test "allows async commands without payment data" do
      command = %Command{type: :async, data: fn _ -> :ok end}

      assert {:ok, ^command} =
               SpendingHook.pre_execute(command, %{agent_id: :test})
    end

    test "denies commands with unapproved domain" do
      config = SpendingHook.get_config()
      policy = %{config.policy | approved_domains: ["allowed.com"]}
      SpendingHook.set_config(%{config | policy: policy})

      command = %Command{
        type: :async,
        data: %{__payment__: %{amount: Decimal.new("0.01"), domain: "evil.com"}}
      }

      assert {:deny, {:domain_not_approved, "evil.com"}} =
               SpendingHook.pre_execute(command, %{agent_id: :test})
    end

    test "denies commands over per-request budget" do
      command = %Command{
        type: :async,
        data: %{
          __payment__: %{amount: Decimal.new("999.00"), domain: "api.test.com"}
        }
      }

      assert {:deny, {:over_budget, :per_request, _}} =
               SpendingHook.pre_execute(command, %{agent_id: :test})
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

      command = %Command{
        type: :async,
        data: %{
          __payment__: %{amount: Decimal.new("10.00"), domain: "api.test.com"}
        }
      }

      assert {:deny, {:requires_confirmation, _amount, "api.test.com"}} =
               SpendingHook.pre_execute(command, %{agent_id: :test})
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

      command = %Command{
        type: :async,
        data: %{
          __payment__: %{amount: Decimal.new("10.00"), domain: "api.test.com"}
        }
      }

      assert {:ok, ^command} =
               SpendingHook.pre_execute(command, %{agent_id: :test})
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

      command = %Command{
        type: :async,
        data: %{
          __payment__: %{amount: Decimal.new("10.00"), domain: "api.test.com"}
        }
      }

      assert {:deny, {:requires_confirmation, _, _}} =
               SpendingHook.pre_execute(command, %{agent_id: :test})
    end
  end

  describe "post_execute/3" do
    test "records payment from data", %{ledger: ledger} do
      command = %Command{
        type: :async,
        data: %{
          __payment__: %{
            amount: Decimal.new("0.01"),
            domain: "api.test.com",
            agent_id: :test
          }
        }
      }

      assert {:ok, :result} =
               SpendingHook.post_execute(command, :result, %{agent_id: :test})

      :timer.sleep(10)

      entries = Ledger.get_history(ledger, :test)
      assert length(entries) == 1
    end

    test "passes through without payment data" do
      command = %Command{type: :none, data: nil}
      assert {:ok, :result} = SpendingHook.post_execute(command, :result, %{})
    end
  end

  alias Raxol.Payments.Directive.Pay

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
  end
end
