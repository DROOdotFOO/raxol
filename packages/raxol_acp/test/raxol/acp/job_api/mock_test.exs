defmodule Raxol.ACP.JobApi.MockTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.JobApi
  alias Raxol.ACP.JobApi.Mock

  describe "get_me/1" do
    test "returns the seeded me" do
      api = Mock.new(me: %{wallet_address: "0xabc", name: "Xochi", is_online: true})

      assert {:ok, %{wallet_address: "0xabc", name: "Xochi"}} = JobApi.get_me(api)
    end
  end

  describe "browse_agents/3" do
    test "filters by case-insensitive name keyword" do
      api = Mock.new()
      Mock.put_agent(api, "0x1", %{name: "Xochi Solver"})
      Mock.put_agent(api, "0x2", %{name: "Other Agent"})

      assert {:ok, [%{name: "Xochi Solver"}]} = JobApi.browse_agents(api, "xochi", %{})
      assert {:ok, [%{name: "Other Agent"}]} = JobApi.browse_agents(api, "other", %{})
    end

    test "empty keyword returns everything" do
      api = Mock.new()
      Mock.put_agent(api, "0x1", %{name: "A"})
      Mock.put_agent(api, "0x2", %{name: "B"})

      assert {:ok, results} = JobApi.browse_agents(api, "", %{})
      assert length(results) == 2
    end

    test "no match returns []" do
      api = Mock.new()
      Mock.put_agent(api, "0x1", %{name: "A"})

      assert {:ok, []} = JobApi.browse_agents(api, "nothing", %{})
    end
  end

  describe "get_agent_by_wallet_address/2" do
    test "returns the agent" do
      api = Mock.new()
      Mock.put_agent(api, "0x1", %{name: "A"})

      assert {:ok, %{name: "A", wallet_address: "0x1"}} =
               JobApi.get_agent_by_wallet_address(api, "0x1")
    end

    test "returns nil for unknown wallet" do
      api = Mock.new()
      assert {:ok, nil} = JobApi.get_agent_by_wallet_address(api, "0xmissing")
    end
  end

  describe "active jobs" do
    test "round-trips" do
      api = Mock.new()
      Mock.put_active_jobs(api, [%{job_id: "1"}, %{job_id: "2"}])

      assert {:ok, [%{job_id: "1"}, %{job_id: "2"}]} = JobApi.get_active_jobs(api)
    end
  end

  describe "post_deliverable/4" do
    test "records every deliverable in order" do
      api = Mock.new()

      JobApi.post_deliverable(api, 8453, "1", %{result: "a"})
      JobApi.post_deliverable(api, 8453, "2", %{result: "b"})

      assert [
               {8453, "1", %{result: "a"}},
               {8453, "2", %{result: "b"}}
             ] = Mock.posted_deliverables(api)
    end
  end
end
