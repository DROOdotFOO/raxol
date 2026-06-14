defmodule Raxol.Payments.Directive.PayTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Directive.Executor
  alias Raxol.Payments.Directive.Pay

  describe "new/1" do
    test "builds a Pay with required fields" do
      pay =
        Pay.new(
          amount: Decimal.new("0.01"),
          domain: "api.test.com",
          perform: fn -> {:ok, :done} end
        )

      assert %Pay{
               amount: %Decimal{},
               domain: "api.test.com",
               agent_id: nil,
               meta: %{},
               perform: perform
             } = pay

      assert is_function(perform, 0)
    end

    test "carries optional fields" do
      pay =
        Pay.new(
          amount: Decimal.new("1.00"),
          domain: "api.test.com",
          agent_id: :research,
          meta: %{tag: "experiment"},
          perform: fn -> {:ok, :done} end
        )

      assert pay.agent_id == :research
      assert pay.meta == %{tag: "experiment"}
    end

    test "raises without required fields" do
      assert_raise KeyError, fn ->
        Pay.new(domain: "x", perform: fn -> {:ok, :done} end)
      end
    end
  end

  describe "Executor for Pay" do
    test "successful perform sends pay_result" do
      pay =
        Pay.new(
          amount: Decimal.new("0.01"),
          domain: "x.com",
          perform: fn -> {:ok, %{ok: true}} end
        )

      Executor.execute(pay, %{pid: self(), runtime_pid: self()})

      assert_receive {:command_result, {:pay_result, %{ok: true}}}, 1_000
    end

    test "error perform sends pay_error" do
      pay =
        Pay.new(
          amount: Decimal.new("0.01"),
          domain: "x.com",
          perform: fn -> {:error, :insufficient_funds} end
        )

      Executor.execute(pay, %{pid: self(), runtime_pid: self()})

      assert_receive {:command_result, {:pay_error, :insufficient_funds}}, 1_000
    end

    test "raised exception sends pay_error with exception tag" do
      pay =
        Pay.new(
          amount: Decimal.new("0.01"),
          domain: "x.com",
          perform: fn -> raise "wallet locked" end
        )

      Executor.execute(pay, %{pid: self(), runtime_pid: self()})

      assert_receive {:command_result, {:pay_error, {:exception, "wallet locked"}}},
                     1_000
    end

    test "non-tuple return is treated as pay_result" do
      pay =
        Pay.new(
          amount: Decimal.new("0.01"),
          domain: "x.com",
          perform: fn -> :raw_value end
        )

      Executor.execute(pay, %{pid: self(), runtime_pid: self()})

      assert_receive {:command_result, {:pay_result, :raw_value}}, 1_000
    end
  end
end
