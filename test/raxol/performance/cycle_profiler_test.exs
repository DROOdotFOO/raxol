defmodule Raxol.Performance.CycleProfilerTest do
  use ExUnit.Case, async: true

  alias Raxol.Performance.CycleProfiler

  setup do
    name = :"profiler_test_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      CycleProfiler.start_link(
        name: name,
        max_entries: 100,
        slow_threshold_us: 1000
      )

    %{pid: pid}
  end

  describe "record_update/2" do
    test "records update timings", %{pid: pid} do
      CycleProfiler.record_update(pid, %{
        update_us: 500,
        message_summary: ":tick"
      })

      CycleProfiler.record_update(pid, %{
        update_us: 700,
        message_summary: ":key"
      })

      # Give casts time to process
      :timer.sleep(10)

      stats = CycleProfiler.stats(pid)
      assert stats.update.update_us.count == 2
      assert stats.update.update_us.avg == 600.0
    end
  end

  describe "record_render/2" do
    test "records render timings", %{pid: pid} do
      CycleProfiler.record_render(pid, %{
        view_us: 100,
        layout_us: 200,
        render_us: 300,
        plugin_us: 50,
        backend_us: 150,
        total_us: 800
      })

      :timer.sleep(10)

      stats = CycleProfiler.stats(pid)
      assert stats.render.total_us.count == 1
      assert stats.render.view_us.avg == 100.0
    end

    test "detects slow cycles", %{pid: pid} do
      CycleProfiler.record_render(pid, %{total_us: 500})
      CycleProfiler.record_render(pid, %{total_us: 2000})

      :timer.sleep(10)

      counts = CycleProfiler.counts(pid)
      assert counts.total == 2
      assert counts.slow == 1
    end

    test "returns slow cycle entries", %{pid: pid} do
      CycleProfiler.record_render(pid, %{total_us: 500})
      CycleProfiler.record_render(pid, %{total_us: 2000, view_us: 1500})

      :timer.sleep(10)

      slow = CycleProfiler.slow_cycles(pid)
      assert length(slow) == 1
      assert hd(slow).total_us == 2000
    end
  end

  describe "stats/1" do
    test "returns empty stats when no data", %{pid: pid} do
      stats = CycleProfiler.stats(pid)
      assert stats.total_cycles == 0
      assert stats.slow_cycles == 0
    end
  end

  describe "reset/1" do
    test "clears all recorded data", %{pid: pid} do
      CycleProfiler.record_update(pid, %{update_us: 100})
      CycleProfiler.record_render(pid, %{total_us: 2000})
      :timer.sleep(10)

      CycleProfiler.reset(pid)
      :timer.sleep(10)

      counts = CycleProfiler.counts(pid)
      assert counts.total == 0
      assert counts.slow == 0
    end
  end

  describe "export/2" do
    test "exports data to file", %{pid: pid} do
      CycleProfiler.record_render(pid, %{total_us: 100, view_us: 50})
      :timer.sleep(10)

      path =
        Path.join(
          System.tmp_dir!(),
          "profiler_test_#{System.unique_integer([:positive])}.bin"
        )

      assert :ok = CycleProfiler.export(pid, path)
      assert File.exists?(path)

      data = path |> File.read!() |> :erlang.binary_to_term()
      assert is_list(data.renders)
      assert length(data.renders) == 1

      File.rm(path)
    end
  end

  describe "subscribe/1" do
    test "notifies on slow cycles", %{pid: pid} do
      CycleProfiler.subscribe(pid)
      :timer.sleep(10)

      CycleProfiler.record_render(pid, %{total_us: 2000})

      assert_receive {:slow_cycle, entry}, 100
      assert entry.total_us == 2000
    end

    test "does not notify on fast cycles", %{pid: pid} do
      CycleProfiler.subscribe(pid)
      :timer.sleep(10)

      CycleProfiler.record_render(pid, %{total_us: 500})

      refute_receive {:slow_cycle, _}, 50
    end

    test "notifies a process that subscribed twice once", %{pid: pid} do
      CycleProfiler.subscribe(pid)
      CycleProfiler.subscribe(pid)
      CycleProfiler.record_render(pid, %{total_us: 2000})

      assert_receive {:slow_cycle, _}
      refute_receive {:slow_cycle, _}, 50
    end

    test "drops a subscriber that exits", %{pid: pid} do
      test = self()

      subscriber =
        spawn(fn ->
          CycleProfiler.subscribe(pid)
          # A call from the same process runs after the subscribe cast.
          _ = CycleProfiler.counts(pid)
          send(test, :subscribed)
          receive do: (:stop -> :ok)
        end)

      assert_receive :subscribed
      assert subscriber in :sys.get_state(pid).subscribers

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      refute subscriber in :sys.get_state(pid).subscribers
    end
  end
end
