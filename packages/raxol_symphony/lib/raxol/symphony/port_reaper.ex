defmodule Raxol.Symphony.PortReaper do
  @moduledoc """
  Stop the OS process behind a `Port`, and the descendants it spawned.

  `Port.close/1` releases the BEAM-side port and signals NOTHING. What becomes
  of the child is entirely the child's business: one that reads its stdin sees
  EOF and usually exits, one that does not simply keeps running, and in BOTH
  cases the subprocesses it spawned are untouched and outlive it. A caller that
  needs the work actually stopped has to signal it.

  Capture a target with `capture/1` while the port is still open, then either
  `kill/1` (we have given up on the work) or `await_exit/2` (let it go quietly
  first, then insist). `close/1` is the matching port teardown.

  `watch/1` covers the case no `try/after` can: a caller killed with an
  untrappable exit never runs its own cleanup, so the reap has to live in a
  process that survives it.

  The remote counterpart is `Raxol.Symphony.Ssh.reap_on_disconnect/2`, which
  does the same job on the far side of an ssh connection with `set -m` and a
  group kill inside bash.
  """

  require Logger

  @typedoc """
  What may safely be signalled.

  `{:group, pgid}` when the child leads its own process group, so its
  descendants come with it. `{:pid, os_pid}` when it does not, in which case
  only the child itself can be signalled. `:none` when the child is already
  gone.
  """
  @type target :: {:group, pos_integer()} | {:pid, pos_integer()} | :none

  @typedoc "Handle returned by `watch/1`, to be handed back to `release/1`."
  @type watcher :: pid() | :none

  @typedoc """
  Why a reap could not be carried out.

  `:unavailable` is the one that matters: it means we could not run a signal at
  all, so nothing was verified and nothing was killed. It must never be
  reported as success -- a caller that is about to delete the target's working
  directory is relying on the difference.
  """
  @type reason :: :unavailable

  # A pid of 0 means "my own process group" and 1 means "everything I am
  # allowed to signal". Neither is ever a port child, and either one turned
  # into a group kill takes the VM (or the host) with it. `capture/1` cannot
  # produce them, but `kill/1` and `await_exit/2` are public and this module
  # exists precisely to not assume that.
  defguardp is_signallable(target)
            when is_tuple(target) and tuple_size(target) == 2 and
                   elem(target, 0) in [:group, :pid] and
                   is_integer(elem(target, 1)) and elem(target, 1) > 1

  @poll_ms 50

  @doc """
  Read the signal target off a live port.

  Call this BEFORE closing the port. Once the child has exited, `ps` answers
  nothing about it, and the process group its orphans are still in is no longer
  recoverable -- a process group outlives its leader, which is exactly the case
  worth reaping.
  """
  @spec capture(port()) :: target()
  def capture(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      # `:os_pid` is `:undefined` for a port that did not spawn a process, and
      # the atom would otherwise flow all the way into an argv.
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 1 -> classify(os_pid)
      _ -> :none
    end
  end

  @doc """
  Close `port` if it is still open.

  The child can exit on its own between the decision to stop it and the close.
  `:exit_status` then closes the port for us, and `Port.close/1` raises on an
  already-closed port.
  """
  @spec close(port()) :: :ok
  def close(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        Port.close(port)
        :ok
    end
  rescue
    # The port can close between the check above and the call: same outcome.
    ArgumentError -> :ok
  end

  @doc """
  SIGKILL the target now.

  For callers that have already stopped waiting, where a process that traps
  SIGTERM must not get to keep running anyway.

  Returns `{:error, :unavailable}` when there is no way to send a signal on
  this system, which is NOT the same as the target being gone.
  """
  @spec kill(target()) :: :ok | {:error, reason()}
  def kill(:none), do: :ok
  def kill(target) when is_signallable(target), do: do_kill(signaller(), target)

  @doc """
  Wait up to `grace_ms` for the target to exit on its own, then SIGKILL it.

  For a clean shutdown, where closing the port has already delivered the EOF a
  well-behaved stdio child treats as "shut down": that child should be allowed
  to flush and exit on its own terms. The kill is the backstop for the two
  cases EOF does not cover -- a child that never reads stdin, and the tool
  subprocesses that outlive a parent which DID exit cleanly.

  Note the target was captured before the port closed, so across a long
  `grace_ms` there is a window in which the group could drain and the OS recycle
  the pid onto something unrelated. `kill/1` before the close avoids that
  entirely and is the right call wherever the EOF is not wanted.
  """
  @spec await_exit(target(), non_neg_integer()) :: :ok | {:error, reason()}
  def await_exit(:none, grace_ms) when is_integer(grace_ms) and grace_ms >= 0, do: :ok

  def await_exit(target, grace_ms)
      when is_signallable(target) and is_integer(grace_ms) and grace_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + grace_ms

    # Resolved once rather than per poll: this loop runs every 50ms and each
    # resolution is a full PATH scan.
    poll_until_gone(signaller(), target, deadline)
  end

  @doc """
  Reap `target` if the calling process dies before calling `release/1`.

  `try/after` does not run when a process is taken down by an untrappable exit,
  and that is how the orchestrator tears workers down (`stop_run`, stall
  detection, reconcile-kill). Cleanup that has to survive that cannot live in
  the dying process, so this spawns an unlinked one: it monitors the caller and
  kills the target on `:DOWN`.

  SIGKILL with no grace, unlike `await_exit/2`. An untrappable exit means the
  caller was abandoned rather than shut down -- nothing is left to read a clean
  exit's output, and the workspace may be removed next.

  The window this leaves is the mirror of `await_exit/2`'s: if the child exits
  on its own and the owner is killed much later, the captured target may by then
  name something else. Callers that finish normally close that by calling
  `release/1`.
  """
  @spec watch(target()) :: watcher()
  def watch(:none), do: :none

  def watch(target) when is_signallable(target) do
    owner = self()

    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        # Signals from one process are ordered, so a `release/1` sent before the
        # owner dies always arrives ahead of the `:DOWN`.
        {:release, ^owner} ->
          :ok

        {:DOWN, ^ref, :process, ^owner, reason} ->
          Logger.warning(
            "symphony.port_reaper.owner_died target=#{inspect(target)} " <>
              "reason=#{inspect(reason)} action=killed"
          )

          kill(target)
      end
    end)
  end

  @doc """
  Stand down a watcher: the caller has reaped the target itself.
  """
  @spec release(watcher() | nil) :: :ok
  def release(:none), do: :ok
  def release(nil), do: :ok

  def release(watcher) when is_pid(watcher) do
    send(watcher, {:release, self()})
    :ok
  end

  defp poll_until_gone(signaller, target, deadline) do
    case signal(signaller, target, "-0") do
      # Nothing signallable is left, which is the whole question.
      :gone ->
        :ok

      {:error, :unavailable} = err ->
        err

      :ok ->
        keep_waiting(signaller, target, deadline)
    end
  end

  defp keep_waiting(signaller, target, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      # Operationally interesting: reaching here means the child ignored the
      # EOF or left subprocesses behind, which is a fact about the child worth
      # seeing at the default log level.
      Logger.warning("symphony.port_reaper.grace_expired target=#{inspect(target)} action=killed")

      do_kill(signaller, target)
    else
      Process.sleep(@poll_ms)
      poll_until_gone(signaller, target, deadline)
    end
  end

  defp do_kill(signaller, target) do
    case signal(signaller, target, "-KILL") do
      :ok ->
        :ok

      # Already gone. Routine: the whole point of the grace is that the target
      # usually exits inside it, and the workspace path kills into a live race.
      :gone ->
        Logger.debug("symphony.port_reaper.already_gone target=#{inspect(target)}")
        :ok

      {:error, :unavailable} = err ->
        Logger.warning(
          "symphony.port_reaper.kill_unavailable target=#{inspect(target)} " <>
            "detail=no_kill_executable_and_no_bash"
        )

        err
    end
  end

  # `kill -0` reports whether anything signallable is left. Against a GROUP that
  # is the question worth asking: the leader can be gone while an orphaned tool
  # subprocess keeps the group alive.
  #
  # A zombie answers "alive" here, since it still holds its pid. `erl_child_setup`
  # reaps its own children promptly, so that resolves on its own rather than
  # costing the full grace.
  defp signal(:unavailable, _target, _flag), do: {:error, :unavailable}

  # Signals go through bash's `kill` BUILTIN, never `kill(1)`.
  #
  # procps-ng's `kill` -- `/usr/bin/kill` on Debian and Ubuntu, which is what CI
  # runs -- takes a negative pid in its own argv slot, does NOTHING with it, and
  # exits 0. Measured on linux/aarch64 with the group live:
  # `System.cmd(kill, ["-KILL", "-57"])` returned `{"", 0}` and both members
  # were still running afterwards. That is the worst failure available to this
  # module, a reap that reports success and reaps nothing, and the exit status
  # gives away none of it. `kill -s KILL -- -57` is no way out either: procps
  # has no `--` and answers with a usage error.
  #
  # macOS's `/bin/kill` handles the same argv correctly, which is exactly why
  # this was green on a developer machine and red on Linux CI.
  #
  # The builtin is POSIX about negative pids on both, and bash is already a hard
  # dependency of every call site -- `Session.start/5` and
  # `Workspace.execute_script/3` each spawn their child through it -- so where
  # bash is missing there is no port child to reap in the first place.
  #
  # Arguments are passed positionally rather than interpolated into the script,
  # so nothing about the target can be read as shell.
  defp signal({:bash, path}, target, flag) do
    run_signal(path, ["-c", ~s(kill "$1" "$2"), "raxol-port-reaper", flag, signal_arg(target)])
  end

  defp run_signal(path, args) do
    case System.cmd(path, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> :gone
    end
  rescue
    # The executable resolved a moment ago and cannot be run now.
    e in [ErlangError, ArgumentError] ->
      Logger.debug("symphony.port_reaper.signal_raised error=#{inspect(e)}")
      {:error, :unavailable}
  end

  defp signaller do
    case System.find_executable("bash") do
      path when is_binary(path) -> {:bash, path}
      nil -> :unavailable
    end
  end

  defp signal_arg({:group, pgid}), do: "-#{pgid}"
  defp signal_arg({:pid, os_pid}), do: "#{os_pid}"

  # Signal the process GROUP wherever it is safe to, because killing only the
  # child leaves its descendants running: still doing work, and still holding
  # the inherited stdout pipe, so a reader waiting on EOF blocks for the
  # command's full natural runtime after the supposed kill.
  #
  # `erl_child_setup` gives a spawned port child a process group of its own, so
  # `kill -KILL -PID` reaches its descendants and nothing else. That is CHECKED
  # rather than assumed, because the failure mode is not subtle: a child that is
  # not a group leader shares the BEAM's own group, and the group kill would
  # take the VM down with it. The `{:pid, _}` fallback loses the descendants and
  # keeps the VM.
  #
  # Falling back is safe but not free -- it silently drops the descendants --
  # so it says so rather than degrading quietly.
  defp classify(os_pid) do
    case process_group(os_pid) do
      {:ok, ^os_pid} ->
        {:group, os_pid}

      {:ok, pgid} ->
        warn_no_group_kill(os_pid, "not_group_leader pgid=#{pgid}")
        {:pid, os_pid}

      :error ->
        warn_no_group_kill(os_pid, "pgid_unavailable")
        {:pid, os_pid}
    end
  end

  defp warn_no_group_kill(os_pid, reason) do
    Logger.warning(
      "symphony.port_reaper.no_group_kill os_pid=#{os_pid} reason=#{reason} " <>
        "detail=descendants_will_survive"
    )
  end

  # A `ps` that is missing, fails, or answers something unparseable resolves the
  # same conservative way, for the same reason.
  defp process_group(os_pid) do
    with ps_path when is_binary(ps_path) <- System.find_executable("ps"),
         {output, 0} <-
           System.cmd(ps_path, ["-o", "pgid=", "-p", "#{os_pid}"], stderr_to_stdout: true),
         {pgid, ""} <- output |> String.trim() |> Integer.parse() do
      {:ok, pgid}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
