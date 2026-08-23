defmodule Raxol.Symphony.PortReaperTest do
  @moduledoc """
  `Port.close/1` signals nothing, so what a port's child does next is the
  child's own business. These drive the behaviours that fall out of that,
  against real spawned processes:

    * a child that reads stdin exits on the EOF a close delivers
    * a child that does not read stdin ignores it entirely
    * a tool subprocess survives a parent that exited cleanly
    * an owner killed outright never runs its own cleanup

  Liveness is asked of the OS (`kill -0`) rather than inferred from a witness
  file, since the question is whether a process is still running, not whether it
  got as far as some side effect. Every wait is a poll against a deadline, not a
  fixed sleep, so a loaded machine makes these slower rather than red.
  """
  use ExUnit.Case, async: true

  alias Raxol.Symphony.PortReaper

  @wait_ms 5_000

  # Mirrors `Runners.Codex.Session.base_port_opts/0`: no `:in`, so stdin is a
  # live pipe and closing the port is what delivers EOF.
  #
  # `script` must `echo ready` once it has spawned whatever it is going to
  # spawn -- placed by the script, since where it goes is the point: a test of
  # orphaned subprocesses that proceeds before the fork proves nothing. Waiting
  # on that line rather than on a duration is what keeps these off the clock.
  defp open_child(script) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:line, 1_048_576},
          {:cd, System.tmp_dir!()},
          {:args, ["-lc", script]}
        ]
      )

    receive do
      {^port, {:data, {:eol, "ready"}}} -> port
    after
      @wait_ms -> flunk("child never signalled ready")
    end
  end

  # Resolved rather than hardcoded to /bin/kill, which slim images do not have.
  # Deliberately not the module's own resolution: a test oracle that shares the
  # implementation's lookup cannot catch the implementation losing it.
  defp kill_exe do
    System.find_executable("kill") || "/bin/kill"
  end

  defp alive?(target) do
    {_out, status} = System.cmd(kill_exe(), ["-0", target], stderr_to_stdout: true)
    status == 0
  end

  defp wait_until(fun, timeout_ms \\ @wait_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(fun, deadline)
  end

  defp poll_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        poll_until(fun, deadline)
    end
  end

  defp close(port) do
    PortReaper.close(port)
  end

  describe "capture/1" do
    test "reports the child as its own process group leader" do
      port = open_child("echo ready; sleep 30")

      assert {:group, pgid} = PortReaper.capture(port)
      assert {:os_pid, ^pgid} = Port.info(port, :os_pid)

      close(port)
      PortReaper.kill({:group, pgid})
    end

    test "is :none once the port is closed" do
      port = open_child("echo ready; sleep 30")
      target = PortReaper.capture(port)
      close(port)
      PortReaper.kill(target)

      assert PortReaper.capture(port) == :none
    end
  end

  describe "close/1" do
    test "is idempotent" do
      port = open_child("echo ready; sleep 30")
      target = PortReaper.capture(port)

      assert :ok = PortReaper.close(port)
      assert :ok = PortReaper.close(port)

      PortReaper.kill(target)
    end
  end

  describe "kill/1" do
    test "kills a child that never reads stdin" do
      port = open_child("echo ready; sleep 30")
      {:group, pgid} = target = PortReaper.capture(port)

      close(port)
      assert alive?("-#{pgid}"), "closing the port must not be what stops it"

      assert :ok = PortReaper.kill(target)
      assert wait_until(fn -> not alive?("-#{pgid}") end)
    end

    test "is a no-op for :none" do
      assert :ok = PortReaper.kill(:none)
    end

    # pid 0 is "my own process group" and pid 1 is "everything I may signal".
    # Turned into a group kill either one takes the VM or the host down, and
    # nothing about that failure is recoverable, so it is refused at the door
    # rather than trusted to only ever be reached via `capture/1`.
    test "refuses a target that would signal the VM or the world" do
      for pid <- [0, 1], kind <- [:group, :pid] do
        assert_raise FunctionClauseError, fn -> PortReaper.kill({kind, pid}) end
        assert_raise FunctionClauseError, fn -> PortReaper.await_exit({kind, pid}, 0) end
      end
    end
  end

  describe "await_exit/2" do
    test "reaps a tool subprocess that outlived a cleanly exited parent" do
      # The codex shape: the app-server exits on EOF, the tool it spawned does
      # not, and the group outlives its leader.
      port = open_child("( sleep 30 ) & echo ready; cat > /dev/null")
      {:group, pgid} = target = PortReaper.capture(port)

      close(port)

      assert wait_until(fn -> not alive?("#{pgid}") end),
             "the parent should have exited on EOF"

      assert alive?("-#{pgid}"), "the orphaned tool should still hold the group"

      assert :ok = PortReaper.await_exit(target, @wait_ms)
      refute alive?("-#{pgid}")
    end

    test "returns as soon as a well-behaved child exits, without spending the grace" do
      port = open_child("echo ready; cat > /dev/null")
      {:group, pgid} = target = PortReaper.capture(port)

      close(port)

      elapsed =
        wall_ms(fn ->
          assert :ok = PortReaper.await_exit(target, 30_000)
        end)

      assert wait_until(fn -> not alive?("-#{pgid}") end)

      # Bounded well under the grace: the point is that a clean exit is detected
      # rather than waited out. Generous enough not to be a timing race.
      assert elapsed < 10_000
    end

    test "is a no-op for :none" do
      assert :ok = PortReaper.await_exit(:none, 10_000)
    end
  end

  describe "watch/1" do
    test "reaps the target when the owner is killed outright" do
      # `Process.exit(pid, :kill)` does not run `try/after`, which is how the
      # orchestrator tears down workers -- so the reap cannot live in the owner.
      test_pid = self()

      owner =
        spawn(fn ->
          port = open_child("echo ready; sleep 30")
          {:group, pgid} = target = PortReaper.capture(port)
          PortReaper.watch(target)
          send(test_pid, {:spawned, pgid})
          Process.sleep(:infinity)
        end)

      assert_receive {:spawned, pgid}, @wait_ms
      assert alive?("-#{pgid}")

      Process.exit(owner, :kill)

      assert wait_until(fn -> not alive?("-#{pgid}") end),
             "the watcher must outlive the owner it is cleaning up after"
    end

    test "stands down after release/1" do
      test_pid = self()

      owner =
        spawn(fn ->
          port = open_child("echo ready; sleep 30")
          {:group, pgid} = target = PortReaper.capture(port)
          watcher = PortReaper.watch(target)
          PortReaper.release(watcher)
          send(test_pid, {:spawned, pgid, watcher})
          Process.sleep(:infinity)
        end)

      assert_receive {:spawned, pgid, watcher}, @wait_ms
      assert wait_until(fn -> not Process.alive?(watcher) end)

      Process.exit(owner, :kill)

      # A released watcher is gone, so nothing reaps: the caller took ownership.
      refute wait_until(fn -> not alive?("-#{pgid}") end, 500)

      PortReaper.kill({:group, pgid})
    end

    test "is a no-op for :none" do
      assert PortReaper.watch(:none) == :none
      assert PortReaper.release(:none) == :ok
      assert PortReaper.release(nil) == :ok
    end
  end

  defp wall_ms(fun) do
    started = System.monotonic_time(:millisecond)
    fun.()
    System.monotonic_time(:millisecond) - started
  end
end
