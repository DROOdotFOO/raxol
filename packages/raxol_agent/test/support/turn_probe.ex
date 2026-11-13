defmodule Raxol.Agent.Test.TurnProbe do
  @moduledoc """
  An agent whose turns end the ways `Raxol.Agent.ClientProtocol.Turn` and
  `Raxol.Agent.ClientProtocol.Permission` have to report. A test puts it on
  `config :raxol_agent, :mcp_spawnable_apps` for its own duration
  (`Raxol.Agent.Test.AcpPipe.spawnable/1`). The prompt text picks the turn:

    * `error-atom`, `error-text`, `no-usage`, `long-error` - answered inline
      with `{:error, :boom}`, `{:error, "x"}`, `{:ok, "x"}` and
      `{:error, text}` where `text` is 3,000 characters
    * `pay` - calls the sensitive `pay` action with `%{"amount" => 5}` in a
      turn process. Denied, the turn answers with the denial. Allowed, the
      turn sends the payment to the agent and then waits to be cancelled.

  A plain `Raxol.Agent.Comm.call/3` with `"paid"` is answered with the total
  paid once a payment has been applied, so a test waits on it.
  """

  use Raxol.Agent

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.Comm

  defmodule Pay do
    @moduledoc "Pay `amount` (returns the payment for the agent to apply)."
    use Raxol.Agent.Action, name: "pay", description: "Pay an amount", sensitive: true

    @impl true
    def run(params, _context), do: {:ok, %{paid: Map.fetch!(params, :amount)}}
  end

  @usage %{input_tokens: 0, output_tokens: 0}

  @replies %{
    "error-atom" => {:error, :boom},
    "error-text" => {:error, "x"},
    "no-usage" => {:ok, "x"},
    "long-error" => {:error, String.duplicate("x", 3_000)}
  }

  def init(_context), do: %{paid: 0, waiting: []}

  def available_actions, do: [Pay]

  def update(
        {:agent_message, _from, {:call, session, ref, {:acp_prompt, text, approver}}},
        model
      ),
      do: prompt(String.trim(text), session, ref, approver, model)

  def update({:agent_message, _from, {:call, caller, ref, "paid"}}, %{paid: 0} = model),
    do: {%{model | waiting: [{caller, ref} | model.waiting]}, []}

  def update({:agent_message, _from, {:call, caller, ref, "paid"}}, model) do
    Comm.reply(caller, ref, model.paid)
    {model, []}
  end

  def update({:command_result, {:paid, amount}}, model) do
    paid = model.paid + amount
    Enum.each(model.waiting, fn {caller, ref} -> Comm.reply(caller, ref, paid) end)
    {%{model | paid: paid, waiting: []}, []}
  end

  def update(_message, model), do: {model, []}

  defp prompt("pay", session, ref, approver, model) do
    agent = self()
    Comm.run_turn(session, ref, fn -> pay(agent, approver) end)
    {model, []}
  end

  defp prompt(text, session, ref, _approver, model) do
    Comm.reply(session, ref, Map.get(@replies, text, {:ok, "unknown", @usage}))
    {model, []}
  end

  # Runs in the turn process. Once the payment is sent the turn has nothing
  # more to say: only a cancel ends it.
  defp pay(agent, approver) do
    call = %{"name" => "pay", "arguments" => %{"amount" => 5}}

    case ToolConverter.dispatch_tool_call(call, [Pay], %{tool_authorizer: approver}) do
      {:ok, payment} ->
        send(agent, {:command_result, {:paid, payment.paid}})
        receive(do: (:never -> :ok))

      {:error, reason} ->
        {:ok, ToolConverter.public_error("pay", reason), @usage}
    end
  end
end
