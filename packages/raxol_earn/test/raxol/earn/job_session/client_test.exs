defmodule Raxol.Earn.JobSession.ClientTest do
  use ExUnit.Case, async: false

  alias Raxol.Earn.{AssetToken, JobSession}
  alias Raxol.Earn.JobSession.Client
  alias Raxol.Earn.ProviderAdapter.Mock, as: Adapter
  alias Raxol.Earn.JobIdResolver.Mock, as: Resolver
  alias Raxol.Payments.{Checkpoint, Ledger, SpendingPolicy}

  @chain 84_532
  @core "0x" <> String.duplicate("ab", 20)
  @provider "0x" <> String.duplicate("cd", 20)
  @buyer "0x" <> String.duplicate("ef", 20)

  setup do
    ensure_session_infra()

    ledger = start_ledger()
    adapter = Adapter.new()
    resolver = Resolver.new()
    :ok = Resolver.put_default(resolver, System.unique_integer([:positive]))
    store = Checkpoint.ETS.new()

    {:ok, adapter: adapter, resolver: resolver, store: store, ledger: ledger}
  end

  defp ensure_session_infra do
    unless Process.whereis(JobSession.Registry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: JobSession.Registry)
    end

    unless Process.whereis(JobSession.Supervisor) do
      start_supervised!(JobSession.Supervisor)
    end
  end

  defp start_ledger do
    {:ok, ledger} =
      Ledger.start_link(table_name: :"client_test_ledger_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      try do
        GenServer.stop(ledger)
      catch
        :exit, _ -> :ok
      end
    end)

    ledger
  end

  defp client(ctx, opts \\ []) do
    Client.new(
      Keyword.merge(
        [
          adapter: ctx.adapter,
          resolver: ctx.resolver,
          chain_id: @chain,
          acp_core_address: @core,
          buyer: @buyer,
          provider: @provider,
          amount: AssetToken.usdc(10, @chain),
          ledger: ctx.ledger,
          policy: SpendingPolicy.unrestricted(),
          agent_id: :test_buyer,
          checkpoint: ctx.store,
          nonce: System.unique_integer([:positive])
        ],
        opts
      )
    )
  end

  defp call_sigs(ctx) do
    ctx.adapter |> Adapter.sent_calls() |> Enum.map(fn {_chain, [call | _]} -> call.data end)
  end

  test "buy reserves, creates the job, resolves the job_id, and starts a client session", ctx do
    c = client(ctx)

    assert {:ok, c, %{status: :open, job_id: job_id, tx_hash: tx}} = Client.buy(c)
    assert is_integer(job_id)
    assert is_binary(tx)
    assert c.job_id == job_id
    assert JobSession.status({@chain, job_id}) == :open

    # Exactly one on-chain write (createJob) so far.
    assert length(Adapter.sent_calls(ctx.adapter)) == 1

    # The purchase is checkpointed at the `bound` phase.
    key = Raxol.Earn.Checkpoint.buyer_key(@chain, c.request_key)
    assert {:ok, %{"phase" => "bound", "job_id" => ^job_id}} = Checkpoint.fetch(ctx.store, key)
  end

  test "on_budget_set funds the escrow and mirrors :funded", ctx do
    {:ok, c, _} = Client.buy(client(ctx))

    assert {:ok, c, %{status: :funded, tx_hash: _}} = Client.on_budget_set(c)
    assert JobSession.status({@chain, c.job_id}) == :funded
    # createJob + fund
    assert length(Adapter.sent_calls(ctx.adapter)) == 2
  end

  test "on_submitted approves -> complete on-chain, spend stands", ctx do
    {:ok, c, _} = Client.buy(client(ctx))
    {:ok, c, _} = Client.on_budget_set(c)

    deliverable = %{"result" => "ok"}
    assert {:ok, c, %{status: :completed, tx_hash: _}} = Client.on_submitted(c, deliverable)

    # createJob + fund + complete
    assert length(Adapter.sent_calls(ctx.adapter)) == 3

    # The reservation was forgotten but the spend stands (net 10 spent).
    totals = Ledger.get_totals(ctx.ledger, :test_buyer, SpendingPolicy.unrestricted())
    assert Decimal.equal?(totals.lifetime, Decimal.new(10))

    # Checkpoint cleaned up at the terminal.
    key = Raxol.Earn.Checkpoint.buyer_key(@chain, c.request_key)
    assert :error = Checkpoint.fetch(ctx.store, key)
  end

  test "on_submitted rejects -> reject on-chain and releases the reservation", ctx do
    reject_fn = fn _deliverable, _ctx -> {:reject, :bad} end
    {:ok, c, _} = Client.buy(client(ctx, evaluate_fn: reject_fn))
    {:ok, c, _} = Client.on_budget_set(c)

    assert {:ok, c, %{status: :rejected}} = Client.on_submitted(c, %{"x" => 1})

    # Reservation released: lifetime nets back to 0.
    totals = Ledger.get_totals(ctx.ledger, :test_buyer, SpendingPolicy.unrestricted())
    assert Decimal.equal?(totals.lifetime, Decimal.new(0))
    assert_session_gone({@chain, c.job_id})
  end

  test "spend over the per-request cap is rejected before any on-chain write", ctx do
    tight = %SpendingPolicy{
      per_request_max: Decimal.new("1.00"),
      session_max: Decimal.new("1.00"),
      lifetime_max: Decimal.new("1.00"),
      currency: "USDC"
    }

    c = client(ctx, policy: tight)

    assert {:rejected, {:spend_rejected, {:over_budget, _}}} = Client.buy(c)
    assert Adapter.sent_calls(ctx.adapter) == []
  end

  test "fail-closed: require_policy with no policy refuses before any write", ctx do
    c = client(ctx, policy: nil, require_policy: true)

    assert {:rejected, {:spend_rejected, {:policy_required, _}}} = Client.buy(c)
    assert Adapter.sent_calls(ctx.adapter) == []
  end

  test "fail-closed: require_checkpoint with no store refuses before reserve", ctx do
    Application.put_env(:raxol_earn, :require_checkpoint, true)
    on_exit(fn -> Application.delete_env(:raxol_earn, :require_checkpoint) end)

    c = client(ctx, checkpoint: nil)

    assert {:error, :checkpoint_required} = Client.buy(c)
    assert Adapter.sent_calls(ctx.adapter) == []
  end

  test "a budget exceeding the reserved ceiling is rejected and the reservation released", ctx do
    {:ok, c, _} = Client.buy(client(ctx))
    reserved_raw = AssetToken.usdc(10, @chain).raw_amount

    assert {:rejected, {:budget_over_reserved, _, ^reserved_raw}} =
             Client.on_budget_set(c, reserved_raw + 1)

    # Only createJob was written; no fund. The session expired (terminal).
    assert length(Adapter.sent_calls(ctx.adapter)) == 1
    assert_session_gone({@chain, c.job_id})

    totals = Ledger.get_totals(ctx.ledger, :test_buyer, SpendingPolicy.unrestricted())
    assert Decimal.equal?(totals.lifetime, Decimal.new(0))
  end

  # createJob is the first sent call; assert its calldata starts with the
  # createJob 4-byte selector (ABI.encode_call returns raw bytes).
  test "buy writes createJob (not fund) as its first on-chain call", ctx do
    {:ok, _c, _} = Client.buy(client(ctx))
    [first_data | _] = call_sigs(ctx)
    selector = Raxol.Earn.ABI.encode_call("createJob(address,address,uint256,string,address)", [])
    assert binary_part(first_data, 0, byte_size(selector)) == selector
  end

  defp assert_session_gone(key), do: wait_gone(key, 50)

  defp wait_gone(key, 0), do: flunk("session #{inspect(key)} still alive")

  defp wait_gone(key, attempts) do
    case Registry.lookup(JobSession.Registry, key) do
      [] ->
        :ok

      [{pid, _}] ->
        if Process.alive?(pid) do
          Process.sleep(5)
          wait_gone(key, attempts - 1)
        else
          :ok
        end
    end
  end
end
