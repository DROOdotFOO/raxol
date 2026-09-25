defmodule Raxol.Agent.Probe.Runner.PoolTest do
  # The pool is a named singleton that the async U12 red suite also submits to.
  # These tests restart it with a small retention cap, so they must not overlap
  # an async module: ExUnit runs sync modules only after every async one is done.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Probe.Runner
  alias Raxol.Agent.Probe.Runner.Pool
  alias Raxol.Agent.Red.ProbeRunnerLab.{CacheRideProbe, GatedProbe}

  setup do
    stop_pool()
    on_exit(&stop_pool/0)
  end

  defp stop_pool do
    case Process.whereis(Pool) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp start_pool!(opts) do
    {:ok, _pid} = Pool.start(opts)
    :ok
  end

  defp submit_opts(context \\ %{}) do
    test = self()
    [emit: &send(test, {:emitted, &1}), context: Map.merge(%{tip_offset: 1}, context)]
  end

  defp assert_terminal(run_id, status) do
    assert_receive {:emitted, %{kind: :probe_run, run_id: ^run_id, status: ^status}}, 5_000
  end

  defp complete! do
    {:ok, run_id} = Runner.submit("pool-test", CacheRideProbe, submit_opts())
    assert_terminal(run_id, :completed)
    run_id
  end

  describe "finished-run retention" do
    test "keeps at most :max_terminal_runs finished runs, evicting the oldest first" do
      start_pool!(max_terminal_runs: 2)

      [r1, r2, r3] = for _ <- 1..3, do: complete!()

      assert Runner.status(r1) == {:error, :not_found}
      assert Runner.kill(r1) == {:error, :not_found}
      assert Runner.status(r2) == {:ok, :completed}
      assert Runner.status(r3) == {:ok, :completed}

      r4 = complete!()

      assert Runner.status(r2) == {:error, :not_found}
      assert Runner.status(r3) == {:ok, :completed}
      assert Runner.status(r4) == {:ok, :completed}
    end

    test "a running run is never evicted; eviction follows the order runs finished" do
      start_pool!(max_terminal_runs: 1)

      {:ok, held} = Runner.submit("pool-test", GatedProbe, submit_opts(%{gate: self()}))
      assert_receive {:probe_gated, worker}, 5_000

      [r1, r2] = for _ <- 1..2, do: complete!()

      # `held` was submitted first, but it has not finished: only r1 goes.
      assert Runner.status(held) == {:ok, :running}
      assert Runner.status(r1) == {:error, :not_found}
      assert Runner.status(r2) == {:ok, :completed}

      send(worker, :release)
      assert_terminal(held, :completed)

      # `held` finished last, so it is now the newest finished run.
      assert Runner.status(held) == {:ok, :completed}
      assert Runner.status(r2) == {:error, :not_found}
    end

    test "start/1 rejects a :max_terminal_runs that is not a non-negative integer" do
      assert Pool.start(max_terminal_runs: -1) ==
               {:error, {:invalid_option, {:max_terminal_runs, -1}}}

      assert Process.whereis(Pool) == nil
    end
  end
end
