defmodule Raxol.Payments.Actions.Payments do
  @moduledoc """
  Payment actions for AI agents.

  Exposes LLM-callable tools for explicit payment operations. These
  complement the transparent auto-pay Req plugin -- auto-pay handles
  402 flows silently, while these Actions let agents deliberately
  inspect balances, get quotes, transfer funds, and run cross-chain
  stealth intents through Xochi.

  ## Usage with ToolConverter

      tools = ToolConverter.to_tool_definitions(Raxol.Payments.Actions.Payments.actions())

      context = %{
        wallet: Raxol.Payments.Wallets.Env,
        ledger: ledger_pid,
        policy: SpendingPolicy.dev(),
        agent_id: :my_agent
      }
      {:ok, result} = ToolConverter.dispatch_tool_call(tool_call, actions(), context)
  """

  @actions [
    Raxol.Payments.Actions.Payments.GetBalance,
    Raxol.Payments.Actions.Payments.GetQuote,
    Raxol.Payments.Actions.Payments.Transfer,
    Raxol.Payments.Actions.Payments.SpendingStatus,
    Raxol.Payments.Actions.Payments.ListHistory,
    Raxol.Payments.Actions.Payments.CreateMandate,
    Raxol.Payments.Actions.Payments.ListMandates,
    Raxol.Payments.Actions.Payments.RevokeMandate,
    Raxol.Payments.Actions.Payments.ExecuteXochiIntent,
    Raxol.Payments.Actions.Payments.PollXochiStatus
  ]

  @doc "Returns all payment action modules."
  @spec actions() :: [module()]
  def actions, do: @actions
end
