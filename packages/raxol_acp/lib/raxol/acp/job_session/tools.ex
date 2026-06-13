defmodule Raxol.ACP.JobSession.Tools do
  @moduledoc """
  Role + status -> allowed actions for v2 LLM-driven JobSessions.

  Mirrors the tool-availability matrix documented in the acp-node-v2
  README ("Tool Availability by Role & Status"). The list returned by
  `available/2` is the set of action atoms an agent (or LLM tool-calling
  loop) may legitimately invoke at that point.

  | Role      | Status     | Tools                          |
  |-----------|------------|---------------------------------|
  | provider  | open       | set_budget, send_message, wait |
  | provider  | budget_set | set_budget                     |
  | provider  | funded     | submit                         |
  | client    | open       | send_message, wait             |
  | client    | budget_set | send_message, fund, wait       |
  | evaluator | submitted  | complete, reject               |

  Any combination not listed yields `[]`. `:send_message` is always
  available to the provider and client in pre-submission statuses, and
  to all roles before a terminal status -- the table above is the
  *minimum* gated set; raxol may surface `:send_message` more liberally
  via `extra_tools/2`.
  """

  alias Raxol.ACP.JobSession.Status

  @type role :: :client | :provider | :evaluator
  @type tool :: :set_budget | :fund | :submit | :complete | :reject | :send_message | :wait

  @doc """
  Tools available to `role` at `status`. Returns an empty list when
  no actions are legal (e.g. an evaluator before submission, or any
  role in a terminal status).
  """
  @spec available(role(), Status.t()) :: [tool()]
  def available(:provider, :open), do: [:set_budget, :send_message, :wait]
  def available(:provider, :budget_set), do: [:set_budget]
  def available(:provider, :funded), do: [:submit]
  def available(:client, :open), do: [:send_message, :wait]
  def available(:client, :budget_set), do: [:send_message, :fund, :wait]
  def available(:evaluator, :submitted), do: [:complete, :reject]
  def available(_role, _status), do: []

  @doc """
  Check whether the role may invoke this action at this status.

      iex> Raxol.ACP.JobSession.Tools.allowed?(:provider, :funded, :submit)
      true

      iex> Raxol.ACP.JobSession.Tools.allowed?(:client, :submitted, :complete)
      false
  """
  @spec allowed?(role(), Status.t(), tool()) :: boolean()
  def allowed?(role, status, tool) do
    tool in available(role, status)
  end
end
