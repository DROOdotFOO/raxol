defmodule Raxol.Payments.Directive.Pay do
  @moduledoc """
  Semantic payment directive.

  Carries the spend metadata an agent runtime hook (`SpendingHook`) needs
  to authorize before the side effect runs: `amount` and `domain`. The
  side effect itself is a zero-arity `perform` closure that returns
  `{:ok, result}` or `{:error, reason}`.

  ## Result messages

  Results land at the agent's `update/2` as:

    * `{:command_result, {:pay_result, result}}` on `{:ok, result}`
    * `{:command_result, {:pay_error, reason}}` on `{:error, reason}`
    * `{:command_result, {:pay_error, {:exception, message}}}` on raise

  ## Example

      Raxol.Payments.Directive.Pay.new(
        amount: Decimal.new("0.05"),
        domain: "api.openai.com",
        agent_id: :research_bot,
        perform: fn ->
          Req.post("https://api.openai.com/...")
        end
      )
  """

  @type perform :: (-> {:ok, term()} | {:error, term()})

  @type t :: %__MODULE__{
          amount: Decimal.t(),
          domain: String.t(),
          agent_id: term() | nil,
          meta: map(),
          perform: perform()
        }

  @enforce_keys [:amount, :domain, :perform]
  defstruct [:amount, :domain, :agent_id, perform: nil, meta: %{}]

  @doc """
  Construct a Pay directive.

  Required: `:amount`, `:domain`, `:perform`. Optional: `:agent_id`, `:meta`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      amount: Keyword.fetch!(opts, :amount),
      domain: Keyword.fetch!(opts, :domain),
      perform: Keyword.fetch!(opts, :perform),
      agent_id: Keyword.get(opts, :agent_id),
      meta: Keyword.get(opts, :meta, %{})
    }
  end
end

defimpl Raxol.Agent.Directive.Executor, for: Raxol.Payments.Directive.Pay do
  alias Raxol.Payments.Directive.Pay

  def execute(%Pay{perform: perform}, context) do
    pid = context.pid

    Task.start(fn ->
      try do
        case perform.() do
          {:ok, result} -> send(pid, {:command_result, {:pay_result, result}})
          {:error, reason} -> send(pid, {:command_result, {:pay_error, reason}})
          other -> send(pid, {:command_result, {:pay_result, other}})
        end
      rescue
        e ->
          send(
            pid,
            {:command_result, {:pay_error, {:exception, Exception.message(e)}}}
          )
      end
    end)
  end
end
