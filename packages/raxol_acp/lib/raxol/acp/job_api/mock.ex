defmodule Raxol.ACP.JobApi.Mock do
  @moduledoc """
  In-process mock for `Raxol.ACP.JobApi`. Tests pre-seed agents,
  active jobs, and a `getMe` response; this module returns them
  without touching the network.

  ## Usage

      api = Raxol.ACP.JobApi.Mock.new(me: %{wallet_address: "0x...", name: "Xochi"})
      Raxol.ACP.JobApi.Mock.put_agent(api, "0xabc...", %{name: "Other"})
      Raxol.ACP.JobApi.Mock.put_active_jobs(api, [%{job_id: "1", chain_id: 8453}])
      {:ok, [agent]} = Raxol.ACP.JobApi.browse_agents(api, "Other", %{})

  ## Inspecting outgoing traffic

  `posted_deliverables(api)` returns every deliverable ever posted as
  `{chain_id, job_id, deliverable}` tuples.
  """

  @behaviour Raxol.ACP.JobApi

  @doc "Construct a fresh mock JobApi."
  @spec new(keyword()) :: Raxol.ACP.JobApi.t()
  def new(opts \\ []) do
    table = :ets.new(:raxol_acp_jobapi_mock, [:set, :public])

    me = Keyword.get(opts, :me, %{wallet_address: "0x" <> String.duplicate("ab", 20), name: "raxol-agent"})

    :ets.insert(table, {:me, me})
    :ets.insert(table, {:agents, %{}})
    :ets.insert(table, {:active_jobs, []})
    :ets.insert(table, {:posted_deliverables, []})

    %{adapter: __MODULE__, config: %{table: table}}
  end

  @doc "Register an agent so it appears in `browse_agents/3` and `get_agent_by_wallet_address/2`."
  @spec put_agent(Raxol.ACP.JobApi.t(), String.t(), Raxol.ACP.JobApi.agent_detail()) :: :ok
  def put_agent(%{config: %{table: table}}, wallet_address, detail) do
    [{:agents, current}] = :ets.lookup(table, :agents)
    detail = Map.put(detail, :wallet_address, wallet_address)
    :ets.insert(table, {:agents, Map.put(current, wallet_address, detail)})
    :ok
  end

  @doc "Set the list returned by `get_active_jobs/1`."
  @spec put_active_jobs(Raxol.ACP.JobApi.t(), [map()]) :: :ok
  def put_active_jobs(%{config: %{table: table}}, jobs) do
    :ets.insert(table, {:active_jobs, jobs})
    :ok
  end

  @doc "Return every deliverable ever posted via `post_deliverable/4`."
  @spec posted_deliverables(Raxol.ACP.JobApi.t()) :: [tuple()]
  def posted_deliverables(%{config: %{table: table}}) do
    [{:posted_deliverables, list}] = :ets.lookup(table, :posted_deliverables)
    Enum.reverse(list)
  end

  # -- Raxol.ACP.JobApi callbacks --

  @impl Raxol.ACP.JobApi
  def browse_agents(%{config: %{table: table}}, keyword, _params) do
    [{:agents, agents}] = :ets.lookup(table, :agents)

    matches =
      agents
      |> Map.values()
      |> Enum.filter(fn agent ->
        keyword == "" or
          String.contains?(String.downcase(Map.get(agent, :name, "")), String.downcase(keyword)) or
          String.contains?(
            String.downcase(Map.get(agent, :description, "") || ""),
            String.downcase(keyword)
          )
      end)

    {:ok, matches}
  end

  @impl Raxol.ACP.JobApi
  def get_agent_by_wallet_address(%{config: %{table: table}}, wallet_address) do
    [{:agents, agents}] = :ets.lookup(table, :agents)
    {:ok, Map.get(agents, wallet_address)}
  end

  @impl Raxol.ACP.JobApi
  def get_me(%{config: %{table: table}}) do
    [{:me, me}] = :ets.lookup(table, :me)
    {:ok, me}
  end

  @impl Raxol.ACP.JobApi
  def get_active_jobs(%{config: %{table: table}}) do
    [{:active_jobs, jobs}] = :ets.lookup(table, :active_jobs)
    {:ok, jobs}
  end

  @impl Raxol.ACP.JobApi
  def post_deliverable(%{config: %{table: table}}, chain_id, job_id, deliverable) do
    [{:posted_deliverables, list}] = :ets.lookup(table, :posted_deliverables)
    :ets.insert(table, {:posted_deliverables, [{chain_id, job_id, deliverable} | list]})
    :ok
  end
end
