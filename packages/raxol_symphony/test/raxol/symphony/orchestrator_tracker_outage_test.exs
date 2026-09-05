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

  defp config(max_retry_backoff_ms) do
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
        agent: %{max_concurrent_agents: 3, max_retry_backoff_ms: max_retry_backoff_ms},
        codex: %{stall_timeout_ms: 0},
        runner: %{kind: "noop"}
      },
      prompt_template: ""
    })
  end

  # Candidate polls filter by project and are answered; the per-ID refresh a
  # retry does is answered with 500, which is what `fetch_issue_states_by_ids/2`
  # turns into `{:error, {:linear_api_status, 500}}`.
  defp install_tracker_that_fails_id_lookups do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      filter = get_in(Jason.decode!(body), ["variables", "filter"])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> respond(filter)
    end

    Application.put_env(:raxol_symphony, :linear, plug: plug)
  end

  defp respond(conn, %{"id" => _}), do: Plug.Conn.send_resp(conn, 500, ~s({"message":"boom"}))

  defp respond(conn, _project_filter) do
    Plug.Conn.send_resp(conn, 200, Jason.encode!(candidates_payload()))
  end

  defp candidates_payload do
    node = %{
      "id" => @issue_id,
      "identifier" => "MT-1",
      "title" => "Hello",
      "priority" => 2,
      "createdAt" => "2026-05-01T12:00:00Z",
      "updatedAt" => "2026-05-02T12:00:00Z",
      "state" => %{"name" => "Todo"},
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []}
    }

    %{
      "data" => %{
        "issues" => %{
          "nodes" => [node],
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

    pid = start_orchestrator(config(60_000))
    :ok = Orchestrator.tick_now(pid)

    # The clean worker exit arms a continuation retry at attempt 1; when it
    # fires, the per-ID refresh 500s and the entry is re-armed.
    wait_until(fn -> requeued?(pid) end)

    entry = retry_entry(pid)
    remaining = entry.due_at_ms - System.monotonic_time(:millisecond)

    assert entry.attempt == 2,
           "the requeue must escalate the attempt, otherwise the backoff never grows; " <>
             "got #{inspect(entry.attempt)}"

    assert remaining > Retry.continuation_delay_ms(),
           "the requeue re-armed at the flat continuation delay instead of backing off; " <>
             "#{remaining}ms remaining"

    assert entry.error == {:tracker_unavailable_during_retry, {:linear_api_status, 500}},
           "the requeue must record the failure that caused it; got #{inspect(entry.error)}"
  end

  test "repeated tracker failures do not nest the recorded error" do
    install_tracker_that_fails_id_lookups()
    Noop.Director.set("MT-1", {:fail_after, 0, :boom})

    # A 50ms ceiling keeps every backoff at 50ms, so two requeues are observable
    # without waiting out a real exponential delay.
    pid = start_orchestrator(config(50))
    :ok = Orchestrator.tick_now(pid)

    wait_until(fn -> requeued?(pid) end)
    first = retry_entry(pid)

    wait_until(fn -> requeued?(pid) and retry_entry(pid).timer_ref != first.timer_ref end)

    second = retry_entry(pid)

    assert second.error == {:tracker_unavailable_during_retry, {:linear_api_status, 500}},
           "each requeue must wrap the current cause, not the previous entry's error; " <>
             "got #{inspect(second.error)}"
  end
end
