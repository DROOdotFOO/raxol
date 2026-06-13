defmodule Raxol.ACP.JobApi do
  @moduledoc """
  Behaviour for the ACP REST discovery API.

  Mirrors `AcpJobApi` in `acp-node-v2`. Talks to
  `https://api.acp.virtuals.io` (mainnet) and
  `https://api-dev.acp.virtuals.io` (testnet) for agent registry,
  active-job listing, and out-of-band deliverable posting.

  The on-chain side lives behind `Raxol.ACP.ProviderAdapter` (PR D);
  JobApi is purely off-chain HTTP.
  """

  @type t :: %{
          required(:adapter) => module(),
          optional(:config) => map()
        }

  @type agent_detail :: %{
          required(:wallet_address) => String.t(),
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:cluster) => String.t(),
          optional(:offerings) => [map()],
          optional(:is_online) => boolean(),
          optional(:successful_job_count) => non_neg_integer(),
          optional(:success_rate) => float()
        }

  @type browse_params :: %{
          optional(:sort_by) =>
            :successful_job_count
            | :success_rate
            | :unique_buyer_count
            | :mins_from_last_online,
          optional(:top_k) => pos_integer(),
          optional(:is_online) => :all | :online | :offline,
          optional(:cluster) => String.t(),
          optional(:show_hidden) => boolean()
        }

  @callback browse_agents(t(), keyword :: String.t(), params :: browse_params()) ::
              {:ok, [agent_detail()]} | {:error, term()}

  @callback get_agent_by_wallet_address(t(), wallet_address :: String.t()) ::
              {:ok, agent_detail() | nil} | {:error, term()}

  @callback get_me(t()) :: {:ok, agent_detail()} | {:error, term()}

  @callback get_active_jobs(t()) :: {:ok, [map()]} | {:error, term()}

  @callback post_deliverable(
              t(),
              chain_id :: pos_integer(),
              job_id :: String.t() | non_neg_integer(),
              deliverable :: term()
            ) :: :ok | {:error, term()}

  # -- Dispatch --

  @spec browse_agents(t(), String.t(), browse_params()) ::
          {:ok, [agent_detail()]} | {:error, term()}
  def browse_agents(api, keyword, params \\ %{}) do
    api.adapter.browse_agents(api, keyword, params)
  end

  @spec get_agent_by_wallet_address(t(), String.t()) ::
          {:ok, agent_detail() | nil} | {:error, term()}
  def get_agent_by_wallet_address(api, wallet_address) do
    api.adapter.get_agent_by_wallet_address(api, wallet_address)
  end

  @spec get_me(t()) :: {:ok, agent_detail()} | {:error, term()}
  def get_me(api), do: api.adapter.get_me(api)

  @spec get_active_jobs(t()) :: {:ok, [map()]} | {:error, term()}
  def get_active_jobs(api), do: api.adapter.get_active_jobs(api)

  @spec post_deliverable(t(), pos_integer(), String.t() | non_neg_integer(), term()) ::
          :ok | {:error, term()}
  def post_deliverable(api, chain_id, job_id, deliverable) do
    api.adapter.post_deliverable(api, chain_id, job_id, deliverable)
  end
end
