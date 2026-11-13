defmodule Raxol.Agent.Test.DenyAction do
  @moduledoc """
  A sandbox that denies one action atom when `deny?` accepts the payload and
  abstains on every other action.
  """

  @enforce_keys [:action]
  defstruct [:action, deny?: &__MODULE__.always/1]

  @doc "The default `deny?`: every payload."
  def always(_payload), do: true
end

defimpl Raxol.Agent.Sandbox, for: Raxol.Agent.Test.DenyAction do
  def authorize(%{action: action, deny?: deny?}, action, payload, _ctx) do
    if deny?.(payload), do: {:deny, {:denied, action}}, else: :ok
  end

  def authorize(_sandbox, _action, _payload, _ctx), do: :ok
end
