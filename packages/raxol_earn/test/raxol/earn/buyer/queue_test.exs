defmodule Raxol.Earn.Buyer.QueueTest do
  use ExUnit.Case, async: false

  alias Raxol.Earn.Buyer.Queue
  alias Raxol.Earn.{AssetToken, JobSession}
  alias Raxol.Earn.ProviderAdapter.Mock, as: Adapter
  alias Raxol.Earn.JobIdResolver.Mock, as: Resolver
  alias Raxol.Payments.{Ledger, SpendingPolicy}

  @chain 84_532
  @core "0x" <> String.duplicate("ab", 20)
  @provider "0x" <> String.duplicate("cd", 20)
  @buyer "0x" <> String.duplicate("ef", 20)

  setup do
    unless Process.whereis(JobSession.Registry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: JobSession.Registry)
    end

    unless Process.whereis(JobSession.Supervisor) do
      start_supervised!(JobSession.Supervisor)
    end

    {:ok, ledger} =
      Ledger.start_link(table_name: :"bq_ledger_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      try do
        GenServer.stop(ledger)
      catch
        :exit, _ -> :ok
      end
    end)

    adapter = Adapter.new()
    resolver = Resolver.new()
    :ok = Resolver.put_default(resolver, System.unique_integer([:positive]))

    put_all(%{
      buyer_provider_adapter: adapter,
      buyer_chain_id: @chain,
      buyer_acp_core_address: @core,
      buyer_address: @buyer,
      buyer_agent_id: :queue_buyer,
      buyer_spending_policy: SpendingPolicy.unrestricted(),
      buyer_ledger: ledger,
      buyer_job_id_resolver: resolver
    })

    start_supervised!(Queue)

    {:ok, adapter: adapter, ledger: ledger}
  end

  defp put_all(map) do
    Enum.each(map, fn {k, v} -> Application.put_env(:raxol_earn, k, v) end)

    on_exit(fn ->
      Enum.each(Map.keys(map), &Application.delete_env(:raxol_earn, &1))
    end)
  end

  defp poll_status(key, expected, attempts \\ 100)
  defp poll_status(_key, _expected, 0), do: flunk("status never reached")

  defp poll_status(key, expected, attempts) do
    if status_or_gone(key) == expected do
      :ok
    else
      Process.sleep(5)
      poll_status(key, expected, attempts - 1)
    end
  end

  defp status_or_gone(key) do
    JobSession.status(key)
  catch
    :exit, _ -> :gone
  end

  test "start_purchase originates a job and dispatch drives it to completion" do
    intent = %{provider: @provider, amount: AssetToken.usdc(10, @chain), offering: "svc"}

    assert {:ok, job_id} = Queue.start_purchase(intent)
    assert JobSession.status({@chain, job_id}) == :open

    Queue.dispatch(%{type: :budget_set, job_id: job_id})
    poll_status({@chain, job_id}, :funded)

    Queue.dispatch(%{type: :submitted, job_id: job_id, deliverable: %{"result" => "ok"}})
    poll_status({@chain, job_id}, :gone)
  end

  test "start_purchase fails closed when no provider adapter is configured" do
    Application.delete_env(:raxol_earn, :buyer_provider_adapter)

    assert {:error, :no_provider_adapter} =
             Queue.start_purchase(%{provider: @provider, amount: AssetToken.usdc(10, @chain)})
  end

  test "events for jobs we do not track drop without crashing", %{adapter: adapter} do
    Queue.dispatch(%{type: :budget_set, job_id: 999_999})
    # The Queue survives an untracked event.
    Process.sleep(20)
    assert Process.alive?(Process.whereis(Queue))
    # No on-chain writes happened for the phantom job.
    assert Adapter.sent_calls(adapter) == []
  end
end
