defmodule Raxol.Earn.JobApi.HTTPTest do
  @moduledoc """
  Live tests for `Raxol.Earn.JobApi.HTTP` against the real Virtuals dev
  API. Same gating as `Raxol.Earn.AuthTest`: skipped unless
  `RAXOL_ACP_AGENT_PRIVATE_KEY` is set.
  """
  use ExUnit.Case, async: false

  alias Raxol.Earn.{Auth, JobApi}
  alias Raxol.Earn.JobApi.HTTP
  alias Raxol.Earn.ProviderAdapter.JSONRPC

  @moduletag :live_acp_dev

  # ExUnit has no runtime skip: a callback returning {:skip, _} raises and
  # invalidates the module. Decide at load time -- .exs files are re-evaluated
  # every run, so this still tracks the credential. A skipped module never runs
  # setup_all, so the key is present by the time it does.
  if System.fetch_env("RAXOL_ACP_AGENT_PRIVATE_KEY") == :error do
    @moduletag skip: "RAXOL_ACP_AGENT_PRIVATE_KEY not set -- live Virtuals dev API tests"
  end

  setup_all do
    pk = decode_pk(System.fetch_env!("RAXOL_ACP_AGENT_PRIVATE_KEY"))

    server_url =
      System.get_env("RAXOL_ACP_SERVER_URL", "https://api-dev.acp.virtuals.io")

    rpc_url = System.get_env("RAXOL_ACP_RPC_URL", "https://mainnet.base.org")

    provider = JSONRPC.new(chains: %{8453 => rpc_url}, private_key: pk)

    {:ok, auth} = Auth.start_link(provider: provider, server_url: server_url, chain_id: 8453)
    api = HTTP.new(auth: auth, server_url: server_url, chain_ids: [8453])

    {:ok, api: api, provider: provider}
  end

  describe "get_active_jobs/1" do
    test "returns a list (possibly empty) of jobs assigned to this agent", %{api: api} do
      assert {:ok, jobs} = JobApi.get_active_jobs(api)
      assert is_list(jobs)
    end
  end

  describe "browse_agents/3" do
    test "empty keyword returns a list (may be paginated)", %{api: api} do
      assert {:ok, agents} = JobApi.browse_agents(api, "", %{top_k: 5})
      assert is_list(agents)
    end

    test "keyword filter returns matching agents", %{api: api} do
      # Use a deliberately rare keyword that's unlikely to match anything.
      # The shape of the response should still be a list (possibly empty).
      assert {:ok, agents} =
               JobApi.browse_agents(api, "xochi-unlikely-match-#{:rand.uniform(1_000_000)}", %{})

      assert is_list(agents)
    end
  end

  describe "get_agent_by_wallet_address/2 + get_me/1" do
    test "get_me returns our own agent registration", %{api: api, provider: provider} do
      case JobApi.get_me(api) do
        {:ok, nil} ->
          flunk(
            "Our wallet #{Raxol.Earn.ProviderAdapter.get_address(provider)} is not registered " <>
              "on api-dev.acp.virtuals.io. Register at https://app.virtuals.io/acp/new (dev env) first."
          )

        {:ok, agent} ->
          assert agent.wallet_address
          assert is_binary(agent.name)
      end
    end

    test "unknown wallet returns nil", %{api: api} do
      random_addr = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
      assert {:ok, nil} = JobApi.get_agent_by_wallet_address(api, random_addr)
    end
  end

  defp decode_pk("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_pk(hex), do: Base.decode16!(hex, case: :mixed)
end
