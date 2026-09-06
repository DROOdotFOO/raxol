defmodule Raxol.Agent.Actions.ShellJobsTest do
  @moduledoc """
  `Raxol.Agent.Shell.Jobs` against real OS processes.

  What is asserted here is lifecycle, not features: buffered output survives
  across polls, a killed job's whole tree is dead at the OS level, the running
  cap and the per-job output cap actually bind, a wall-clock timeout still
  reaps, and one working directory cannot see another's jobs. `ps` is the death
  oracle throughout (`Raxol.Agent.KillLab`) — never `:exit_status`, and never
  the absence of a port.

  Isolation comes from the owner key: every test gets its own temp directory,
  so no test can observe or reap another's jobs, and `on_exit` kills whatever
  it started.
  """

  use ExUnit.Case, async: true

  @moduletag :unix_only
  # Killing a pty tears the `script` process down as a consequence of killing
  # the session inside it, so the shared process-group helper legitimately logs
  # "no group under that id" for a pid that has already exited.
  @moduletag :capture_log

  alias Raxol.Agent.KillLab
  alias Raxol.Agent.Shell.Jobs
  alias Raxol.Agent.Shell.Pty

  @death_budget_ms 3_000
  @marker_budget_ms 2_000
  @poll_budget_ms 5_000

  setup do
    owner =
      Path.join(
        System.tmp_dir!(),
        "raxol-shell-jobs-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(owner)

    on_exit(fn ->
      Jobs.reap(owner)
      File.rm_rf(owner)
    end)

    %{owner: owner}
  end

  describe "output across turns" do
    test "a later poll returns only the bytes written since the cursor", %{owner: owner} do
      gate = Path.join(owner, "gate")

      {:ok, job} =
        Jobs.start(gated("echo one", gate, "echo two"), owner: owner, timeout_ms: 20_000)

      first = poll_until_output(job.job_id, owner)
      assert first.output == "one\n"
      assert first.cursor == byte_size("one\n")
      assert first.running

      File.write!(gate, "")

      assert {:ok, done} = Jobs.await(job.job_id, owner, 20_000)
      refute done.running
      assert done.status == "exited"
      assert done.exit_code == 0

      assert {:ok, tail} = Jobs.poll(job.job_id, owner, first.cursor)
      assert tail.output == "two\n"
      assert tail.cursor == byte_size("one\ntwo\n")
    end

    test "polling at the cursor is idempotent, and from 0 replays everything", %{owner: owner} do
      {:ok, job} = Jobs.start("echo hi", owner: owner, timeout_ms: 10_000)
      assert {:ok, _done} = Jobs.await(job.job_id, owner, 10_000)

      assert {:ok, read} = Jobs.poll(job.job_id, owner, 0)
      assert read.output == "hi\n"

      assert {:ok, again} = Jobs.poll(job.job_id, owner, read.cursor)
      assert again.output == ""
      assert again.cursor == read.cursor

      assert {:ok, replay} = Jobs.poll(job.job_id, owner, 0)
      assert replay.output == "hi\n"
    end

    test "a wait that expires reports the job still running instead of hanging", %{owner: owner} do
      gate = Path.join(owner, "gate")
      {:ok, job} = Jobs.start(gated("", gate, ""), owner: owner, timeout_ms: 20_000)

      assert {:ok, expired} = Jobs.await(job.job_id, owner, 100)
      assert expired.running
      assert expired.status == "running"
      assert expired.exit_code == nil

      File.write!(gate, "")
      assert {:ok, done} = Jobs.await(job.job_id, owner, 20_000)
      refute done.running
    end
  end

  describe "lifecycle safety" do
    test "killing a job kills the child it backgrounded, not just the shell", %{owner: owner} do
      marker = Path.join(owner, "child.pid")

      {:ok, job} =
        Jobs.start(backgrounds_a_child(marker), owner: owner, timeout_ms: 60_000)

      child = read_marker_pid(marker)
      assert KillLab.alive?(job.os_pid)

      assert {:ok, killed} = Jobs.kill(job.job_id, owner)
      assert killed.status == "killed"
      assert killed.killed
      refute killed.running

      assert KillLab.await_dead(job.os_pid, @death_budget_ms)

      assert KillLab.await_dead(child, @death_budget_ms),
             "backgrounded child #{child} survived shell_kill -- the group kill " <>
               "did not reach it (orphan leak)"
    end

    test "a wall-clock timeout reaps the tree and reports 124", %{owner: owner} do
      marker = Path.join(owner, "child.pid")

      {:ok, job} =
        Jobs.start(backgrounds_a_child(marker), owner: owner, timeout_ms: 400)

      child = read_marker_pid(marker)

      assert {:ok, done} = Jobs.await(job.job_id, owner, 20_000)
      assert done.status == "timed_out"
      assert done.exit_code == 124

      assert KillLab.await_dead(job.os_pid, @death_budget_ms)

      assert KillLab.await_dead(child, @death_budget_ms),
             "backgrounded child #{child} outlived the job's deadline"
    end

    test "killing an already-finished job is a no-op that still answers", %{owner: owner} do
      {:ok, job} = Jobs.start("exit 3", owner: owner, timeout_ms: 10_000)
      assert {:ok, done} = Jobs.await(job.job_id, owner, 10_000)
      assert done.exit_code == 3

      assert {:ok, killed} = Jobs.kill(job.job_id, owner)
      assert killed.status == "exited"
      assert killed.exit_code == 3
      refute killed.killed
    end

    test "reaping an owner kills its live jobs", %{owner: owner} do
      {:ok, job} = Jobs.start("sleep 300", owner: owner, timeout_ms: 60_000)
      os_pid = job.os_pid
      assert KillLab.alive?(os_pid)

      assert :ok = Jobs.reap(owner)

      assert KillLab.await_dead(os_pid, @death_budget_ms)
      assert Jobs.list(owner) == []
    end
  end

  describe "bounds" do
    test "the running cap is enforced and released when a job finishes", %{owner: owner} do
      gate = Path.join(owner, "gate")
      command = gated("", gate, "")

      started =
        for _ <- 1..Jobs.max_running() do
          assert {:ok, job} = Jobs.start(command, owner: owner, timeout_ms: 20_000)
          job
        end

      assert {:error, :job_limit_reached} =
               Jobs.start("echo refused", owner: owner, timeout_ms: 5_000)

      File.write!(gate, "")

      for job <- started do
        assert {:ok, done} = Jobs.await(job.job_id, owner, 20_000)
        refute done.running
      end

      # The cap counts RUNNING jobs, so finishing them frees the slots rather
      # than the entries retaining them forever.
      assert {:ok, _job} = Jobs.start("echo ok", owner: owner, timeout_ms: 5_000)
    end

    test "retained output is capped while the real byte count is still reported", %{owner: owner} do
      cap = Jobs.max_output_bytes()
      flood = cap * 2

      {:ok, job} =
        Jobs.start("yes raxol | head -c #{flood}", owner: owner, timeout_ms: 30_000)

      assert {:ok, done} = Jobs.await(job.job_id, owner, 30_000)
      refute done.running
      assert done.truncated

      # At least, not exactly: `yes` dies on SIGPIPE and some implementations
      # announce it on stderr, which `:stderr_to_stdout` folds into the count.
      # What matters is that the count is the command's real output and not the
      # buffer's size.
      assert done.output_bytes >= flood

      assert {:ok, read} = Jobs.poll(job.job_id, owner, 0)
      assert byte_size(read.output) == cap
    end
  end

  describe "owner scoping" do
    test "another working directory can neither read nor kill the job", %{owner: owner} do
      {:ok, job} = Jobs.start("sleep 300", owner: owner, timeout_ms: 60_000)
      other = owner <> "-other"

      assert {:error, :job_not_found} = Jobs.poll(job.job_id, other, 0)
      assert {:error, :job_not_found} = Jobs.await(job.job_id, other, 100)
      assert {:error, :job_not_found} = Jobs.kill(job.job_id, other)
      assert Jobs.list(other) == []

      # Still ours, and still alive: the refusal was a refusal, not a kill.
      assert KillLab.alive?(job.os_pid)
      assert [%{job_id: id}] = Jobs.list(owner)
      assert id == job.job_id
    end
  end

  describe "pty" do
    test "a pty job's command sees a terminal", %{owner: owner} do
      command = "if [ -t 1 ]; then echo TTY; else echo PIPE; fi"

      case Jobs.start(command, owner: owner, pty: true, timeout_ms: 20_000) do
        {:ok, job} ->
          assert job.pty
          assert {:ok, _done} = Jobs.await(job.job_id, owner, 20_000)
          assert {:ok, read} = Jobs.poll(job.job_id, owner, 0)

          assert read.output =~ "TTY"

          # A terminal, not a pipe: the line discipline translates NL to CR-LF.
          assert read.output =~ "\r\n"

        {:error, :pty_unavailable} ->
          refute Pty.available?(sh()),
                 "pty was refused on a host where Pty.available?/1 says yes"
      end
    end

    test "a pty job runs on pipes only if it was never granted a pty", %{owner: owner} do
      command = "if [ -t 1 ]; then echo TTY; else echo PIPE; fi"
      {:ok, job} = Jobs.start(command, owner: owner, timeout_ms: 20_000)

      refute job.pty
      assert {:ok, _done} = Jobs.await(job.job_id, owner, 20_000)
      assert {:ok, read} = Jobs.poll(job.job_id, owner, 0)
      assert read.output == "PIPE\n"
    end

    test "killing a pty job kills the session inside the pty", %{owner: owner} do
      if Pty.available?(sh()) do
        marker = Path.join(owner, "child.pid")

        {:ok, job} =
          Jobs.start(backgrounds_a_child(marker),
            owner: owner,
            pty: true,
            timeout_ms: 60_000
          )

        child = read_marker_pid(marker)

        assert {:ok, killed} = Jobs.kill(job.job_id, owner)
        assert killed.killed

        assert KillLab.await_dead(job.os_pid, @death_budget_ms)

        # `script` setsid's the command into its own session, so a group kill of
        # the port program alone would leave this alive. That is the regression.
        assert KillLab.await_dead(child, @death_budget_ms),
               "the process inside the pty survived shell_kill -- " <>
                 "Pty.inner_groups/1 did not name its session"
      end
    end
  end

  # -- command fixtures ------------------------------------------------------

  # Emits `before`, blocks until `gate` exists, emits `after_`. A file gate
  # rather than a sleep: the test decides when the job may proceed, so nothing
  # depends on how fast the machine is.
  defp gated(before, gate, after_) do
    [before, "while [ ! -f #{gate} ]; do sleep 0.05; done", after_]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
  end

  # Backgrounds a `sleep`, records its pid, then blocks in the foreground. Both
  # the shell and the detached child must die.
  defp backgrounds_a_child(marker),
    do: "sleep 300 & echo $! > #{marker}; wait"

  defp sh, do: System.find_executable("sh") || "/bin/sh"

  # -- polling helpers -------------------------------------------------------

  defp poll_until_output(id, owner, budget_ms \\ @poll_budget_ms)

  defp poll_until_output(id, _owner, budget_ms) when budget_ms <= 0 do
    flunk("job #{id} produced no output within the budget")
  end

  defp poll_until_output(id, owner, budget_ms) do
    assert {:ok, view} = Jobs.poll(id, owner, 0)

    if view.output == "" do
      Process.sleep(10)
      poll_until_output(id, owner, budget_ms - 10)
    else
      view
    end
  end

  defp read_marker_pid(marker, budget_ms \\ @marker_budget_ms)

  defp read_marker_pid(marker, budget_ms) when budget_ms <= 0 do
    flunk("background child never wrote its pid to #{marker}")
  end

  defp read_marker_pid(marker, budget_ms) do
    case File.read(marker) do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {pid, ""} -> pid
          _ -> retry_marker(marker, budget_ms)
        end

      _ ->
        retry_marker(marker, budget_ms)
    end
  end

  defp retry_marker(marker, budget_ms) do
    Process.sleep(10)
    read_marker_pid(marker, budget_ms - 10)
  end
end
