defmodule Raxol.System.PortCommandTest do
  use ExUnit.Case, async: true

  alias Raxol.System.PortCommand

  # These exercise the real stdin -> command -> output/exit-status path against
  # POSIX utilities. The whole point of the module is to deliver the child's
  # exit status after feeding it stdin to EOF, which a plain Port.close could
  # not do, so the assertions are on real process exit codes.
  @moduletag :unix_only

  describe "run/4" do
    test "captures stdout and returns :ok on exit 0" do
      assert {:ok, "hello world"} = PortCommand.run("cat", [], "hello world")
    end

    test "handles empty stdin without hanging" do
      assert {:ok, ""} = PortCommand.run("cat", [], "")
    end

    test "returns :error with output on a non-zero exit" do
      # grep exits 1 when nothing matches
      assert {:error, ""} = PortCommand.run("grep", ["zzz"], "no match here\n")
    end

    test "returns :ok when a filtering command matches" do
      assert {:ok, "keep me\n"} =
               PortCommand.run("grep", ["keep"], "keep me\ndrop me\n")
    end

    test "passes arguments through argv, never re-parsed by the shell" do
      # A shell metacharacter in the input must reach the command literally,
      # proving the input is a data stream and not interpolated into a command.
      payload = "$(touch /tmp/raxol_portcmd_injection_probe); rm -rf /"
      assert {:ok, output} = PortCommand.run("cat", [], payload)
      assert output == payload
      refute File.exists?("/tmp/raxol_portcmd_injection_probe")
    end

    test "returns an error tuple for a missing command" do
      assert {:error, "command not found: raxol-nonexistent-xyz"} =
               PortCommand.run("raxol-nonexistent-xyz", [], "")
    end

    test "times out and reports failure without blocking indefinitely" do
      assert {:error, "timeout waiting for command"} =
               PortCommand.run("sleep", ["30"], "", timeout: 200)
    end

    test "kills the whole process tree on timeout, not just the direct child" do
      pidfile =
        Path.join(
          System.tmp_dir!(),
          "raxol_portcmd_pg_#{System.unique_integer([:positive])}"
        )

      File.rm(pidfile)

      # The shell records the pid of a BACKGROUNDED grandchild (`$!`) that sleeps
      # 30s, then waits. run/4 issues the kill INSIDE its timeout branch
      # (synchronously, before returning), so by the time it returns the group
      # has already been signalled -- no wall-clock race. A per-pid kill of the
      # shell would leave the grandchild alive; a process-GROUP kill reaps it.
      assert {:error, "timeout waiting for command"} =
               PortCommand.run(
                 "sh",
                 ["-c", "(sleep 30) & echo $! > #{pidfile}; wait"],
                 "",
                 timeout: 150
               )

      grandchild = await_pid(pidfile)

      # The group kill was issued synchronously in run/4; poll (up to ~1s) for
      # the grandchild to disappear. A per-pid kill would leave it sleeping 30s,
      # so it would still be alive when the budget runs out.
      dead? = await_dead(grandchild, 1000)

      # Safety net: never leak the 30s sleep if the group kill regressed.
      _ = System.cmd("kill", ["-9", grandchild], stderr_to_stdout: true)
      File.rm(pidfile)

      assert dead?,
             "the backgrounded grandchild survived the process-group kill"
    end

    test "does not leak stdin temp files" do
      before = temp_buffers()
      assert {:ok, _} = PortCommand.run("cat", [], "leak check")
      assert {:error, _} = PortCommand.run("sleep", ["30"], "", timeout: 200)
      assert temp_buffers() == before
    end
  end

  defp temp_buffers do
    System.tmp_dir!()
    |> Path.join("raxol_portcmd_*")
    |> Path.wildcard()
    |> Enum.sort()
  end

  # Poll until the shell has written the grandchild pid.
  defp await_pid(pidfile, tries \\ 200) do
    with {:ok, contents} <- File.read(pidfile),
         pid when pid != "" <- String.trim(contents) do
      pid
    else
      _ when tries > 0 ->
        Process.sleep(10)
        await_pid(pidfile, tries - 1)

      _ ->
        flunk("grandchild pid was never recorded in #{pidfile}")
    end
  end

  # Poll until `pid` is gone, or the budget is exhausted (still alive).
  defp await_dead(_pid, budget_ms) when budget_ms <= 0, do: false

  defp await_dead(pid, budget_ms) do
    if os_pid_alive?(pid) do
      Process.sleep(20)
      await_dead(pid, budget_ms - 20)
    else
      true
    end
  end

  defp os_pid_alive?(pid) do
    match?({_out, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  end
end
