defmodule Raxol.Symphony.TestSupport.AllowSandbox do
  @moduledoc """
  Test sandbox that returns `:ok` for every action. Used to verify
  the chain composes without changing outcomes.
  """
  defstruct []
end

defimpl Raxol.Agent.Sandbox, for: Raxol.Symphony.TestSupport.AllowSandbox do
  def authorize(_sandbox, _action, _payload, _ctx), do: :ok
end

defmodule Raxol.Symphony.TestSupport.DenyTurnSandbox do
  @moduledoc """
  Test sandbox that denies the Symphony `:turn` action with a
  caller-supplied reason. Used to verify Sandbox.Chain.authorize/4
  short-circuiting + telemetry.
  """
  defstruct [:reason]
end

defimpl Raxol.Agent.Sandbox, for: Raxol.Symphony.TestSupport.DenyTurnSandbox do
  def authorize(%{reason: reason}, :turn, _payload, _ctx) do
    {:deny, reason || :test_deny}
  end

  def authorize(_sandbox, _action, _payload, _ctx), do: :ok
end

defmodule Raxol.Symphony.TestSupport.AbstainSandbox do
  @moduledoc """
  Test sandbox that abstains (`:ok`) for every action it sees. Mirrors
  the documented dimension semantics: dimensions not relevant to the
  passed action return `:ok` so the chain continues.
  """
  defstruct []
end

defimpl Raxol.Agent.Sandbox, for: Raxol.Symphony.TestSupport.AbstainSandbox do
  def authorize(_sandbox, _action, _payload, _ctx), do: :ok
end
