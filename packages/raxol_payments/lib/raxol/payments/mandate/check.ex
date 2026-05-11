defmodule Raxol.Payments.Mandate.Check do
  @moduledoc """
  Select the best Mandate envelope from the Store for a given scope
  and agent wallet.

  Pure module. No state. Reads from `Raxol.Payments.Mandate.Store`.

  ## Selection strategy

  Among the mandates an agent can present for a given scope, returns
  the one with the soonest `expires_at`. This drains short-lived
  envelopes first, leaving longer-lived ones available for later
  calls -- the same heuristic Permit2 callers use for nonce ordering.

  Expired mandates are filtered out. Unsigned mandates can't be in
  the Store in the first place (the Store rejects them in `put/2`).
  """

  alias Raxol.Payments.Mandate
  alias Raxol.Payments.Mandate.Store

  @doc """
  Find the soonest-expiring active Mandate that covers `scope` and
  is addressed to `agent_wallet`.

  Reads from the singleton `Raxol.Payments.Mandate.Store`. The Store
  is a singleton (named ETS tables), so there is no `store` argument
  to swap targets -- start exactly one Store per node.
  """
  @spec select_for_scope(Mandate.scope(), String.t()) ::
          {:ok, Mandate.t()} | {:error, :no_mandate}
  def select_for_scope(scope, agent_wallet)
      when is_binary(scope) and is_binary(agent_wallet) do
    now = System.system_time(:second)

    agent_wallet
    |> Store.list_for_agent()
    |> Enum.filter(fn m ->
      Mandate.covers_scope?(m, scope) and not Mandate.expired?(m, now)
    end)
    |> Enum.min_by(& &1.expires_at, fn -> nil end)
    |> case do
      nil -> {:error, :no_mandate}
      %Mandate{} = m -> {:ok, m}
    end
  end
end
