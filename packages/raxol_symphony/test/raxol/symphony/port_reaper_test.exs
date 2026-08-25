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

  # Spelled out here rather than routed through `PortReaper`, so the oracle
  # cannot agree with the implementation by sharing its bug -- but through bash's
  # `kill` BUILTIN, because `kill(1)` is not an oracle at all on Linux. procps-ng
  # answers `kill -0 -<pgid>` with exit 0 whether or not the group exists, so an
  # oracle built on it reports every process alive forever and turns every
  # `refute alive?` red for the wrong reason.
  defp alive?(target) do
    {_out, status} =
      System.cmd(
        System.find_executable("bash"),
        ["-c", ~s(kill "$1" "$2"), "reaper-test-oracle", "-0", target],
        stderr_to_stdout: true
      )

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

    test "resolves the group when the parent has exited but its orphan holds the port open" do
      # The commonest leak shape: the hook backgrounds a child and exits. ERTS
      # withholds the exit status until the inherited stdout reaches EOF and the
      # orphan is still holding it, so the port stays OPEN while `Port.info/2`
      # goes on naming a pid that has already been reaped.
      #
      # Resolving the target off that pid -- asking `ps` for its pgid -- fails,
      # because `ps` cannot see a corpse. Resolving it off the process GROUP
      # succeeds, because the group is what is still running.
      port = open_child("( sleep 30 ) & echo ready; exit 0")
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      assert wait_until(fn -> not alive?("#{os_pid}") end),
             "the parent should have exited on its own"

      assert alive?("-#{os_pid}"), "the orphan should still hold the group"
      assert Port.info(port, :os_pid) == {:os_pid, os_pid}, "the port should still be open"

      assert {:group, ^os_pid} = target = PortReaper.capture(port)

      assert :ok = PortReaper.kill(target)
      assert wait_until(fn -> not alive?("-#{os_pid}") end)

      close(port)
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

      # Polled, not asserted outright: `await_exit/2` returns once the SIGKILL
      # has been ACCEPTED, and a killed group member stays in the group until it
      # is reaped, so the transition is not synchronous with the return.
      assert :ok = PortReaper.await_exit(target, @wait_ms)
      assert wait_until(fn -> not alive?("-#{pgid}") end)
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

    test "stands down when released by a process other than the owner" do
      # Holding the watcher pid is the authority to disarm it. Pinning the
      # release to the owner made `release/1` a silent no-op from anywhere else,
      # which leaves a watcher armed to SIGKILL a target the caller has already
      # reaped -- and `release/1` cannot report that it failed.
      test_pid = self()

      owner =
        spawn(fn ->
          port = open_child("echo ready; sleep 30")
          {:group, pgid} = target = PortReaper.capture(port)
          send(test_pid, {:spawned, pgid, PortReaper.watch(target)})
          Process.sleep(:infinity)
        end)

      assert_receive {:spawned, pgid, watcher}, @wait_ms

      # Released from the TEST process, not from `owner`.
      assert :ok = PortReaper.release(watcher)
      assert wait_until(fn -> not Process.alive?(watcher) end)

      Process.exit(owner, :kill)
      refute wait_until(fn -> not alive?("-#{pgid}") end, 500)

      PortReaper.kill({:group, pgid})
    end

    test "reaps when the watcher itself is shut down" do
      # An orchestrator restart tears the supervision tree down while its workers
      # are still alive, so the owner-death path never fires. A watcher that just
      # dies with the tree abandons the process tree it was covering.
      test_pid = self()

      owner =
        spawn(fn ->
          port = open_child("echo ready; sleep 30")
          {:group, pgid} = target = PortReaper.capture(port)
          send(test_pid, {:spawned, pgid, PortReaper.watch(target)})
          Process.sleep(:infinity)
        end)

      assert_receive {:spawned, pgid, watcher}, @wait_ms
      assert alive?("-#{pgid}")

      # What a supervisor sends a child on the way down. The owner stays alive
      # throughout, so only the shutdown path can account for the reap.
      Process.exit(watcher, :shutdown)

      assert wait_until(fn -> not alive?("-#{pgid}") end),
             "a watcher taken down with its tree still has to reap first"

      assert Process.alive?(owner)
      Process.exit(owner, :kill)
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
