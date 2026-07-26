defmodule Raxol.ACP.JobSession.ClientCheckpointTest do
  @moduledoc """
  Crash-window coverage for the buyer driver: across a replay at any phase there
  is exactly one `createJob` and one `fund`, and the budget is reserved once and
  released at most once. A replay is simulated by rebuilding the client from
  scratch with the SAME `request_key` (the checkpoint, not the in-memory struct,
  carries the truth) and re-running the step.
  """
  use ExUnit.Case, async: false

  alias Raxol.ACP.{AssetToken, JobSession}
  alias Raxol.ACP.JobSession.Client
  alias Raxol.ACP.ProviderAdapter.Mock, as: Adapter
  alias Raxol.ACP.JobIdResolver.Mock, as: Resolver
  alias Raxol.Payments.{Checkpoint, Ledger, SpendingPolicy}

  @chain 84_532
  @core "0x" <> String.duplicate("ab", 20)
  @provider "0x" <> String.duplicate("cd", 20)
  @buyer "0x" <> String.duplicate("ef", 20)
  @rk "fixed-request-key-000000000000000000000000000000000000000000000000"

  @create_selector Raxol.ACP.ABI.encode_call(
                     "createJob(address,address,uint256,string,address)",
                     []
                   )
  @fund_selector Raxol.ACP.ABI.encode_call("fund(uint256,uint256,bytes)", [])

  setup do
    unless Process.whereis(JobSession.Registry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: JobSession.Registry)
    end

    unless Process.whereis(JobSession.Supervisor) do
      start_supervised!(JobSession.Supervisor)
    end

    {:ok, ledger} =
      Ledger.start_link(table_name: :"ck_ledger_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      try do
        GenServer.stop(ledger)
      catch
        :exit, _ -> :ok
      end
    end)

    adapter = Adapter.new()
    resolver = Resolver.new()
    :ok = Resolver.put_default(resolver, 4242)
    store = Checkpoint.ETS.new()
    api = Raxol.ACP.JobApi.Mock.new()

    {:ok, adapter: adapter, resolver: resolver, store: store, ledger: ledger, api: api}
  end

  # A fresh client sharing the fixed request_key -- this is the "after a crash,
  # a new process rebuilds the client" state.
  defp client(ctx) do
    Client.new(
      adapter: ctx.adapter,
      api: ctx.api,
      resolver: ctx.resolver,
      chain_id: @chain,
      acp_core_address: @core,
      buyer: @buyer,
      provider: @provider,
      amount: AssetToken.usdc(10, @chain),
      ledger: ctx.ledger,
      policy: SpendingPolicy.unrestricted(),
      agent_id: :ck_buyer,
      checkpoint: ctx.store,
      request_key: @rk
    )
  end

  defp count(ctx, selector) do
    ctx.adapter
    |> Adapter.sent_calls()
    |> Enum.count(fn {_chain, [call | _]} ->
      binary_part(call.data, 0, byte_size(selector)) == selector
    end)
  end

  test "replaying buy after `bound` does not create a second job", ctx do
    assert {:ok, _c, %{job_id: job_id}} = Client.buy(client(ctx))
    assert count(ctx, @create_selector) == 1

    # Crash + restart: fresh client, same request_key, re-run buy.
    assert {:ok, c2, %{status: :resumed, job_id: ^job_id}} = Client.buy(client(ctx))
    assert c2.job_id == job_id
    assert count(ctx, @create_selector) == 1
  end

  test "a `creating` record reconciles by tag instead of double-creating", ctx do
    c = client(ctx)
    tag = Client.request_tag(c)
    :ok = Resolver.put_tag(ctx.resolver, tag, 777)

    # Pin the crash-in-`creating` state: params written, broadcast status unknown.
    key = Raxol.ACP.Checkpoint.buyer_key(@chain, @rk)

    :ok =
      Checkpoint.put(ctx.store, key, %{
        "phase" => "creating",
        "request_key" => @rk,
        "amount_raw" => AssetToken.usdc(10, @chain).raw_amount,
        "create_params" => %{
          "provider" => @provider,
          "evaluator" => @buyer,
          "expired_at" => 0,
          "hook_address" => "0x" <> String.duplicate("0", 40),
          "description" => tag
        }
      })

    assert {:ok, c2, %{status: :open, job_id: 777}} = Client.buy(c)
    assert c2.job_id == 777
    # Reconcile adopted the existing job: NO createJob broadcast.
    assert count(ctx, @create_selector) == 0
  end

  test "a `creating` record with no reconcilable job re-creates exactly once", ctx do
    c = client(ctx)
    key = Raxol.ACP.Checkpoint.buyer_key(@chain, @rk)

    :ok =
      Checkpoint.put(ctx.store, key, %{
        "phase" => "creating",
        "request_key" => @rk,
        "amount_raw" => AssetToken.usdc(10, @chain).raw_amount,
        "create_params" => %{
          "provider" => @provider,
          "evaluator" => @buyer,
          "expired_at" => 0,
          "hook_address" => "0x" <> String.duplicate("0", 40),
          "description" => Client.request_tag(c)
        }
      })

    # No tag seeded in the resolver and no active job -> reconcile :none -> create.
    assert {:ok, _c2, %{status: :open, job_id: 4242}} = Client.buy(c)
    assert count(ctx, @create_selector) == 1
  end

  test "a `created` record resolves the job_id from the tx without re-creating", ctx do
    key = Raxol.ACP.Checkpoint.buyer_key(@chain, @rk)
    :ok = Resolver.put_tx(ctx.resolver, "0xcreatetx", 555)

    :ok =
      Checkpoint.put(ctx.store, key, %{
        "phase" => "created",
        "request_key" => @rk,
        "amount_raw" => AssetToken.usdc(10, @chain).raw_amount,
        "create_tx" => "0xcreatetx"
      })

    assert {:ok, c2, %{status: :open, job_id: 555, tx_hash: "0xcreatetx"}} =
             Client.buy(client(ctx))

    assert c2.job_id == 555
    assert count(ctx, @create_selector) == 0
  end

  test "replaying on_budget_set after `funded` does not double-fund", ctx do
    {:ok, c, _} = Client.buy(client(ctx))
    {:ok, _c, %{status: :funded}} = Client.on_budget_set(c)
    assert count(ctx, @fund_selector) == 1

    # Crash + restart mid-fund-mirror: rebuild, resume from the `funded` record.
    {:ok, c2, %{job_id: _}} = Client.buy(client(ctx))
    assert {:ok, %{status: :funded, idempotent: true}} = Client.on_budget_set(c2)
    assert count(ctx, @fund_selector) == 1
  end

  test "budget reserved exactly once across a buy replay", ctx do
    {:ok, _c, _} = Client.buy(client(ctx))
    {:ok, _c2, _} = Client.buy(client(ctx))

    # One reservation of 10 USDC, not two.
    totals = Ledger.get_totals(ctx.ledger, :ck_buyer, SpendingPolicy.unrestricted())
    assert Decimal.equal?(totals.lifetime, Decimal.new(10))
  end
end
