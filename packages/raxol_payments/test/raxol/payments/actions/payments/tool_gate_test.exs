defmodule Raxol.Payments.Actions.Payments.ToolGateTest do
  @moduledoc """
  The LLM tool-call gate must deny fund-moving payment Actions by default so a
  prompt-injected model can't drive a payment just by emitting a tool call. The
  gate sits on `ToolConverter.dispatch_tool_call/3`; programmatic `.run/2` calls
  are unaffected.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.ToolPolicy
  alias Raxol.Payments.Actions.Payments

  alias Raxol.Payments.Actions.Payments.{
    CreateMandate,
    ExecuteRelayTransfer,
    ExecuteXochiIntent,
    GetQuote,
    GetWalletInfo,
    ListHistory,
    ListMandates,
    PollXochiStatus,
    RevokeMandate,
    SpendingStatus,
    Transfer
  }

  describe "sensitivity flags" do
    test "fund-moving / delegation Actions are marked sensitive" do
      for mod <- [ExecuteXochiIntent, ExecuteRelayTransfer, Transfer, CreateMandate] do
        assert mod.__action_meta__().sensitive == true,
               "#{inspect(mod)} must be sensitive"
      end
    end

    test "read-only Actions are not sensitive" do
      for mod <- [
            GetWalletInfo,
            GetQuote,
            SpendingStatus,
            ListHistory,
            ListMandates,
            RevokeMandate,
            PollXochiStatus
          ] do
        refute mod.__action_meta__().sensitive,
               "#{inspect(mod)} should not be sensitive"
      end
    end
  end

  describe "default LLM dispatch gate" do
    test "a sensitive payment tool is denied with no authorizer" do
      tool_call = %{
        "name" => "payment_execute_xochi_intent",
        "arguments" => %{"to" => "0xabc"}
      }

      assert {:error, {:tool_denied, "payment_execute_xochi_intent", :sensitive_tool}} =
               ToolConverter.dispatch_tool_call(tool_call, Payments.actions(), %{})
    end

    test "a read-only payment tool is not blocked by the gate" do
      tool_call = %{"name" => "payment_spending_status", "arguments" => %{}}

      result = ToolConverter.dispatch_tool_call(tool_call, Payments.actions(), %{})

      refute match?({:error, {:tool_denied, _, _}}, result)
    end

    test "an explicit allow_all lets a sensitive payment tool past the gate" do
      tool_call = %{
        "name" => "payment_execute_xochi_intent",
        "arguments" => %{"to" => "0xabc"}
      }

      result =
        ToolConverter.dispatch_tool_call(
          tool_call,
          Payments.actions(),
          %{tool_authorizer: ToolPolicy.allow_all()}
        )

      # past the gate -> the action runs and fails for its own reasons
      # (missing params/wallet), but it is not a gate denial
      refute match?({:error, {:tool_denied, _, _}}, result)
    end
  end
end
