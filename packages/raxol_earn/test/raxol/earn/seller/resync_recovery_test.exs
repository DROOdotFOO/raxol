defmodule Raxol.Earn.Seller.ResyncRecoveryTest do
  use ExUnit.Case, async: false

  alias Raxol.Earn.JobSession
  alias Raxol.Earn.ProviderAdapter.Mock
  alias Raxol.Earn.Seller.{Queue, Resync}
  alias Raxol.Payments.Checkpoint

  @chain 84_532
  @counter :resync_test_counters

  defmodule Offering do
    use Raxol.Earn.Offering,
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

    unless Process.whereis(Raxol.Earn.JobSession.Registry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Raxol.Earn.JobSession.Registry)
    end

    unless Process.whereis(Raxol.Earn.JobSession.Supervisor) do
      start_supervised!(Raxol.Earn.JobSession.Supervisor)
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

    for {k, v} <- env, do: Application.put_env(:raxol_earn, k, v)
    on_exit(fn -> for {k, _} <- env, do: Application.delete_env(:raxol_earn, k) end)

    start_supervised!(Raxol.Earn.Checkpoint.Owner)
    # The seller Queue is already running (test_helper starts the seller stack);
    # it reads its defaults from Application on every dispatch, so the env set
    # above takes effect without recycling the singleton.

    # Attached here rather than per test so nothing can land in the gap between
    # acting and waiting. The drop events are the point: an offer the Queue
    # refuses names its reason, and that reason is what `await_status/2` reports
    # instead of timing out with no evidence. Transitions ride the same channel
    # to wake a wait the moment one lands.
    test_pid = self()
    handler_id = {__MODULE__, test_pid}

    :telemetry.attach_many(
      handler_id,
      [
        [:raxol, :earn, :job_session, :transition],
        [:raxol, :earn, :seller, :queue, :dropped]
      ],
      &__MODULE__.forward_event/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, adapter: adapter}
  end

  # Public and named so `:telemetry` gets a module capture; an anonymous handler
  # is a local function and telemetry logs about it on every attach.
  @doc false
  def forward_event(event, _measurements, metadata, test_pid) do
    send(test_pid, {:job_event, List.last(event), metadata})
  end

  defp api(jobs), do: %{adapter: StubApi, config: %{jobs: jobs}}
  defp calls(ctx), do: length(Mock.sent_calls(ctx.adapter))
  defp deliver_count, do: :ets.lookup_element(@counter, :deliver, 2)

  @await_timeout 5_000

  # `Queue.dispatch/1` is a cast, so it returns before the Queue has looked at
  # the event. Everything the event produces -- the provider adapter write and
  # the `JobSession.apply_event` mirror, both synchronous calls -- happens
  # inside that one callback, so a synchronous call to the Queue is a complete
  # barrier: once it returns, the event is fully processed.
  #
  # This is what the old `Process.sleep(20)` poll was standing in for, and it
  # was standing in badly. The poll could see a status transition while the
  # Queue was still mid-callback, so assertions on the adapter that follow the
  # status read a half-finished event.
  defp settle_queue do
    case Process.whereis(Queue) do
      nil -> :ok
      pid -> :sys.get_state(pid)
    end

    :ok
  catch
    # The Queue is a suite-wide singleton that `restart_queue!` deliberately
    # kills; racing its restart is not a failure, it just leaves nothing to
    # flush.
    :exit, _ -> :ok
  end

  # The barrier settles the common case, so this returns without waiting. What
  # remains genuinely asynchronous is a session stopping itself after a terminal
  # transition, which is what the deadline is for.
  #
  # A refused offer is reported rather than left as an absence: the Queue drops
  # with a named reason (`:no_provider_adapter`, `:at_capacity`,
  # `:offering_not_registered`, `{:handler_error, _}`), and timing out with
  # "condition never became true" throws that reason away.
  defp await_status(job_id, target) do
    settle_queue()
    deadline = System.monotonic_time(:millisecond) + @await_timeout
    await_status(job_id, target, deadline, [])
  end

  defp await_status(job_id, target, deadline, drops) do
    actual = status(job_id)

    cond do
      actual == target ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("""
        #{job_id} never reached #{inspect(target)} within #{@await_timeout}ms.
          last status: #{inspect(actual)}
          queue drops: #{if drops == [], do: "none", else: inspect(Enum.reverse(drops))}
        """)

      true ->
        receive do
          {:job_event, :dropped, %{job_id: ^job_id} = meta} ->
            await_status(job_id, target, deadline, [meta | drops])

          {:job_event, _kind, _meta} ->
            await_status(job_id, target, deadline, drops)
        after
          25 -> await_status(job_id, target, deadline, drops)
        end
    end
  end

  # Kept for waits that are not about a job's status, where there is no
  # telemetry to ride.
  defp eventually(what, fun, attempts \\ 100) do
    if fun.() do
      :ok
    else
      if attempts == 0, do: flunk("#{what} never became true")
      Process.sleep(20)
      eventually(what, fun, attempts - 1)
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

    eventually("Queue restarted", fn ->
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

    await_status(job, :budget_set)
    assert calls(ctx) == 1

    Queue.dispatch(%{type: :payment_received, job_id: job})
    await_status(job, :submitted)
    assert deliver_count() == 1
    assert calls(ctx) == 2

    # simulated restart: session killed, Queue restarted with empty job map.
    # The checkpoint table (supervisor-owned) survives.
    session_pid = GenServer.whereis(Raxol.Earn.JobSession.Registry.via({@chain, job}))
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

    await_status(job, :submitted)
    assert deliver_count() == 1
    assert calls(ctx) == 2

    # external evaluator approval routes through the re-adopted job and
    # completes it; terminal cleanup drops the checkpoint records.
    Queue.dispatch(%{type: :approval_received, job_id: job, payload: %{}})
    await_status(job, :gone)

    store = Raxol.Earn.Checkpoint.store()
    assert :error = Checkpoint.fetch(store, Raxol.Earn.Checkpoint.key(@chain, job, :submit))
    assert :error = Checkpoint.fetch(store, Raxol.Earn.Checkpoint.key(@chain, job, :accept))
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

    await_status(job, :budget_set)
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

    await_status(job, :submitted)

    Queue.dispatch(%{type: :approval_received, job_id: job, payload: %{}})
    await_status(job, :gone)
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
