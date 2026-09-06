defmodule Raxol.Agent.Actions.ShellTest do
  @moduledoc """
  Regression spec for `Raxol.Agent.Actions.Shell` -- in particular the
  wall-clock timeout path, which used to close only the BEAM's side of the
  `Port` (`Port.close/1`) and leave the spawned OS process (and anything it
  forked) running detached. `Port.info/1` + `ps` verify the OS process is
  ACTUALLY dead, never trusting `:exit_status` or its absence.
  """

  use ExUnit.Case, async: true

  @moduletag :unix_only

  alias Raxol.Agent.Actions.Shell

  describe "baseline correctness" do
    test "runs a command and returns its combined output + exit code" do
      assert {:ok, result} = Shell.run(%{command: "echo hi"}, %{})
      assert result.output == "hi\n"
      assert result.exit_code == 0
      assert result.timed_out == false
      assert result.killed == false
    end

    test "a non-zero exit is reported honestly" do
      assert {:ok, result} = Shell.run(%{command: "exit 7"}, %{})
      assert result.exit_code == 7
      assert result.timed_out == false
    end

    test "a command that reads stdin sees EOF instead of an open pipe" do
      # Nothing ever writes to this port, so an inherited write pipe carries
      # nothing and only signals "more input is coming". Without `:in`, `cat`
      # blocks until the deadline and the tool reports a timeout it never
      # earned. The short timeout keeps the regression cheap to observe.
      assert {:ok, result} = Shell.run(%{command: "cat", timeout_ms: 2_000}, %{})

      assert result.exit_code == 0
      assert result.timed_out == false
    end
  end

  describe "wall-clock timeout kills the OS process group" do
    test "the captured os_pid is dead shortly after a timeout fires" do
      test_pid = self()

      sink = fn
        %{os_pid: os_pid} -> send(test_pid, {:os_pid, os_pid})
        nil -> :ok
      end

      assert {:ok, result} =
               Shell.run(
                 %{command: "sleep 5", timeout_ms: 150},
                 %{shell_tool_ref_sink: sink}
               )

      assert result.timed_out == true
      # A real OS-level kill landed -- `killed:` is now truthful, not the
      # old hardcoded `false` for every timeout.
      assert result.killed == true

      assert_receive {:os_pid, os_pid}, 1_000
      assert is_integer(os_pid)

      assert eventually_dead?(os_pid),
             "os_pid #{os_pid} (sleep 5, timeout 150ms) still alive -- " <>
               "Port.close/1 alone does not reap the OS process"
    end

    test "a background CHILD spawned by the command is also killed, not orphaned" do
      marker =
        Path.join(
          System.tmp_dir!(),
          "raxol-shell-timeout-child-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm(marker) end)

      test_pid = self()

      sink = fn
        %{os_pid: os_pid} -> send(test_pid, {:os_pid, os_pid})
        nil -> :ok
      end

      # Backgrounds a child `sleep`, records its pid to `marker`, then blocks
      # in the foreground well past the timeout -- so BOTH the shell (or
      # whatever it execs into) and its detached child must die.
      command = "sleep 5 & echo $! > #{marker}; wait"

      assert {:ok, result} =
               Shell.run(
                 %{command: command, timeout_ms: 200},
                 %{shell_tool_ref_sink: sink}
               )

      assert result.timed_out == true
      assert_receive {:os_pid, shell_os_pid}, 1_000

      child_pid = read_marker_pid(marker)

      assert eventually_dead?(shell_os_pid),
             "shell os_pid #{shell_os_pid} still alive after timeout"

      assert eventually_dead?(child_pid),
             "background child pid #{child_pid} survived the timeout -- " <>
               "the process-group kill did not reach it (orphan leak)"
    end
  end

  describe "pty" do
    test "the command sees a terminal, and says so in the result" do
      command = "if [ -t 1 ]; then echo TTY; else echo PIPE; fi"

      case Shell.run(%{command: command, pty: true, timeout_ms: 10_000}, %{}) do
        {:ok, result} ->
          assert result.pty == true
          assert result.exit_code == 0
          assert result.output =~ "TTY"
          # A terminal, not a pipe: the line discipline translates NL to CR-LF.
          assert result.output =~ "\r\n"

        {:error, :pty_unavailable} ->
          refute Raxol.Agent.Shell.Pty.available?(System.find_executable("sh") || "/bin/sh"),
                 "pty was refused on a host where Pty.available?/1 says yes"
      end
    end

    test "without pty the command gets pipes, and says so" do
      command = "if [ -t 1 ]; then echo TTY; else echo PIPE; fi"

      assert {:ok, result} = Shell.run(%{command: command}, %{})
      assert result.pty == false
      assert result.output == "PIPE\n"
    end
  end

  # -- helpers -----------------------------------------------------------

  defp read_marker_pid(marker, budget_ms \\ 1_000)

  defp read_marker_pid(marker, budget_ms) when budget_ms <= 0 do
    flunk("background child never wrote its pid to #{marker}")
  end

  defp read_marker_pid(marker, budget_ms) do
    case File.read(marker) do
      {:ok, content} when content != "" ->
        content |> String.trim() |> String.to_integer()

      _ ->
        Process.sleep(20)
        read_marker_pid(marker, budget_ms - 20)
    end
  end

  defp eventually_dead?(os_pid, budget_ms \\ 3_000)

  defp eventually_dead?(_os_pid, budget_ms) when budget_ms <= 0, do: false

  defp eventually_dead?(os_pid, budget_ms) do
    if os_alive?(os_pid) do
      Process.sleep(25)
      eventually_dead?(os_pid, budget_ms - 25)
    else
      true
    end
  end

  defp os_alive?(os_pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line -> not String.starts_with?(String.trim(line), "Z") end)

      _ ->
        false
    end
  end
end
