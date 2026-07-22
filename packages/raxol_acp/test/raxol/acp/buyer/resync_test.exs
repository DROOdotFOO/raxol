defmodule Raxol.ACP.Buyer.ResyncTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.Buyer.{Queue, Resync}
  alias Raxol.ACP.JobSession
  alias Raxol.ACP.ProviderAdapter.Mock, as: Adapter
  alias Raxol.ACP.JobIdResolver.Mock, as: Resolver
  alias Raxol.ACP.JobApi.Mock, as: JobApiMock
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
      Ledger.start_link(table_name: :"rs_ledger_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      try do
        GenServer.stop(ledger)
      catch
        :exit, _ -> :ok
      end
    end)

    adapter = Adapter.new()
    resolver = Resolver.new()

    put_all(%{
      buyer_provider_adapter: adapter,
      buyer_chain_id: @chain,
      buyer_acp_core_address: @core,
      buyer_address: @buyer,
      buyer_agent_id: :resync_buyer,
      buyer_spending_policy: SpendingPolicy.unrestricted(),
      buyer_ledger: ledger,
      buyer_job_id_resolver: resolver
    })

    start_supervised!(Queue)

    {:ok, adapter: adapter}
  end

  defp put_all(map) do
    Enum.each(map, fn {k, v} -> Application.put_env(:raxol_acp, k, v) end)
    on_exit(fn -> Enum.each(Map.keys(map), &Application.delete_env(:raxol_acp, &1)) end)
  end

  defp poll_status(key, expected, attempts \\ 100)
  defp poll_status(_key, expected, 0), do: flunk("status never reached #{inspect(expected)}")

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

  test "rehydrates an interrupted budget_set job and resumes the fund", %{adapter: adapter} do
    api = JobApiMock.new()

    :ok =
      JobApiMock.put_active_jobs(api, [
        %{
          "onChainJobId" => "321",
          "provider" => @provider,
          "buyer" => @buyer,
          "status" => "budget_set",
          "budget" => "10000000"
        }
      ])

    start_supervised!({Resync, api: api})

    # Resync adopts the job and redrives the interrupted fund.
    poll_status({@chain, 321}, :funded)
    assert length(Adapter.sent_calls(adapter)) == 1
  end

  test "skips jobs belonging to another buyer" do
    api = JobApiMock.new()

    :ok =
      JobApiMock.put_active_jobs(api, [
        %{
          "onChainJobId" => "55",
          "provider" => @provider,
          "buyer" => "0x" <> String.duplicate("11", 20),
          "status" => "budget_set",
          "budget" => "10000000"
        }
      ])

    start_supervised!({Resync, api: api})
    Process.sleep(30)

    assert status_or_gone({@chain, 55}) == :gone
  end

  test "is inert with no job api configured" do
    start_supervised!({Resync, api: nil})
    Process.sleep(20)
    assert Process.alive?(Process.whereis(Resync))
  end
end
