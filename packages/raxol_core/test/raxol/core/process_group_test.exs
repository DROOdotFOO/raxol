defmodule Raxol.Core.ProcessGroupTest do
  @moduledoc """
  Driven against real spawned processes, because every claim this module makes
  is a claim about the OS. Liveness is asked of the kernel (`kill -0`) rather
  than inferred from a witness file: the question is whether a process is still
  running, not whether it got as far as some side effect.

  Every wait is a poll against a deadline, never a fixed sleep, so a loaded
  machine makes these slower rather than red.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.ProcessGroup

  @moduletag :unix_only

  @wait_ms 5_000

  # `script` must `echo ready` once it has spawned whatever it is going to spawn.
  # Placed by the script because where it goes is the point: a test of orphaned
  # subprocesses that proceeds before the fork proves nothing.
  defp open_child(script) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:line, 65_536},
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

  defp os_pid(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    os_pid
  end

  # Spelled out rather than routed through `ProcessGroup`, so the oracle cannot
  # agree with the implementation by sharing its bug -- but through bash's `kill`
  # BUILTIN, because `kill(1)` is not an oracle at all on Linux. procps-ng
  # answers `kill -0 -<pgid>` with exit 0 whether or not the group exists, so an
  # oracle built on it reports every process alive forever.
  defp alive?(target) do
    {_out, status} =
      System.cmd(
        System.find_executable("bash"),
        ["-c", ~s(kill "$1" "$2"), "oracle", "-0", target],
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

  describe "resolve/1" do
    test "reports a spawned child as its own process group leader" do
      port = open_child("echo ready; sleep 30")
      pid = os_pid(port)

      assert {:group, ^pid} = ProcessGroup.resolve(pid)

      ProcessGroup.signal({:group, pid}, "-KILL")
    end

    test "resolves the group when the parent is a corpse but its orphan holds it" do
      # The topology a `ps`-based pgid read cannot answer: the parent has exited
      # and been reaped, so `ps -o pgid= -p <corpse>` is empty, while the group
      # it led is still running. This is the case the whole probe exists for.
      port = open_child("( sleep 30 ) & echo ready; exit 0")
      pid = os_pid(port)

      assert wait_until(fn -> not alive?("#{pid}") end), "the parent should have exited"
      assert alive?("-#{pid}"), "the orphan should still hold the group"

      assert {:group, ^pid} = ProcessGroup.resolve(pid)

      ProcessGroup.signal({:group, pid}, "-KILL")
    end

    test "falls back to the bare pid when no group answers under that id" do
      # The narrow target is the safe direction: it loses the descendants, where
      # a group kill aimed at a group that is not ours is unrecoverable. It is
      # also why the VM's own group is unreachable here -- a child that leads no
      # group sits in the BEAM's group, whose id is never the child's pid, so
      # the probe finds nothing and this branch is taken.
      port = open_child("echo ready; sleep 30")
      pid = os_pid(port)
      {:group, _} = ProcessGroup.resolve(pid)

      ProcessGroup.signal({:group, pid}, "-KILL")
      assert wait_until(fn -> not alive?("-#{pid}") end)

      assert {:pid, ^pid} = ProcessGroup.resolve(pid)
    end

    test "is :none for a pid that could never be a child" do
      # 0 is "my own process group" and 1 is "everything I may signal". Turned
      # into a group kill either takes the VM or the host down.
      assert ProcessGroup.resolve(0) == :none
      assert ProcessGroup.resolve(1) == :none
    end
  end

  describe "group_leader?/1" do
    test "true for a live leader, false once its group has drained" do
      port = open_child("echo ready; sleep 30")
      pid = os_pid(port)

      assert ProcessGroup.group_leader?(pid)

      ProcessGroup.signal({:group, pid}, "-KILL")
      assert wait_until(fn -> not alive?("-#{pid}") end)

      refute ProcessGroup.group_leader?(pid)
    end
  end

  describe "signal/3" do
    test "a group kill reaches the descendants, not just the child" do
      port = open_child("( sleep 30 ) & echo ready; sleep 30")
      pid = os_pid(port)

      assert :ok = ProcessGroup.signal({:group, pid}, "-KILL")
      assert wait_until(fn -> not alive?("-#{pid}") end)
    end

    test "reports :gone rather than :ok when nothing is left" do
      port = open_child("echo ready; sleep 30")
      pid = os_pid(port)
      target = {:group, pid}

      ProcessGroup.signal(target, "-KILL")
      assert wait_until(fn -> not alive?("-#{pid}") end)

      assert :gone = ProcessGroup.signal(target, "-0")
    end

    test "an unrecognised failure is an error, never :gone" do
      # The failure this inversion exists to prevent: `true` exits 0 for
      # everything and `false` exits 1 with no output at all. Neither says the
      # target exited, and reporting `:gone` for the second would tell a caller
      # a reap succeeded right before it deletes the target's workspace.
      port = open_child("echo ready; sleep 30")
      pid = os_pid(port)

      false_bin = System.find_executable("false")

      assert {:error, :unknown} =
               ProcessGroup.signal({:group, pid}, "-0", shell: false_bin)

      ProcessGroup.signal({:group, pid}, "-KILL")
    end

    test "is :gone for :none and refuses a target that would signal the world" do
      assert ProcessGroup.signal(:none, "-KILL") == :gone

      for pid <- [0, 1], kind <- [:group, :pid] do
        assert_raise FunctionClauseError, fn -> ProcessGroup.signal({kind, pid}, "-KILL") end
        assert_raise FunctionClauseError, fn -> ProcessGroup.await_gone({kind, pid}, 0) end
      end
    end
  end

  describe "await_gone/3" do
    test "returns as soon as the group drains, without spending the budget" do
      port = open_child("echo ready; cat > /dev/null")
      pid = os_pid(port)
      target = ProcessGroup.resolve(pid)

      Port.close(port)

      started = System.monotonic_time(:millisecond)
      assert :ok = ProcessGroup.await_gone(target, 30_000)
      elapsed = System.monotonic_time(:millisecond) - started

      # Bounded well under the budget: the point is that a clean exit is
      # detected rather than waited out. Generous enough not to be a race.
      assert elapsed < 10_000
    end

    test ":timeout is a distinct answer from an error" do
      # The caller's cue to stop asking and SIGKILL. Reporting it as an error
      # would make "still running after the grace" look like "could not tell".
      port = open_child("echo ready; sleep 30")
      pid = os_pid(port)
      target = ProcessGroup.resolve(pid)

      assert :timeout = ProcessGroup.await_gone(target, 100)

      ProcessGroup.signal(target, "-KILL")
    end

    test "is :ok for :none" do
      assert :ok = ProcessGroup.await_gone(:none, 10_000)
    end
  end
end
