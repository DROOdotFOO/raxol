defmodule Raxol.Property.HeadlessMonitoringTest do
  @moduledoc """
  Property tests for the Headless GenServer's session cleanup state machine.

  Bug (#223): Headless uses start_link to create lifecycle processes, linking
  them to the GenServer. When a lifecycle exits, the link kills the GenServer
  before its Process.monitor :DOWN handler can fire. The fix is to unlink
  after start_link (or use start). These tests verify the :DOWN handler's
  state transformation is correct, independent of the process lifecycle.

  Tests the handle_info callback as a pure state transformation -- no real
  processes needed, deterministic, no race conditions.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log
  use ExUnitProperties

  import Raxol.Test.PropertyGenerators

  alias Raxol.Headless
  alias Raxol.Swarm.Discovery

  # -- Helpers --

  defp build_state(session_ids) do
    sessions =
      Map.new(session_ids, fn id ->
        pid = spawn(fn -> Process.sleep(:infinity) end)
        {id, %Headless.Session{id: id, lifecycle_pid: pid}}
      end)

    {%{sessions: sessions}, sessions}
  end

  defp cleanup_pids(sessions) do
    Enum.each(sessions, fn {_id, s} ->
      if Process.alive?(s.lifecycle_pid), do: Process.exit(s.lifecycle_pid, :kill)
    end)
  end

  # -- Property 10: :DOWN removes exactly the matching session --

  describe "handle_info :DOWN correctness (#223)" do
    property "removes exactly the matching session, preserves others" do
      check all(
              session_ids <- unique_session_ids_gen(2, 5),
              target_idx <- integer(0..100),
              max_runs: 300
            ) do
        target_idx = rem(target_idx, length(session_ids))
        target_id = Enum.at(session_ids, target_idx)

        {state, sessions} = build_state(session_ids)
        target_pid = sessions[target_id].lifecycle_pid

        {:noreply, new_state} =
          Headless.handle_info(
            {:DOWN, make_ref(), :process, target_pid, :normal},
            state
          )

        refute Map.has_key?(new_state.sessions, target_id),
               "session #{inspect(target_id)} should be removed after :DOWN"

        for id <- session_ids, id != target_id do
          assert Map.has_key?(new_state.sessions, id),
                 "session #{inspect(id)} should survive when #{inspect(target_id)} dies"
        end

        cleanup_pids(sessions)
      end
    end

    property ":DOWN for unknown pid leaves state unchanged" do
      check all(session_ids <- unique_session_ids_gen(1, 3), max_runs: 200) do
        {state, sessions} = build_state(session_ids)
        unknown_pid = spawn(fn -> :ok end)

        {:noreply, new_state} =
          Headless.handle_info(
            {:DOWN, make_ref(), :process, unknown_pid, :normal},
            state
          )

        assert new_state.sessions == state.sessions,
               ":DOWN for unknown pid should not modify sessions"

        cleanup_pids(sessions)
      end
    end
  end

  # -- Property 11: sequential :DOWN for all sessions --

  describe "sequential :DOWN cleanup" do
    property "all sessions removed after all :DOWN messages" do
      check all(session_ids <- unique_session_ids_gen(1, 6), max_runs: 200) do
        {state, sessions} = build_state(session_ids)

        final_state =
          Enum.reduce(session_ids, state, fn id, acc ->
            pid = sessions[id].lifecycle_pid

            {:noreply, new_acc} =
              Headless.handle_info(
                {:DOWN, make_ref(), :process, pid, :normal},
                acc
              )

            new_acc
          end)

        assert final_state.sessions == %{},
               "all sessions should be removed after all :DOWN messages, got #{inspect(Map.keys(final_state.sessions))}"

        cleanup_pids(sessions)
      end
    end

    property "session count decreases by exactly one per :DOWN" do
      check all(session_ids <- unique_session_ids_gen(2, 5), max_runs: 200) do
        {state, sessions} = build_state(session_ids)

        Enum.reduce(session_ids, state, fn id, acc ->
          before_count = map_size(acc.sessions)
          pid = sessions[id].lifecycle_pid

          {:noreply, new_acc} =
            Headless.handle_info(
              {:DOWN, make_ref(), :process, pid, :normal},
              acc
            )

          after_count = map_size(new_acc.sessions)

          assert after_count == before_count - 1,
                 "expected #{before_count - 1} sessions after :DOWN, got #{after_count}"

          new_acc
        end)

        cleanup_pids(sessions)
      end
    end
  end

  # -- Discovery :DOWN handler correctness --

  describe "Discovery handle_info :DOWN correctness" do
    test ":DOWN for cluster_pid sets it to nil" do
      cluster_pid = spawn(fn -> Process.sleep(:infinity) end)
      state = %{cluster_pid: cluster_pid, topologies: [:gossip]}

      {:noreply, new_state} =
        Discovery.handle_info(
          {:DOWN, make_ref(), :process, cluster_pid, :normal},
          state
        )

      assert new_state.cluster_pid == nil
      assert new_state.topologies == [:gossip]

      Process.exit(cluster_pid, :kill)
    end

    test ":DOWN for unrelated pid does not affect cluster_pid" do
      cluster_pid = spawn(fn -> Process.sleep(:infinity) end)
      other_pid = spawn(fn -> :ok end)
      state = %{cluster_pid: cluster_pid, topologies: []}

      {:noreply, new_state} =
        Discovery.handle_info(
          {:DOWN, make_ref(), :process, other_pid, :normal},
          state
        )

      assert new_state.cluster_pid == cluster_pid

      Process.exit(cluster_pid, :kill)
    end
  end
end
