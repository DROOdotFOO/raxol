defmodule Raxol.Earn.JobIdResolverTest do
  use ExUnit.Case, async: false

  alias Raxol.Earn.JobIdResolver
  alias Raxol.Earn.JobIdResolver.{Mock, Receipt}
  alias Raxol.Earn.Onchain.LogDecoder
  alias Raxol.Earn.ProviderAdapter.Mock, as: Adapter

  @chain 84_532

  describe "Mock" do
    test "resolve returns a mapped tx and :pending for an unknown one" do
      r = Mock.new()
      :ok = Mock.put_tx(r, "0xtx", 42)

      assert {:ok, 42} = JobIdResolver.resolve(r, %{}, @chain, "0xtx")
      assert :pending = JobIdResolver.resolve(r, %{}, @chain, "0xother")
    end

    test "put_default resolves any unmapped tx" do
      r = Mock.new()
      :ok = Mock.put_default(r, 7)
      assert {:ok, 7} = JobIdResolver.resolve(r, %{}, @chain, "0xanything")
    end

    test "set_pending overrides the default" do
      r = Mock.new()
      :ok = Mock.put_default(r, 7)
      :ok = Mock.set_pending(r, "0xtx")
      assert :pending = JobIdResolver.resolve(r, %{}, @chain, "0xtx")
    end

    test "reconcile matches a request tag" do
      r = Mock.new()
      :ok = Mock.put_tag(r, "rk-abc", 99)

      assert {:ok, 99} = JobIdResolver.reconcile(r, %{}, @chain, "rk-abc")
      assert :none = JobIdResolver.reconcile(r, %{}, @chain, "rk-missing")
    end
  end

  describe "Receipt" do
    test "resolve decodes the jobId from the createJob receipt logs" do
      adapter = Adapter.new()
      topic = LogDecoder.event_topic("JobCreated(uint256)")
      log = %{"topics" => [topic, "0x" <> String.duplicate("0", 62) <> "2a"]}
      :ok = Adapter.set_receipt(adapter, "0xtx", %{"logs" => [log]})

      resolver = %{adapter: Receipt}
      assert {:ok, 42} = JobIdResolver.resolve(resolver, adapter, @chain, "0xtx")
    end

    test "resolve returns :pending when the receipt is not yet available" do
      adapter = Adapter.new()
      resolver = %{adapter: Receipt}
      assert :pending = JobIdResolver.resolve(resolver, adapter, @chain, "0xmissing")
    end

    test "resolve honors an overridden event signature and topic index" do
      adapter = Adapter.new()
      topic = LogDecoder.event_topic("JobOpened(uint256,uint256)")

      log = %{
        "topics" => [
          topic,
          "0x" <> String.duplicate("0", 63) <> "1",
          "0x" <> String.duplicate("0", 62) <> "63"
        ]
      }

      :ok = Adapter.set_receipt(adapter, "0xtx", %{"logs" => [log]})

      resolver = %{
        adapter: Receipt,
        config: %{event_signature: "JobOpened(uint256,uint256)", topic_index: 2}
      }

      assert {:ok, 99} = JobIdResolver.resolve(resolver, adapter, @chain, "0xtx")
    end

    test "reconcile correlates an active job by its description tag" do
      api = Raxol.Earn.JobApi.Mock.new()

      :ok =
        Raxol.Earn.JobApi.Mock.put_active_jobs(api, [
          %{"onChainJobId" => "17", "description" => "buy [raxol-earn:deadbeef00000000]"}
        ])

      resolver = %{adapter: Receipt}

      assert {:ok, 17} =
               JobIdResolver.reconcile(resolver, api, @chain, "raxol-earn:deadbeef00000000")

      assert :none = JobIdResolver.reconcile(resolver, api, @chain, "raxol-earn:nomatch")
    end

    test "reconcile correlates a legacy raxol-acp:-tagged job against the new tag" do
      api = Raxol.Earn.JobApi.Mock.new()

      :ok =
        Raxol.Earn.JobApi.Mock.put_active_jobs(api, [
          %{"onChainJobId" => "17", "description" => "buy [raxol-acp:deadbeef00000000]"}
        ])

      resolver = %{adapter: Receipt}

      assert {:ok, 17} =
               JobIdResolver.reconcile(resolver, api, @chain, "raxol-earn:deadbeef00000000")
    end
  end
end
