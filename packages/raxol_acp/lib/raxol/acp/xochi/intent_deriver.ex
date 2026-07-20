defmodule Raxol.ACP.Xochi.IntentDeriver do
  @moduledoc """
  Read the authoritative Xochi intent behind a job's `signed_intent`.

  Both storefront drivers -- the generic `Raxol.ACP.JobSession.Provider` path
  (via `UsdcPublicOffering.resolve_accept/2`) and the bespoke
  `Raxol.ACP.Xochi.SolverAgent` -- must size the storefront fee on the amount the
  buyer ACTUALLY signed, not a relayed `amount_atomic` field a buyer could
  understate. This is the single seam that fetches the intent from Xochi by its
  `intent_id` and returns the corridor + authoritative `from_amount`.

  Fails closed: a missing intent id, no Xochi config, an unreachable/unknown
  intent, a non-`:quoted` state, or a non-positive amount all return an error so
  the caller rejects before any on-chain write.
  """

  alias Raxol.Payments.Protocols.Xochi

  @type resolved :: %{intent: map(), from_amount: pos_integer()}

  @doc """
  Resolve a requirement's `signed_intent` to its authoritative Xochi intent.

  Returns `{:ok, %{intent: intent, from_amount: n}}` where `from_amount` is the
  signed origin amount in token base units, or `{:reject, reason}` /
  `{:error, reason}` (reject = buyer's request is bad; error = infra/config).
  """
  @spec resolve(map() | nil, map()) :: {:ok, resolved()} | {:reject, term()} | {:error, term()}
  def resolve(xochi_config, requirement) do
    with {:ok, intent_id} <- intent_id(requirement),
         {:ok, config} <- ensure_config(xochi_config),
         {:ok, intent} <- fetch(config, intent_id),
         :ok <- ensure_quoted(intent),
         {:ok, amount} <- principal_atomic(intent) do
      {:ok, %{intent: intent, from_amount: amount}}
    end
  end

  defp intent_id(%{"signed_intent" => %{"intent_id" => id}})
       when is_binary(id) and id != "",
       do: {:ok, id}

  defp intent_id(_requirement), do: {:reject, :missing_intent_id}

  defp ensure_config(%{base_url: _} = config), do: {:ok, config}
  defp ensure_config(_), do: {:error, :no_xochi_config}

  defp fetch(config, intent_id) do
    case Xochi.get_intent(config, intent_id) do
      {:ok, intent} -> {:ok, intent}
      {:error, {:http, 404, _}} -> {:reject, {:intent_not_found, intent_id}}
      {:error, reason} -> {:error, {:xochi_unreachable, reason}}
    end
  end

  # Only a freshly quoted intent may be accepted: the buyer signed it and it is
  # not yet executing/settled/dead.
  defp ensure_quoted(%{status: :quoted}), do: :ok
  defp ensure_quoted(%{status: status}), do: {:reject, {:intent_not_quoted, status}}

  defp principal_atomic(%{from_amount: a}) when is_binary(a) do
    case Integer.parse(a) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:reject, :invalid_amount}
    end
  end

  defp principal_atomic(_intent), do: {:reject, :invalid_amount}
end
