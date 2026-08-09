defmodule Raxol.Agent.ClientProtocol.ParentWatchTest do
  @moduledoc """
  Burrito's launcher forks the BEAM and does not forward signals. Kill the
  launcher pid alone and the BEAM keeps running with the provider credential:
  no signal reaches it, and stdin stays open because the client's end of the
  pipe is untouched. Reproduced against the released binary before this
  existed.

  The two shutdowns that already worked stay covered by their own paths -- a
  group signal reaches the BEAM directly, EOF on stdin ends the turn loop --
  so what is tested here is only the third case: the parent changed.

  The ppid reader is injected, so none of this depends on actually orphaning a
  process.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.ClientProtocol.ParentWatch

  defp start(ppid_fun, opts \\ []) do
    test = self()

    ParentWatch.start_link(
      [
        name: :"parent_watch_#{System.unique_integer([:positive])}",
        ppid_fun: ppid_fun,
        interval_ms: 5,
        on_orphan: fn -> send(test, :orphaned) end
      ] ++ opts
    )
  end

  test "a stable parent keeps the watcher running and quiet" do
    {:ok, pid} = start(fn -> {:ok, 42} end)

    refute_receive :orphaned, 60
    assert Process.alive?(pid)
  end

  test "a changed parent fires once and stops" do
    counter = :counters.new(1, [])

    {:ok, pid} =
      start(fn ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) > 2, do: {:ok, 1}, else: {:ok, 42}
      end)

    # Monitor before it can fire: the watcher stops promptly after orphaning,
    # so monitoring afterwards races and reports :noproc.
    ref = Process.monitor(pid)

    assert_receive :orphaned, 500
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 500
  end

  # A transient read failure must not kill a healthy session: readable at boot,
  # unreadable afterwards.
  test "an unreadable parent is waited out, not treated as death" do
    counter = :counters.new(1, [])

    {:ok, pid} =
      start(fn ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == 1, do: {:ok, 42}, else: :error
      end)

    refute_receive :orphaned, 80
    assert Process.alive?(pid)
  end

  # A watchdog that cannot see its subject would fire constantly or never;
  # refusing to start says so instead of pretending to guard.
  test "it refuses to start when the parent cannot be read at boot" do
    assert :ignore = start(fn -> :error end)
  end

  describe "read_ppid/0" do
    test "returns this process's real parent" do
      assert {:ok, ppid} = ParentWatch.read_ppid()
      assert is_integer(ppid) and ppid > 0
    end
  end
end
