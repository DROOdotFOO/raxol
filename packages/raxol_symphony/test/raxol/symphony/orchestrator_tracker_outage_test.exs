defmodule Raxol.Symphony.OrchestratorTrackerOutageTest do
  @moduledoc """
  What a retry does when the tracker cannot answer.

  `retry_with_fresh_state/3` re-reads the issue before re-dispatching it. When
  that read fails the issue is neither known-active nor known-gone, so the retry
  is re-armed -- and that re-arm is the only retry path in the orchestrator that
  could skip the exponential backoff, freeze the attempt counter, and wrap the
  PREVIOUS recorded error instead of the current cause.

  The tracker is a real `Trackers.Linear` over a `Plug` stub (the seam
  `linear_test.exs` uses), because the Memory tracker cannot fail.
  """
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Orchestrator}
  alias Raxol.Symphony.Orchestrator.Retry
  alias Raxol.Symphony.Runners.Noop

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!(Noop.Director)
    Noop.Director.clear()
    on_exit(fn -> Application.delete_env(:raxol_symphony, :linear) end)
    :ok
  end

  @issue_id "iss_1"

  defp config(opts) do
    agent =
      %{max_concurrent_agents: 3, max_retry_backoff_ms: Keyword.fetch!(opts, :backoff)}
      |> put_if(:max_tracker_requeues, Keyword.get(opts, :max_tracker_requeues))

    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "linear",
          api_key: "lin_api_test",
          project_slug: "demo",
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done", "Cancelled"]
        },
        polling: %{interval_ms: 60_000},
        agent: agent,
        codex: %{stall_timeout_ms: 0},
        runner: %{kind: "noop"}
      },
      prompt_template: ""
    })
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  # Candidate polls filter by project and are answered normally; only the
  # per-ID refresh a retry does is under test, so each case supplies its own
  # responder for that leg.
  defp install_tracker(id_responder) do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      filter = get_in(Jason.decode!(body), ["variables", "filter"])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> respond(filter, id_responder)
    end

    Application.put_env(:raxol_symphony, :linear, plug: plug)
  end

  # A 500 is what `fetch_issue_states_by_ids/2` turns into
  # `{:error, {:linear_api_status, 500}}`.
  defp install_tracker_that_fails_id_lookups do
    install_tracker(fn conn -> Plug.Conn.send_resp(conn, 500, ~s({"message":"boom"})) end)
  end

  # A single-ID query answered with more than one issue. Linear maps every
  # returned node to an `Issue`, so the orchestrator gets a two-element list
  # back from a query it asked one ID for.
  defp install_tracker_that_answers_with(nodes) do
    install_tracker(fn conn ->
      Plug.Conn.send_resp(conn, 200, Jason.encode!(payload(nodes)))
    end)
  end

  defp respond(conn, %{"id" => _}, id_responder), do: id_responder.(conn)

  defp respond(conn, _project_filter, _id_responder) do
    Plug.Conn.send_resp(conn, 200, Jason.encode!(payload([node(@issue_id, "MT-1")])))
  end

  defp node(id, identifier, state \\ "Todo") do
    %{
      "id" => id,
      "identifier" => identifier,
      "title" => "Hello",
      "priority" => 2,
      "createdAt" => "2026-05-01T12:00:00Z",
      "updatedAt" => "2026-05-02T12:00:00Z",
      "state" => %{"name" => state},
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []}
    }
  end

  defp payload(nodes) do
    %{
      "data" => %{
        "issues" => %{
          "nodes" => nodes,
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
        }
      }
    }
  end

  defp start_orchestrator(config) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator, config: config, runner_module: Noop, auto_start_tick: false, name: nil},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp retry_entry(pid), do: Map.get(:sys.get_state(pid).retry_attempts, @issue_id)

  defp requeued?(pid) do
    match?(%{error: {:tracker_unavailable_during_retry, _}}, retry_entry(pid))
  end

  defp wait_until(timeout_ms \\ 3_000, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("wait_until timed out")

      true ->
        Process.sleep(10)
        do_wait_until(deadline, fun)
    end
  end

  test "an unreachable tracker backs the retry off instead of re-arming at the continuation delay" do
    install_tracker_that_fails_id_lookups()
    Noop.Director.set("MT-1", {:succeed_after, 0})

    pid = start_orchestrator(config(backoff: 60_000))
    :ok = Orchestrator.tick_now(pid)

    # The clean worker exit arms a continuation retry at attempt 1; when it
    # fires, the per-ID refresh 500s and the entry is re-armed.
    wait_until(fn -> requeued?(pid) end)

    entry = retry_entry(pid)
    remaining = entry.due_at_ms - System.monotonic_time(:millisecond)

    assert entry.requeues == 1,
           "the requeue must escalate its own counter, otherwise the backoff never grows; " <>
             "got #{inspect(entry.requeues)}"

    assert remaining > Retry.continuation_delay_ms(),
           "the requeue re-armed at the flat continuation delay instead of backing off; " <>
             "#{remaining}ms remaining"

    assert entry.error == {:tracker_unavailable_during_retry, {:linear_api_status, 500}},
           "the requeue must record the failure that caused it; got #{inspect(entry.error)}"
  end

  # The backoff has to grow across an outage, but growing it by incrementing
  # `attempt` conflates two different numbers: `attempt` is what reaches the
  # prompt template and the cast filename, so an agent that never ran once is
  # told it is on attempt 12 of a run that has not started.
  test "a tracker outage does not inflate the execution attempt the agent is told about" do
    install_tracker_that_fails_id_lookups()
    Noop.Director.set("MT-1", {:fail_after, 0, :boom})

    pid = start_orchestrator(config(backoff: 50))
    :ok = Orchestrator.tick_now(pid)

    wait_until(fn -> requeued?(pid) end)
    first = retry_entry(pid)

    wait_until(fn -> requeues_reached(pid, 3) end)
    later = retry_entry(pid)

    assert later.attempt == first.attempt,
           "a tracker outage must not move the execution attempt: the agent never ran. " <>
             "Went from #{inspect(first.attempt)} to #{inspect(later.attempt)}"

    assert later.requeues > first.requeues,
           "the outage counter must still escalate so the backoff grows; " <>
             "stuck at #{inspect(later.requeues)}"
  end

  test "repeated tracker failures do not nest the recorded error" do
    install_tracker_that_fails_id_lookups()
    Noop.Director.set("MT-1", {:fail_after, 0, :boom})

    # A 50ms ceiling keeps every backoff at 50ms, so two requeues are observable
    # without waiting out a real exponential delay.
    pid = start_orchestrator(config(backoff: 50))
    :ok = Orchestrator.tick_now(pid)

    wait_until(fn -> requeued?(pid) end)
    first = retry_entry(pid)

    wait_until(fn -> requeued?(pid) and retry_entry(pid).timer_ref != first.timer_ref end)

    second = retry_entry(pid)

    assert second.error == {:tracker_unavailable_during_retry, {:linear_api_status, 500}},
           "each requeue must wrap the current cause, not the previous entry's error; " <>
             "got #{inspect(second.error)}"
  end

  # Without a terminal give-up the requeue loop is unbounded: an indefinitely
  # unreachable tracker holds the claim forever, so the issue is in no running,
  # batch or paused map and `Candidate.eligible/4` skips it for good.
  test "an indefinitely unreachable tracker eventually releases the claim instead of holding it" do
    install_tracker_that_fails_id_lookups()
    Noop.Director.set("MT-1", {:fail_after, 0, :boom})

    pid = start_orchestrator(config(backoff: 50, max_tracker_requeues: 2))
    :ok = Orchestrator.tick_now(pid)

    wait_until(fn -> requeued?(pid) end)

    wait_until(fn -> retry_entry(pid) == nil end)

    state = :sys.get_state(pid)

    refute MapSet.member?(state.claimed, @issue_id),
           "giving up must release the claim, otherwise the issue is stranded: " <>
             "claimed but in no running, batch, paused or retry map"

    assert state.retry_attempts == %{},
           "giving up must not leave a timer behind; got #{inspect(state.retry_attempts)}"
  end

  # `retry_with_fresh_state/3` matched `{:ok, [issue]}`, `{:ok, []}` and
  # `{:error, _}` only, so a tracker answering a single-ID query with two rows
  # raised CaseClauseError inside the orchestrator's own callback.
  test "a single-ID query answered with two issues takes the matching row" do
    install_tracker_that_answers_with([
      node("iss_other", "MT-99"),
      node(@issue_id, "MT-1")
    ])

    Noop.Director.set("MT-1", {:succeed_after, 0})

    pid = start_orchestrator(config(backoff: 50))
    ref = Process.monitor(pid)
    :ok = Orchestrator.tick_now(pid)

    # Wait for the continuation retry to be ARMED before watching for its fire:
    # `retry_attempts` is empty at boot too, so waiting on the empty map alone
    # would pass before the ambiguous answer was ever read.
    wait_until(fn -> retry_entry(pid) != nil end)

    # `retry_with_fresh_state/3` runs in the orchestrator's own callback, so a
    # CaseClauseError on the two-row answer takes the whole orchestrator down.
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 2_500

    state = :sys.get_state(pid)

    assert MapSet.member?(state.claimed, @issue_id),
           "the row we asked for was in the answer, so the issue stays claimed"

    refute MapSet.member?(state.claimed, "iss_other"),
           "a row the query did not ask for must not be acted on as if it were ours"
  end

  test "a single-ID query answered only with rows it did not ask for is requeued, not released" do
    install_tracker_that_answers_with([node("iss_other", "MT-99")])

    Noop.Director.set("MT-1", {:succeed_after, 0})

    pid = start_orchestrator(config(backoff: 50))
    :ok = Orchestrator.tick_now(pid)

    wait_until(fn -> requeued?(pid) end)

    assert Process.alive?(pid)

    assert MapSet.member?(:sys.get_state(pid).claimed, @issue_id),
           "an answer that never mentions the issue says nothing about it, so the " <>
             "claim must be held and retried rather than released"
  end

  defp requeues_reached(pid, n) do
    match?(%{requeues: r} when r >= n, retry_entry(pid))
  end
end
