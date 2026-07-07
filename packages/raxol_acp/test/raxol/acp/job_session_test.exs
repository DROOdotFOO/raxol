defmodule Raxol.ACP.JobSessionTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.{AssetToken, JobSession}
  alias Raxol.ACP.JobSession.Registry

  setup do
    # Terminate any leftover JobSession children from prior tests so the
    # registry doesn't carry stale {chain_id, job_id} entries.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(JobSession.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(JobSession.Supervisor, pid)
    end

    :ok
  end

  defp start_session(opts) do
    opts =
      [chain_id: 8453, job_id: "job-#{System.unique_integer([:positive])}"]
      |> Keyword.merge(opts)

    {:ok, pid} = JobSession.Supervisor.start_session(opts)
    {pid, Keyword.fetch!(opts, :job_id)}
  end

  describe "start_link + registration" do
    test "registers under {chain_id, job_id}" do
      {pid, job_id} = start_session(role: :provider)

      assert Registry.whereis({8453, job_id}) == pid
      assert JobSession.status({8453, job_id}) == :open
      assert JobSession.role({8453, job_id}) == :provider
    end

    test "respects :initial_status" do
      {_pid, job_id} = start_session(role: :provider, initial_status: :budget_set)
      assert JobSession.status({8453, job_id}) == :budget_set
    end
  end

  describe "happy-path lifecycle" do
    test "provider sets budget; client funds; provider submits; evaluator completes" do
      {provider, job_id} = start_session(role: :provider)
      ref = Process.monitor(provider)
      budget = AssetToken.usdc(0.1, 8453)

      assert {:ok, :budget_set} = JobSession.set_budget(provider, budget)
      assert JobSession.status(provider) == :budget_set

      # Spawn a separate session as :client to fund.
      {:ok, client} =
        JobSession.Supervisor.start_session(
          chain_id: 8453,
          job_id: "client-#{job_id}",
          role: :client,
          initial_status: :budget_set
        )

      assert {:ok, :funded} = JobSession.fund(client)

      # Provider's session must also reach :funded for submit to work. In real
      # life the SSE transport propagates this; here we mirror it as an
      # observed event (a provider role can't fund).
      {:ok, :funded} = JobSession.apply_event(provider, :funded)
      assert {:ok, :submitted} = JobSession.submit(provider, %{result: "done"})

      {:ok, evaluator} =
        JobSession.Supervisor.start_session(
          chain_id: 8453,
          job_id: "eval-#{job_id}",
          role: :evaluator,
          initial_status: :submitted
        )

      eval_ref = Process.monitor(evaluator)
      assert {:ok, :completed} = JobSession.complete(evaluator, "ok")

      # Both terminal sessions exit :normal.
      assert_receive {:DOWN, ^eval_ref, :process, ^evaluator, :normal}, 500
      _ = ref
    end

    test "rejection path: submitted -> rejected stops the session" do
      {evaluator, _job_id} = start_session(role: :evaluator, initial_status: :submitted)
      ref = Process.monitor(evaluator)

      assert {:ok, :rejected} = JobSession.reject(evaluator, "bad output")
      assert_receive {:DOWN, ^ref, :process, ^evaluator, :normal}, 500
    end
  end

  describe "role gating" do
    test "client cannot set_budget" do
      {client, _} = start_session(role: :client)
      budget = AssetToken.usdc(0.1, 8453)

      assert {:error, {:not_allowed_for_role, :client, :set_budget, :open}} =
               JobSession.set_budget(client, budget)
    end

    test "client cannot submit" do
      {client, _} = start_session(role: :client, initial_status: :funded)

      assert {:error, {:not_allowed_for_role, :client, :submit, :funded}} =
               JobSession.submit(client, %{})
    end

    test "provider cannot complete" do
      {provider, _} = start_session(role: :provider, initial_status: :submitted)

      assert {:error, {:not_allowed_for_role, :provider, :complete, :submitted}} =
               JobSession.complete(provider, "ok")
    end

    test "evaluator cannot fund" do
      {evaluator, _} = start_session(role: :evaluator, initial_status: :budget_set)

      assert {:error, {:not_allowed_for_role, :evaluator, :fund, :budget_set}} =
               JobSession.fund(evaluator)
    end
  end

  describe "set_budget_with_fund_request" do
    test "transitions to :budget_set and records destination" do
      {provider, _} = start_session(role: :provider)
      budget = AssetToken.usdc(0.1, 8453)
      transfer = AssetToken.usdc(1, 8453)
      destination = "0x" <> String.duplicate("ab", 20)

      assert {:ok, :budget_set} =
               JobSession.set_budget_with_fund_request(provider, budget, transfer, destination)

      [entry] = Enum.filter(JobSession.entries(provider), &(&1.kind == :system))
      assert entry.event == :budget_set
      assert entry.payload.budget == budget
      assert entry.payload.transfer_amount == transfer
      assert entry.payload.destination == destination
    end
  end

  describe "send_message + subscriptions" do
    test "subscribers receive entries for messages and transitions" do
      {provider, job_id} = start_session(role: :provider)
      :ok = JobSession.subscribe(provider)

      :ok = JobSession.send_message(provider, "hello", "text")

      assert_receive {JobSession, {8453, ^job_id}, %{kind: :message, content: "hello"}}, 100

      budget = AssetToken.usdc(0.1, 8453)
      {:ok, :budget_set} = JobSession.set_budget(provider, budget)

      assert_receive {JobSession, {8453, ^job_id}, %{kind: :system, event: :budget_set}}, 100
    end

    test "monitors subscribers and drops dead pids" do
      {provider, _} = start_session(role: :provider)

      subscriber =
        spawn(fn ->
          :ok = JobSession.subscribe(provider)
          receive do: (:die -> :ok)
        end)

      # Let the subscribe call land
      Process.sleep(20)
      send(subscriber, :die)
      Process.sleep(20)

      state = JobSession.get_state(provider)
      refute MapSet.member?(state.subscribers, subscriber)
    end
  end

  describe "available_tools/1" do
    test "tracks role and status" do
      {provider, _} = start_session(role: :provider)

      assert MapSet.equal?(
               MapSet.new(JobSession.available_tools(provider)),
               MapSet.new([:set_budget, :send_message, :wait])
             )

      budget = AssetToken.usdc(0.1, 8453)
      {:ok, :budget_set} = JobSession.set_budget(provider, budget)

      assert JobSession.available_tools(provider) == [:set_budget]
    end
  end

  describe "expire/2" do
    test "from any non-terminal status; bypasses role gating" do
      {client, _} = start_session(role: :client, initial_status: :budget_set)
      ref = Process.monitor(client)

      assert {:ok, :expired} = JobSession.expire(client, "sla exceeded")
      assert_receive {:DOWN, ^ref, :process, ^client, :normal}, 500
    end
  end

  describe "apply_event/3 (observed system events)" do
    test "advances status, records a :system entry, and notifies subscribers" do
      {provider, job_id} = start_session(role: :provider)
      :ok = JobSession.subscribe(provider)

      assert {:ok, :budget_set} =
               JobSession.apply_event(provider, :budget_set, %{observed: true})

      assert JobSession.status(provider) == :budget_set

      assert Enum.any?(JobSession.entries(provider), fn e ->
               e.kind == :system and e.event == :budget_set and e.payload == %{observed: true}
             end)

      assert_receive {JobSession, {8453, ^job_id}, %{kind: :system, event: :budget_set}}, 500
    end

    test "forces a non-adjacent observed status, bypassing role gating and adjacency" do
      # A :client cannot :submit, and open -> submitted is not an adjacent
      # transition; an authoritative observed event applies it regardless
      # (e.g. an Agent connecting mid-stream sees the current status).
      {client, _} = start_session(role: :client)

      assert {:ok, :submitted} = JobSession.apply_event(client, :submitted)
      assert JobSession.status(client) == :submitted
    end

    test "stops the session on a terminal observed status" do
      {provider, _} = start_session(role: :provider)
      ref = Process.monitor(provider)

      assert {:ok, :completed} = JobSession.apply_event(provider, :completed, %{reason: "done"})
      assert_receive {:DOWN, ^ref, :process, ^provider, :normal}, 500
    end

    test "rejects an unknown status atom without changing state" do
      {provider, _} = start_session(role: :provider)

      assert {:error, {:unknown_status, :bogus}} = JobSession.apply_event(provider, :bogus)
      assert JobSession.status(provider) == :open
    end
  end
end
