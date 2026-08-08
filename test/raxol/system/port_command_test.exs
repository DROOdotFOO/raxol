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

    test "kills the timed-out command instead of orphaning it" do
      pidfile =
        Path.join(
          System.tmp_dir!(),
          "raxol_portcmd_pg_#{System.unique_integer([:positive])}"
        )

      File.rm(pidfile)

      # The command records its OWN pid (`echo $$`, which the `exec` keeps as the
      # port's os_pid) then sleeps 30s. run/4 kills it inside its timeout branch
      # SYNCHRONOUSLY (before returning), so by the time run/4 returns the signal
      # is delivered -- no wall-clock race. A bare Port.close would leave the
      # command running; the kill (group where the OS makes the port a group
      # leader, else per-pid) always reaps the command itself.
      assert {:error, "timeout waiting for command"} =
               PortCommand.run(
                 "sh",
                 ["-c", "echo $$ > #{pidfile}; exec sleep 30"],
                 "",
                 timeout: 150
               )

      pid = await_pid(pidfile)
      dead? = await_dead(pid, 2000)
      residue = if dead?, do: nil, else: reap(pid)
      File.rm(pidfile)

      assert dead?, "the timed-out command was orphaned (ps state: #{residue})"
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

  # `kill -0` cannot tell a live process from a ZOMBIE, and a just-killed child
  # stays a zombie until the BEAM reaps it -- so a signal-based oracle reports a
  # successfully killed command as still alive, which is the platform-dependence
  # that got this test tagged out of every executor. `ps -o state=` distinguishes
  # them: a leading Z is a corpse, which is what a delivered kill looks like.
  defp os_pid_alive?(pid) do
    case ps_state(pid) do
      "gone" -> false
      state -> not String.starts_with?(state, "Z")
    end
  end

  defp ps_state(pid) do
    with {out, 0} <-
           System.cmd("ps", ["-o", "state=", "-p", pid], stderr_to_stdout: true),
         state when state != "" <- String.trim(out) do
      state
    else
      _ -> "gone"
    end
  end

  # Never leak the 30s sleep if the kill regressed, but record what the orphan
  # was doing first so the failure names a state instead of just "still alive".
  defp reap(pid) do
    state = ps_state(pid)
    _ = System.cmd("kill", ["-9", pid], stderr_to_stdout: true)
    state
  end
end
