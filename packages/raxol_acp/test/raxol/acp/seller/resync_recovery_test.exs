defmodule Raxol.ACP.Seller.ResyncRecoveryTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.JobSession
  alias Raxol.ACP.ProviderAdapter.Mock
  alias Raxol.ACP.Seller.{Queue, Resync}
  alias Raxol.Payments.Checkpoint

  @chain 84_532
  @counter :resync_test_counters

  defmodule Offering do
    use Raxol.ACP.Offering,
      name: "resync_probe",
      price_usdc: 1,
      sla_minutes: 5,
      cluster: "test"

    @impl true
    def handle_request(request, _ctx), do: {:accept, request}

    @impl true
    def handle_deliver(_request, _ctx) do
      :ets.update_counter(:resync_test_counters, :deliver, 1, {:deliver, 0})
      {:deliver, %{"payload" => "run-#{System.unique_integer([:positive])}"}}
    end
  end

  defmodule StubApi do
    def get_active_jobs(%{config: %{jobs: jobs}}), do: {:ok, jobs}
  end

  setup do
    if :ets.whereis(@counter) == :undefined,
      do: :ets.new(@counter, [:set, :public, :named_table])

    :ets.insert(@counter, {:deliver, 0})

    unless Process.whereis(Raxol.ACP.JobSession.Registry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Raxol.ACP.JobSession.Registry)
    end

    unless Process.whereis(Raxol.ACP.JobSession.Supervisor) do
      start_supervised!(Raxol.ACP.JobSession.Supervisor)
    end

    case Offering.register() do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    adapter = Mock.new()

    env = [
      seller_provider_adapter: adapter,
      seller_chain_id: @chain,
      seller_address: "0x" <> String.duplicate("cd", 20),
      checkpoint: {:ets, :resync_test_checkpoint},
      offerings: [Offering]
    ]

    for {k, v} <- env, do: Application.put_env(:raxol_acp, k, v)
    on_exit(fn -> for {k, _} <- env, do: Application.delete_env(:raxol_acp, k) end)

    start_supervised!(Raxol.ACP.Checkpoint.Owner)
    # The seller Queue is already running (test_helper starts the seller stack);
    # it reads its defaults from Application on every dispatch, so the env set
    # above takes effect without recycling the singleton.

    {:ok, adapter: adapter}
  end

  defp api(jobs), do: %{adapter: StubApi, config: %{jobs: jobs}}
  defp calls(ctx), do: length(Mock.sent_calls(ctx.adapter))
  defp deliver_count, do: :ets.lookup_element(@counter, :deliver, 2)

  defp eventually(fun, attempts \\ 100) do
    if fun.() do
      :ok
    else
      if attempts == 0, do: flunk("condition never became true")
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp status(job_id) do
    JobSession.status({@chain, job_id})
  catch
    :exit, _ -> :gone
  end

  # Simulate a Queue crash: kill the running singleton and let the seller
  # supervisor (:rest_for_one) restart it with an empty in-memory job map. The
  # test-owned checkpoint table lives under the test supervisor, so it survives.
  defp restart_queue! do
    pid = Process.whereis(Queue)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}

    eventually(fn ->
      case Process.whereis(Queue) do
        nil -> false
        new -> new != pid
      end
    end)
  end

  test "kill-and-restart mid-lifecycle: exactly one handler run, one submit, escrow completes",
       ctx do
    job = "rj-#{System.unique_integer([:positive])}"

    # live path: offered -> budget_set -> funded -> submitted
    Queue.dispatch(%{
      type: :job_offered,
      job_id: job,
      offering: "resync_probe",
      request: %{"p" => 1}
    })

    eventually(fn -> status(job) == :budget_set end)
    assert calls(ctx) == 1

    Queue.dispatch(%{type: :payment_received, job_id: job})
    eventually(fn -> status(job) == :submitted end)
    assert deliver_count() == 1
    assert calls(ctx) == 2

    # simulated restart: session killed, Queue restarted with empty job map.
    # The checkpoint table (supervisor-owned) survives.
    session_pid = GenServer.whereis(Raxol.ACP.JobSession.Registry.via({@chain, job}))
    ref = Process.monitor(session_pid)
    Process.exit(session_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    restart_queue!()

    # authoritative state still says :funded (submit landed but API lags --
    # the worst window). Resync rehydrates + re-enqueues the delivery; the
    # Provider resumes from the pinned record instead of re-submitting.
    assert {:ok, %{redelivered: 1}} =
             Resync.run(
               api([
                 %{
                   "id" => job,
                   "phase" => "funded",
                   "chainId" => @chain,
                   "offering" => %{"name" => "resync_probe"},
                   "requirement" => %{"p" => 1}
                 }
               ])
             )

    eventually(fn -> status(job) == :submitted end)
    assert deliver_count() == 1
    assert calls(ctx) == 2

    # external evaluator approval routes through the re-adopted job and
    # completes it; terminal cleanup drops the checkpoint records.
    Queue.dispatch(%{type: :approval_received, job_id: job, payload: %{}})
    eventually(fn -> status(job) == :gone end)

    store = Raxol.ACP.Checkpoint.store()
    assert :error = Checkpoint.fetch(store, Raxol.ACP.Checkpoint.key(@chain, job, :submit))
    assert :error = Checkpoint.fetch(store, Raxol.ACP.Checkpoint.key(@chain, job, :accept))
  end

  test "an :open job resyncs through the normal accept path" do
    job = "rj-open-#{System.unique_integer([:positive])}"

    assert {:ok, %{adopted: 1}} =
             Resync.run(
               api([
                 %{
                   "id" => job,
                   "phase" => "open",
                   "chainId" => @chain,
                   "offering" => %{"name" => "resync_probe"}
                 }
               ])
             )

    eventually(fn -> status(job) == :budget_set end)
  end

  test "a :submitted job is adopted so a later approval still completes it" do
    job = "rj-sub-#{System.unique_integer([:positive])}"

    assert {:ok, %{adopted: 1}} =
             Resync.run(
               api([
                 %{
                   "id" => job,
                   "phase" => "evaluation",
                   "chainId" => @chain,
                   "offering" => %{"name" => "resync_probe"}
                 }
               ])
             )

    eventually(fn -> status(job) == :submitted end)

    Queue.dispatch(%{type: :approval_received, job_id: job, payload: %{}})
    eventually(fn -> status(job) == :gone end)
  end

  test "unknown, numeric, and foreign-chain phases are skipped, not acted on" do
    # x3 carries a numeric phase: the integer enum order is not pinned, so it is
    # skipped (fail closed) rather than positionally mapped to a guessed phase.
    assert {:ok, %{skipped: 3, adopted: 0, redelivered: 0}} =
             Resync.run(
               api([
                 %{"id" => "x1", "phase" => "haggling", "chainId" => @chain},
                 %{"id" => "x2", "phase" => "funded", "chainId" => 1},
                 %{"id" => "x3", "phase" => 2, "chainId" => @chain}
               ])
             )
  end
end
