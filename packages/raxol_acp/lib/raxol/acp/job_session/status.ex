defmodule Raxol.ACP.JobSession.Status do
  @moduledoc """
  Status enum for a v2 ACP job session and the legal transition graph.

  Replaces the v1 phase-enum model. Statuses mirror `JobSession.status`
  in `acp-node-v2`:

      open -> budget_set -> funded -> submitted -> completed
                                                \\-> rejected
      (any) -> expired

  `:expired` can fire from any non-terminal status. `:completed`,
  `:rejected`, and `:expired` are terminal -- the JobSession process
  terminates with `:normal` after one of these.
  """

  @type t ::
          :open
          | :budget_set
          | :funded
          | :submitted
          | :completed
          | :rejected
          | :expired

  @valid_transitions %{
    open: [:budget_set, :expired],
    # Allow re-budgeting before the client funds.
    budget_set: [:budget_set, :funded, :expired],
    funded: [:submitted, :expired],
    submitted: [:completed, :rejected, :expired],
    completed: [],
    rejected: [],
    expired: []
  }

  @terminal MapSet.new([:completed, :rejected, :expired])

  @doc "Initial status of a freshly created job."
  @spec initial() :: t()
  def initial, do: :open

  @doc "List every valid status."
  @spec all() :: [t()]
  def all, do: Map.keys(@valid_transitions)

  @doc "Statuses from which no further transition is possible."
  @spec terminal?(t()) :: boolean()
  def terminal?(status), do: MapSet.member?(@terminal, status)

  @doc """
  Validate a transition from `from` to `to`.

  Returns `:ok` for legal transitions, `{:error, {:invalid_transition,
  from, to}}` otherwise.
  """
  @spec validate(t(), t()) :: :ok | {:error, {:invalid_transition, t(), t()}}
  def validate(from, to) do
    if to in Map.get(@valid_transitions, from, []) do
      :ok
    else
      {:error, {:invalid_transition, from, to}}
    end
  end

  @doc """
  Map an action atom (`:set_budget`, `:fund`, etc.) to the status the
  action transitions into. Returns `nil` for unknown actions.

      iex> Raxol.ACP.JobSession.Status.target_status(:set_budget)
      :budget_set

      iex> Raxol.ACP.JobSession.Status.target_status(:reject)
      :rejected
  """
  @spec target_status(atom()) :: t() | nil
  def target_status(:set_budget), do: :budget_set
  def target_status(:set_budget_with_fund_request), do: :budget_set
  def target_status(:set_budget_with_subscription), do: :budget_set
  def target_status(:fund), do: :funded
  def target_status(:submit), do: :submitted
  def target_status(:complete), do: :completed
  def target_status(:reject), do: :rejected
  def target_status(:expire), do: :expired
  def target_status(_), do: nil
end
