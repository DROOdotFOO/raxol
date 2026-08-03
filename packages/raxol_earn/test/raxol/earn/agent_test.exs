defmodule Raxol.Earn.AgentTest do
  use ExUnit.Case, async: false

  alias Raxol.Earn.{Agent, JobSession, Transport, JobApi}

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(JobSession.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(JobSession.Supervisor, pid)
    end

    transport = Transport.Mock.new()
    api = JobApi.Mock.new(me: %{wallet_address: "0xdead", name: "Xochi"})

    {:ok, agent} =
      Agent.start_link(
        transport: transport,
        api: api,
        wallet_address: "0xdead",
        supported_chain_ids: [8453, 84_532],
        default_role: :provider
      )

    {:ok, agent: agent, transport: transport, api: api}
  end

  describe "start_stream/1" do
    test "connects the transport idempotently", %{agent: agent, transport: transport} do
      :ok = Agent.start_stream(agent)
      assert Transport.Mock.connected?(transport)
      # Idempotent
      :ok = Agent.start_stream(agent)
      assert Transport.Mock.connected?(transport)
    end

    test "stop_stream disconnects", %{agent: agent, transport: transport} do
      Agent.start_stream(agent)
      :ok = Agent.stop_stream(agent)
      refute Transport.Mock.connected?(transport)
    end
  end

  describe "discovery (JobApi pass-through)" do
    test "browse_agents/3 hits the api", %{agent: agent, api: api} do
      JobApi.Mock.put_agent(api, "0xfeed", %{name: "Other Solver"})

      assert {:ok, [%{name: "Other Solver"}]} = Agent.browse_agents(agent, "other")
    end

    test "get_agent/2 looks up by wallet", %{agent: agent, api: api} do
      JobApi.Mock.put_agent(api, "0xfeed", %{name: "Other"})

      assert {:ok, %{name: "Other"}} = Agent.get_agent(agent, "0xfeed")
      assert {:ok, nil} = Agent.get_agent(agent, "0xmissing")
    end

    test "get_address/1 returns the wallet", %{agent: agent} do
      assert Agent.get_address(agent) == "0xdead"
    end
  end

  describe "message passthrough" do
    test "send_message/4 records on the transport", %{agent: agent, transport: transport} do
      Agent.start_stream(agent)

      :ok = Agent.send_message(agent, {8453, "j1"}, "hi", "text")

      assert [{:send, {8453, "j1"}, "hi", "text"}] = Transport.Mock.sent(transport)
    end

    test "post_message/4 uses post path", %{agent: agent, transport: transport} do
      Agent.start_stream(agent)

      :ok = Agent.post_message(agent, {8453, "j1"}, "hi", "text")

      assert [{:post, {8453, "j1"}, "hi", "text"}] = Transport.Mock.sent(transport)
    end
  end

  describe "event routing" do
    test "first system entry spawns a JobSession and broadcasts to subscribers", %{
      agent: agent,
      transport: transport
    } do
      :ok = Agent.start_stream(agent)
      :ok = Agent.subscribe(agent)

      entry = %{
        "kind" => "system",
        "chainId" => 8453,
        "jobId" => "job-1",
        "event" => "job.created"
      }

      Transport.Mock.deliver(transport, entry)

      assert_receive {Agent, ^agent, session_pid, ^entry}, 200
      assert is_pid(session_pid)

      # Session is tracked.
      assert Agent.get_session(agent, {8453, "job-1"}) == session_pid
      assert Map.has_key?(Agent.sessions(agent), {8453, "job-1"})
    end

    test "subsequent entries with the same key reuse the same session", %{
      agent: agent,
      transport: transport
    } do
      Agent.start_stream(agent)
      Agent.subscribe(agent)

      e1 = %{"kind" => "system", "chainId" => 8453, "jobId" => "job-2", "event" => "job.created"}
      e2 = %{"kind" => "system", "chainId" => 8453, "jobId" => "job-2", "event" => "budget.set"}

      Transport.Mock.deliver(transport, e1)
      Transport.Mock.deliver(transport, e2)

      assert_receive {Agent, ^agent, pid1, ^e1}, 200
      assert_receive {Agent, ^agent, pid2, ^e2}, 200
      assert pid1 == pid2

      # Status mirrored into the session.
      assert JobSession.status(pid2) == :budget_set
    end

    test "different keys spawn distinct sessions", %{agent: agent, transport: transport} do
      Agent.start_stream(agent)
      Agent.subscribe(agent)

      e1 = %{"kind" => "system", "chainId" => 8453, "jobId" => "a", "event" => "job.created"}
      e2 = %{"kind" => "system", "chainId" => 84_532, "jobId" => "a", "event" => "job.created"}

      Transport.Mock.deliver(transport, e1)
      Transport.Mock.deliver(transport, e2)

      assert_receive {Agent, ^agent, p1, ^e1}, 200
      assert_receive {Agent, ^agent, p2, ^e2}, 200
      assert p1 != p2
    end

    test "message entries are propagated to JobSession.send_message/3", %{
      agent: agent,
      transport: transport
    } do
      Agent.start_stream(agent)
      Agent.subscribe(agent)

      sys = %{"kind" => "system", "chainId" => 8453, "jobId" => "msg-1", "event" => "job.created"}

      msg = %{
        "kind" => "message",
        "chainId" => 8453,
        "jobId" => "msg-1",
        "content" => "hello there",
        "contentType" => "text"
      }

      Transport.Mock.deliver(transport, sys)
      Transport.Mock.deliver(transport, msg)

      assert_receive {Agent, ^agent, session_pid, ^sys}, 200
      assert_receive {Agent, ^agent, ^session_pid, ^msg}, 200

      entries = JobSession.entries(session_pid)
      assert Enum.any?(entries, fn e -> e.kind == :message and e.content == "hello there" end)
    end

    test "terminal events drop the session from the registry", %{
      agent: agent,
      transport: transport
    } do
      Agent.start_stream(agent)
      Agent.subscribe(agent)

      key = {8453, "term-1"}

      seed = %{
        "kind" => "system",
        "chainId" => 8453,
        "jobId" => "term-1",
        "event" => "job.created"
      }

      Transport.Mock.deliver(transport, seed)
      assert_receive {Agent, ^agent, _, ^seed}, 200

      # Driving the session to a terminal status: send a job.completed event.
      done = %{
        "kind" => "system",
        "chainId" => 8453,
        "jobId" => "term-1",
        "event" => "job.completed"
      }

      Transport.Mock.deliver(transport, done)
      assert_receive {Agent, ^agent, _, ^done}, 200

      # The session stops itself; the agent's :DOWN handler drops it.
      eventually(fn -> Agent.get_session(agent, key) == nil end)
    end
  end

  describe "subscriber lifecycle" do
    test "dead subscribers are dropped", %{agent: agent} do
      subscriber =
        spawn(fn ->
          Agent.subscribe(agent)
          receive do: (:die -> :ok)
        end)

      Process.sleep(20)
      send(subscriber, :die)

      eventually(fn ->
        state = :sys.get_state(agent)
        not MapSet.member?(state.subscribers, subscriber)
      end)
    end
  end

  # -- Helpers --

  defp eventually(check, attempts \\ 50)
  defp eventually(_check, 0), do: flunk("condition did not become true within 1s")

  defp eventually(check, attempts) do
    if check.() do
      :ok
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
