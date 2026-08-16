defmodule Raxol.Earn.JobIdResolverScopeTest do
  @moduledoc """
  The `createJob` receipt a buyer decodes is not always its own transaction's.
  On the ERC-4337 path `ProviderAdapter.SCA` reports the BUNDLE's
  `transactionHash`, so the receipt carries the logs of every UserOp the bundler
  packed, including another buyer's genuine `JobCreated` from the same ACP core.
  These cover the scoping that keeps a bundle-mate's jobId out of our binding.
  """

  use ExUnit.Case, async: true

  alias Raxol.Earn.AssetToken
  alias Raxol.Earn.JobIdResolver
  alias Raxol.Earn.JobIdResolver.Receipt
  alias Raxol.Earn.JobSession.Client
  alias Raxol.Earn.Onchain.LogDecoder
  alias Raxol.Earn.ProviderAdapter.Mock, as: Adapter

  @chain 84_532
  @signature "JobCreated(uint256,address,address,address,uint256,address)"

  @core "0x" <> String.duplicate("ce", 20)
  @other_core "0x" <> String.duplicate("ff", 20)
  @buyer "0x" <> String.duplicate("11", 20)
  @stranger "0x" <> String.duplicate("99", 20)
  @provider "0x" <> String.duplicate("22", 20)

  describe "resolve/4 on a shared-bundle receipt" do
    test "binds our jobId, not the bundle-mate's that precedes it" do
      adapter = Adapter.new()

      :ok =
        Adapter.set_receipt(adapter, "0xbundle", %{
          "logs" => [
            job_created_log(@core, 7, @stranger),
            job_created_log(@core, 42, @buyer)
          ]
        })

      assert {:ok, 42} = JobIdResolver.resolve(scoped_resolver(), adapter, @chain, "0xbundle")
    end

    test "a bundle carrying only a stranger's job stays :pending" do
      adapter = Adapter.new()

      :ok =
        Adapter.set_receipt(adapter, "0xbundle", %{
          "logs" => [job_created_log(@core, 7, @stranger)]
        })

      assert :pending = JobIdResolver.resolve(scoped_resolver(), adapter, @chain, "0xbundle")
    end

    test "our client on a foreign emitter does not match" do
      adapter = Adapter.new()

      :ok =
        Adapter.set_receipt(adapter, "0xbundle", %{
          "logs" => [job_created_log(@other_core, 7, @buyer)]
        })

      assert :pending = JobIdResolver.resolve(scoped_resolver(), adapter, @chain, "0xbundle")
    end

    test "a log with no emitter cannot satisfy an emitter constraint" do
      adapter = Adapter.new()
      log = @core |> job_created_log(7, @buyer) |> Map.delete("address")

      :ok = Adapter.set_receipt(adapter, "0xbundle", %{"logs" => [log]})

      assert :pending = JobIdResolver.resolve(scoped_resolver(), adapter, @chain, "0xbundle")
    end

    test "an unscoped resolver still takes the first signature match" do
      adapter = Adapter.new()

      :ok =
        Adapter.set_receipt(adapter, "0xbundle", %{
          "logs" => [
            job_created_log(@core, 7, @stranger),
            job_created_log(@core, 42, @buyer)
          ]
        })

      assert {:ok, 7} = JobIdResolver.resolve(%{adapter: Receipt}, adapter, @chain, "0xbundle")
    end
  end

  describe "Client.new/1 scoping" do
    test "fills the resolver emitter and client from the buyer it was built for" do
      client = build_client(resolver: %{adapter: Receipt})

      assert %{adapter: Receipt, config: %{emitter: @core, client: @buyer}} = client.resolver
    end

    test "defaults the resolver to a scoped Receipt when none is given" do
      client = build_client([])

      assert %{adapter: Receipt, config: %{emitter: @core, client: @buyer}} = client.resolver
    end

    test "an explicit config wins, including an explicit nil opt-out" do
      client =
        build_client(resolver: %{adapter: Receipt, config: %{emitter: @other_core, client: nil}})

      assert %{config: %{emitter: @other_core, client: nil}} = client.resolver
    end
  end

  describe "LogDecoder.find_event/3" do
    test "rejects a malformed expected topic rather than silently not matching" do
      logs = [job_created_log(@core, 42, @buyer)]

      assert_raise ArgumentError, fn ->
        LogDecoder.find_event(logs, @signature, topics: %{2 => "not-a-topic"})
      end
    end

    test "a topic index past the log's topics does not match" do
      logs = [job_created_log(@core, 42, @buyer)]

      assert :error = LogDecoder.find_event(logs, @signature, topics: %{9 => @buyer})
    end
  end

  # -- Fixtures --

  defp scoped_resolver do
    %{adapter: Receipt, config: %{emitter: @core, client: @buyer}}
  end

  defp build_client(opts) do
    Client.new(
      Keyword.merge(
        [
          adapter: %{},
          chain_id: @chain,
          acp_core_address: @core,
          buyer: @buyer,
          provider: @provider,
          amount: AssetToken.usdc_from_raw(1_000_000, @chain)
        ],
        opts
      )
    )
  end

  defp job_created_log(emitter, job_id, client) do
    %{
      "address" => emitter,
      "topics" => [
        LogDecoder.event_topic(@signature),
        uint_topic(job_id),
        address_topic(client),
        address_topic(@provider)
      ]
    }
  end

  defp uint_topic(value) do
    hex = Integer.to_string(value, 16)
    "0x" <> String.duplicate("0", 64 - byte_size(hex)) <> String.downcase(hex)
  end

  defp address_topic("0x" <> hex), do: "0x" <> String.duplicate("0", 24) <> String.downcase(hex)
end
