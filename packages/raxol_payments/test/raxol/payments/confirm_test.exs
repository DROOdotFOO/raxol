defmodule Raxol.Payments.ConfirmTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Confirm

  describe "always/1" do
    test ":approve always returns :approve" do
      cb = Confirm.always(:approve)
      assert cb.(Decimal.new("1"), "api.example.com") == :approve
      assert cb.(Decimal.new("9999"), "anywhere.com") == :approve
    end

    test ":deny always returns :deny" do
      cb = Confirm.always(:deny)
      assert cb.(Decimal.new("0.01"), "api.example.com") == :deny
    end

    test "rejects bogus decisions at build time" do
      assert_raise FunctionClauseError, fn -> Confirm.always(:maybe) end
    end
  end

  describe "terminal/1 classification" do
    setup do
      # StringIO acts as a fake stdin so we can drive the prompt non-interactively.
      {:ok, %{}}
    end

    test "y / Y / yes => :approve" do
      assert run_terminal("y\n") == :approve
      assert run_terminal("Y\n") == :approve
      assert run_terminal("yes\n") == :approve
      assert run_terminal("YES PLEASE\n") == :approve
    end

    test "n / blank / random input => :deny" do
      assert run_terminal("n\n") == :deny
      assert run_terminal("\n") == :deny
      assert run_terminal("nope\n") == :deny
      assert run_terminal("0\n") == :deny
    end

    test "EOF (closed stdin) => :deny" do
      assert run_terminal("") == :deny
    end
  end

  defp run_terminal(input) do
    {:ok, io} = StringIO.open(input)
    cb = Confirm.terminal(device: io)
    decision = cb.(Decimal.new("10"), "api.example.com")
    StringIO.close(io)
    decision
  end
end
