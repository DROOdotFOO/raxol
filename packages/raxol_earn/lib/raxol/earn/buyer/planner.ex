defmodule Raxol.Earn.Buyer.Planner do
  @moduledoc """
  Initiates purchases: discovery + hand-off to `Raxol.Earn.Buyer.Queue`.

  `buy/1` takes a purchase intent (a map). If it already names a `:provider`
  (seller wallet), it goes straight to `Queue.start_purchase/1`. Otherwise the
  Planner discovers one via `JobApi.browse_agents/3` (using `:keyword` or the
  `:offering` name, plus optional `:browse_params`) and picks the first match,
  then hands off. Discovery uses the same job API the Queue reads from config.

      Raxol.Earn.Buyer.Planner.buy(%{
        offering: "custom_console_agent",
        amount: Raxol.Earn.AssetToken.usdc(10, 84_532),
        expired_at: expiry_ts
      })

  This is deliberately thin -- the crash-safe origination, spend gating, and
  on-chain writes all live in `Raxol.Earn.JobSession.Client`, driven by the Queue.
  """

  alias Raxol.Earn.Buyer.Queue
  alias Raxol.Earn.JobApi

  @doc """
  Discover a provider if needed and start the purchase. Returns
  `{:ok, job_id}` | `{:rejected, reason}` | `{:error, reason}`.
  """
  @spec buy(map()) :: {:ok, non_neg_integer()} | {:rejected, term()} | {:error, term()}
  def buy(intent) when is_map(intent) do
    case ensure_provider(intent) do
      {:ok, intent} -> Queue.start_purchase(intent)
      {:error, _reason} = err -> err
    end
  end

  @doc "Browse the registry for agents matching this intent's keyword/offering."
  @spec discover(JobApi.t(), map()) :: {:ok, [JobApi.agent_detail()]} | {:error, term()}
  def discover(api, intent) when is_map(intent) do
    keyword = Map.get(intent, :keyword) || Map.get(intent, :offering) || ""
    params = Map.get(intent, :browse_params, %{})
    JobApi.browse_agents(api, keyword, params)
  end

  # -- Internals --

  defp ensure_provider(%{provider: provider} = intent) when is_binary(provider), do: {:ok, intent}

  defp ensure_provider(intent) do
    with {:ok, api} <- job_api(),
         {:ok, agents} <- discover(api, intent),
         {:ok, provider} <- pick_provider(agents) do
      {:ok, Map.put(intent, :provider, provider)}
    end
  end

  defp job_api do
    case Queue.defaults().api do
      nil -> {:error, :no_job_api}
      api -> {:ok, api}
    end
  end

  defp pick_provider([agent | _]) do
    case Map.get(agent, :wallet_address) do
      addr when is_binary(addr) -> {:ok, addr}
      _ -> {:error, :provider_missing_wallet}
    end
  end

  defp pick_provider([]), do: {:error, :no_provider_found}
end
