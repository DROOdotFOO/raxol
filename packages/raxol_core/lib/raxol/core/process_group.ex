defmodule Raxol.Core.ProcessGroup do
  @moduledoc """
  Safely signal the OS process group behind a spawned child.

  Killing only a child leaves its descendants running: still doing work, still
  holding whatever fds they inherited. Killing its process GROUP reaches them.
  The catch is that a group kill aimed at the wrong id is unrecoverable -- a
  child that is not a group leader shares the BEAM's own group, and
  `kill -KILL -<pgid>` against that takes the VM down with it.

  So a target is RESOLVED before it is signalled. `resolve/1` answers
  `{:group, pgid}` only when it can show a group under that id exists, and
  `{:pid, os_pid}` (which loses the descendants, and says so) when it cannot.

  ## Why the group is probed rather than read

  A process group's id is the pid of its leader, and that pid stays allocated
  for as long as the group has ANY member. So "group `os_pid` answers a signal"
  can only be true if the process holding pid `os_pid` led it.

  The obvious alternative -- ask `ps` for the child's pgid and require
  `pgid == os_pid` -- cannot answer the case that matters most. When a child
  backgrounds something and exits, the parent is a corpse and `ps` cannot see
  it, so the pgid read fails and the group is never found. That is exactly the
  case where a group is still running and needs reaping, and the ppid-walk
  fallback misses it too: a reparented orphan's ppid is already `1`. `ps` is
  also absent on busybox.

  ## Why signals go through a shell builtin

  Never `kill(1)`. procps-ng's `kill` -- `/usr/bin/kill` on Debian and Ubuntu --
  takes a negative pid in its own argv slot, does NOTHING with it, and exits 0.
  Measured on linux/aarch64 with the group live: `System.cmd(kill,
  ["-KILL", "-57"])` returned `{"", 0}` and both members were still running.
  That is the worst failure available here, a reap that reports success and
  reaps nothing. `kill -s KILL -- -57` is no way out either: procps has no `--`
  and answers with a usage error. macOS's `/bin/kill` handles the same argv
  correctly, which is why this class of bug is green on a developer machine and
  red on Linux CI.

  Shell builtins are POSIX about negative pids on both.

  ## Callers

  `Raxol.Symphony.PortReaper` (port children, with an owner-death watcher) and
  `Raxol.Agent.Interrupt` (the shell tool's staged TERM/KILL escalation). Both
  used to carry their own copy of this; they disagreed, and the `ps`-based one
  had the corpse-parent hole described above.

  This module deliberately does NOT cover zombie-aware liveness. `kill -0`
  answers "is this pid still allocated", and a zombie still holds its pid, so a
  caller that needs to distinguish "exited but unreaped" from "running" needs a
  `ps`-based oracle instead -- which is why `Interrupt` keeps one.
  """

  require Logger

  @typedoc """
  What may safely be signalled.

  `{:group, pgid}` when the child leads its own process group, so its
  descendants come with it. `{:pid, os_pid}` when it does not, in which case
  only the child itself can be signalled. `:none` when there is nothing to
  signal.
  """
  @type target :: {:group, pos_integer()} | {:pid, pos_integer()} | :none

  @typedoc """
  Why a signal could not be delivered.

  NONE of these may be reported as success: a caller about to delete the
  target's working directory is relying on the difference.

  `:unavailable` -- no shell to signal with, so nothing was verified and nothing
  was killed.

  `:refused` -- the kernel rejected the signal (EPERM). The target is
  demonstrably still there, and still running.

  `:spawn_failed` -- the shell resolved but could not be run this time.
  Transient by nature (a fork that hit `EAGAIN` under process-table pressure is
  the case that matters, and that pressure is exactly when a reaper is most
  needed), so callers retry it rather than answering it.

  `:unknown` -- the signal failed with something unrecognised. NOT reported as
  `:gone`: "the message was not one I know" is not evidence that the target
  exited.
  """
  @type reason :: :unavailable | :refused | :spawn_failed | :unknown

  @typedoc """
  * `:shell` -- shell to deliver signals through. Defaults to `bash` on PATH.
    Honoured by `signal/3` and `await_gone/3` only; `resolve/1` always uses the
    real shell, so an injected failing shell simulates a failing KILL without
    also corrupting the target it is aimed at.
  """
  @type opts :: [shell: String.t() | nil]

  # A pid of 0 means "my own process group" and 1 means "everything I am allowed
  # to signal". Neither is ever a spawned child, and either one turned into a
  # group kill takes the VM (or the host) with it. `resolve/1` cannot produce
  # them, but the signalling functions are public and this module exists
  # precisely to not assume that.
  defguard is_signallable(target)
           when is_tuple(target) and tuple_size(target) == 2 and
                  elem(target, 0) in [:group, :pid] and
                  is_integer(elem(target, 1)) and elem(target, 1) > 1

  @poll_ms 50

  @doc """
  Resolve the safe signal target for a spawned child's OS pid.

  `{:group, os_pid}` when a process group under that id answers a signal, which
  can only be true if this child led it. `{:pid, os_pid}` otherwise -- safe, but
  it silently drops the descendants, so it is logged.

  Always uses the real shell, never an injected one: this decides WHAT gets
  signalled, and a wrong answer here is the unrecoverable failure.
  """
  @spec resolve(pos_integer()) :: target()
  def resolve(os_pid) when is_integer(os_pid) and os_pid > 1 do
    case signal({:group, os_pid}, "-0", shell: nil) do
      :ok ->
        {:group, os_pid}

      # EPERM is an existence proof: the kernel can only refuse a signal to
      # something that is there.
      {:error, :refused} ->
        {:group, os_pid}

      :gone ->
        warn_no_group(os_pid, "no_process_group_under_that_id")
        {:pid, os_pid}

      {:error, reason} ->
        warn_no_group(os_pid, "group_probe_failed_#{reason}")
        {:pid, os_pid}
    end
  end

  def resolve(_os_pid), do: :none

  @doc """
  True when a process group exists under `os_pid` -- i.e. the child is its own
  group leader and a group kill is safe.
  """
  @spec group_leader?(pos_integer()) :: boolean()
  def group_leader?(os_pid) when is_integer(os_pid) and os_pid > 1 do
    match?({:group, _}, resolve(os_pid))
  end

  def group_leader?(_os_pid), do: false

  @doc """
  Deliver `flag` (`"-0"`, `"-TERM"`, `"-KILL"`, ...) to `target`.

  `:gone` means nothing signallable is left, which against a GROUP is the
  question worth asking: the leader can be gone while an orphaned subprocess
  keeps the group alive.

  Raises `FunctionClauseError` for a target outside `is_signallable/1`, which is
  the point -- signalling pid 0 or 1 is not a recoverable mistake.
  """
  @spec signal(target(), String.t(), opts()) :: :ok | :gone | {:error, reason()}
  def signal(target, flag, opts \\ [])

  def signal(:none, _flag, _opts), do: :gone

  def signal(target, flag, opts) when is_signallable(target) and is_binary(flag) do
    case shell(opts) do
      nil -> {:error, :unavailable}
      path -> run(path, flag, arg(target))
    end
  end

  @doc """
  Poll until `target` is gone, giving up after `timeout_ms`.

  `:timeout` is a distinct answer from `{:error, _}`: it means the target is
  still there and the caller's grace is spent, which is normally the cue to stop
  asking and SIGKILL. An error means the question could not be answered at all.

  Returns `{:error, reason}` immediately rather than waiting out the deadline
  for any failure waiting cannot fix. A `:spawn_failed` IS waited on: giving up
  there would abandon the check under process-table pressure, which both causes
  it and is when it matters.
  """
  @spec await_gone(target(), non_neg_integer(), opts()) :: :ok | :timeout | {:error, reason()}
  def await_gone(target, timeout_ms, opts \\ [])

  def await_gone(:none, timeout_ms, _opts) when is_integer(timeout_ms), do: :ok

  def await_gone(target, timeout_ms, opts)
      when is_signallable(target) and is_integer(timeout_ms) and timeout_ms >= 0 do
    poll(target, System.monotonic_time(:millisecond) + timeout_ms, opts)
  end

  defp poll(target, deadline, opts) do
    case signal(target, "-0", opts) do
      :gone ->
        :ok

      {:error, :spawn_failed} ->
        keep_waiting(target, deadline, opts)

      {:error, _reason} = err ->
        err

      :ok ->
        keep_waiting(target, deadline, opts)
    end
  end

  defp keep_waiting(target, deadline, opts) do
    if System.monotonic_time(:millisecond) >= deadline do
      :timeout
    else
      Process.sleep(@poll_ms)
      poll(target, deadline, opts)
    end
  end

  # Arguments are passed positionally rather than interpolated into the script,
  # so nothing about the target can be read as shell.
  #
  # `BASH_ENV` and `ENV` are unset for the same reason. Bash sources `$BASH_ENV`
  # for NON-INTERACTIVE shells, `bash -c` included, so inheriting it hands
  # whatever set it arbitrary execution on every signal. Passing the target
  # safely is not worth much if the interpreter reading it was configured by
  # someone else.
  #
  # The locale is pinned to C because the errno text is the only thing that can
  # tell ESRCH from EPERM -- the builtin exits 1 for both. macOS libc does not
  # translate `strerror`, but glibc does, and CI is glibc.
  defp run(path, flag, arg) do
    args = ["-c", ~s(kill "$1" "$2"), "raxol-process-group", flag, arg]
    env = [{"BASH_ENV", nil}, {"ENV", nil}, {"LC_ALL", "C"}, {"LANG", "C"}]

    case System.cmd(path, args, stderr_to_stdout: true, env: env) do
      {_output, 0} -> :ok
      {output, _status} -> classify(output)
    end
  rescue
    e in [ErlangError, ArgumentError] ->
      Logger.debug("raxol.process_group.signal_raised error=#{inspect(e)}")
      {:error, :spawn_failed}
  end

  # ESRCH is matched POSITIVELY and anything unrecognised is an error, rather
  # than the other way round.
  #
  # The two mistakes do not cost the same. A false `:refused` logs a warning. A
  # false `:gone` reports a successful reap to a caller that may be about to
  # delete the directory the process is still writing into. Two real failures
  # that reach this and are not EPERM: a seccomp or LSM filter answers EACCES,
  # whose text is "Permission denied" and not "Operation not permitted"; and a
  # shell whose builtin rejects the flag answers with a usage error.
  defp classify(output) do
    cond do
      output =~ ~r/no such process/i -> :gone
      output =~ ~r/operation not permitted/i -> {:error, :refused}
      true -> {:error, :unknown}
    end
  end

  defp shell(opts) do
    case Keyword.get(opts, :shell) do
      path when is_binary(path) -> path
      _ -> System.find_executable("bash")
    end
  end

  defp arg({:group, pgid}), do: "-#{pgid}"
  defp arg({:pid, os_pid}), do: "#{os_pid}"

  defp warn_no_group(os_pid, reason) do
    Logger.warning(
      "raxol.process_group.no_group_kill os_pid=#{os_pid} reason=#{reason} " <>
        "detail=descendants_will_survive"
    )
  end
end
