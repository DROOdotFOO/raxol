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

  ## Relationship to `Raxol.Agent.Interrupt`

  That module solves the same OS problem for the agent's shell tool and answers
  it differently: it proves group leadership by reading `pgid` out of `ps` and
  requiring `pgid == os_pid`, where this probes with `kill -0` against the group.

  The difference is not cosmetic. `ps` cannot see a corpse, so when a hook
  backgrounds a child and exits -- the commonest leak shape, and the one that
  keeps the port open while `Port.info/2` still names the dead parent -- the
  `ps` read fails and the group is never found. `Interrupt` has a
  `descendants_of/1` sweep that covers some of that through ppid linkage, which
  a reparented orphan is also invisible to. It additionally interpolates the pid
  into a shell string rather than passing it positionally, and depends on a `ps`
  that busybox does not implement.

  Consolidating onto this module is worth doing and is NOT done here: it is a
  different package with its own tests, and `raxol_symphony` takes `raxol_agent`
  only as an optional dependency.
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

  NONE of these may be reported as success: a caller that is about to delete the
  target's working directory is relying on the difference.

  `:unavailable` -- no signal could be run at all (no bash), so nothing was
  verified and nothing was killed.

  `:refused` -- the kernel rejected the signal (EPERM). The target is
  demonstrably still there, and still running.

  `:spawn_failed` -- bash resolved but could not be run this time. Transient by
  nature (a fork that hit `EAGAIN` under process-table pressure is the case that
  matters, and process-table pressure is exactly when a leaked-process reaper is
  most needed), so it is RETRIED rather than answered.

  `:unknown` -- the signal failed with something this does not recognise. Not
  reported as `:gone`, because "the message was not one I know" is not evidence
  that the target exited.
  """
  @type reason :: :unavailable | :refused | :spawn_failed | :unknown

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

  # `kill/1` answers immediately, so a transient fork failure has no deadline to
  # be retried against the way `await_exit/2`'s poll does. Small on purpose: this
  # is covering an `EAGAIN`, not waiting anything out.
  @kill_attempts 3
  @retry_ms 25

  @doc """
  Read the signal target off a live port.

  Call this BEFORE closing the port. `Port.info/2` is the only thing that knows
  the child's pid, and a closed port has forgotten it, so from then on the
  process group the orphans are still in is unrecoverable -- and a group
  outliving its leader is exactly the case worth reaping.

  `:none` means the PORT is closed. It does not mean nothing is running. A
  caller that can reach a closed port should keep the target it captured while
  the port was open and fall back to that.
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
  the pid onto something unrelated. `kill/1` before the close narrows that
  window and is the right call wherever the EOF is not wanted, but it does not
  close it: a port stays open for as long as ANY descendant holds the inherited
  stdout, so the child can already be dead and reaped while `Port.info/2` still
  reports its pid.

  Nothing pid-based can close that window. What BOUNDS it is that a group id
  cannot be recycled while the group still has a member -- so for as long as
  there is anything to kill, the target is exact.

  That is a bound, not a guarantee of harmlessness, and the difference matters
  for anything holding a target across a long idle period. Once the group HAS
  drained its id is free for reuse, and a reap fired then is not a no-op: it is
  a `SIGKILL` at whatever unrelated process group now carries that id. This
  function is safe because it probes with `kill -0` and stops at `:gone` before
  signalling anything; a caller that skips the probe does not inherit that.
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

  The window this leaves is the mirror of `await_exit/2`'s, and unlike that one
  it is NOT probed away: `kill/1` signals whatever the captured target names. If
  the child exits on its own, its group drains, and the owner is killed long
  enough afterwards for the OS to have recycled the pgid, the reap lands on an
  unrelated process group. Callers that finish normally close that window by
  calling `release/1`; hold a watcher across a long idle period and it reopens.

  The watcher also reaps when it is SHUT DOWN, not only when its owner dies, so
  a supervised teardown of the tree does not leak the trees below it.
  """
  @spec watch(target()) :: watcher()
  def watch(:none), do: :none

  def watch(target) when is_signallable(target) do
    owner = self()

    spawn_watcher(fn -> watch_loop(owner, target) end)
  end

  # Under `Raxol.Symphony.TaskSupervisor` when the tree is up, and a bare
  # `spawn/1` when it is not (tests, and embedders that use `Session` without the
  # supervisor).
  #
  # The supervised form is what makes shutdown reaping possible at all: a task is
  # linked to its Task.Supervisor but NOT to the caller, which is exactly the
  # lifetime a watcher wants. A bare unlinked `spawn/1` receives no exit signal
  # from anything, so it cannot be told the VM is going away -- it is a fallback,
  # not an equivalent, and a deployment running without the tree still leaks its
  # in-flight trees on restart.
  #
  # `TaskSupervisor` is FIRST in the supervisor's child list, and children
  # terminate in reverse order, so watchers are torn down after the workers whose
  # targets they are covering.
  defp spawn_watcher(fun) do
    case Process.whereis(Raxol.Symphony.TaskSupervisor) do
      nil ->
        spawn(fun)

      _sup ->
        case Task.Supervisor.start_child(Raxol.Symphony.TaskSupervisor, fun) do
          {:ok, pid} -> pid
          # Racing the tree going down, or at capacity. An unsupervised watcher
          # still covers the owner-death case, which is the common one.
          _other -> spawn(fun)
        end
    end
  end

  defp watch_loop(owner, target) do
    # Trapped so a supervised shutdown arrives as a message rather than killing
    # the watcher outright: an orchestrator restart would otherwise abandon every
    # tree in flight.
    Process.flag(:trap_exit, true)
    ref = Process.monitor(owner)

    receive do
      # NOT pinned to `owner`. Holding the watcher pid IS the authority to stand
      # it down, and pinning made `release/1` silently no-op whenever the process
      # calling it was not the one that called `watch/1` -- leaving a watcher
      # armed to SIGKILL a target its caller had already reaped, with nothing
      # anywhere reporting that the disarm had failed.
      {:release, _from} ->
        :ok

      {:DOWN, ^ref, :process, ^owner, reason} ->
        Logger.warning(
          "symphony.port_reaper.owner_died target=#{inspect(target)} " <>
            "reason=#{inspect(reason)} action=killed"
        )

        kill(target)

      # The supervisor is going down and taking this with it. Reaching here means
      # the owner is still alive, so nothing else is going to reap the target.
      {:EXIT, _from, reason} ->
        Logger.warning(
          "symphony.port_reaper.watcher_shutdown target=#{inspect(target)} " <>
            "reason=#{inspect(reason)} action=killed"
        )

        kill(target)
    end
  end

  @doc """
  Stand down a watcher: the caller has reaped the target itself.

  Any process holding the watcher pid may call this, not only the one that
  called `watch/1`.
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

      # Could not fork bash this time. Giving up here would abandon the reap
      # under process-table pressure -- the one condition that both causes this
      # and makes a leaked process tree matter -- so it is retried on the same
      # deadline as a target that is simply still running.
      {:error, :spawn_failed} ->
        keep_waiting(signaller, target, deadline)

      # Waiting cannot fix these, and each means the target may still be
      # running, so they are answered now rather than at the deadline.
      {:error, _reason} = err ->
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

  defp do_kill(signaller, target), do: do_kill(signaller, target, @kill_attempts)

  defp do_kill(signaller, target, attempts_left) do
    case signal(signaller, target, "-KILL") do
      :ok ->
        :ok

      # Already gone. Routine: the whole point of the grace is that the target
      # usually exits inside it, and the workspace path kills into a live race.
      :gone ->
        Logger.debug("symphony.port_reaper.already_gone target=#{inspect(target)}")
        :ok

      # `kill/1` has no deadline to retry against, so it carries its own small
      # budget rather than reporting a fork failure as an unreaped target.
      {:error, :spawn_failed} when attempts_left > 1 ->
        Process.sleep(@retry_ms)
        do_kill(signaller, target, attempts_left - 1)

      {:error, reason} = err ->
        Logger.warning(
          "symphony.port_reaper.kill_failed target=#{inspect(target)} " <>
            "reason=#{inspect(reason)} detail=#{unreaped_detail(reason)}"
        )

        err
    end
  end

  defp unreaped_detail(:unavailable), do: "no_bash_on_path"
  defp unreaped_detail(:refused), do: "kernel_refused_the_signal_target_still_running"
  defp unreaped_detail(:spawn_failed), do: "could_not_run_bash_target_not_verified"
  defp unreaped_detail(:unknown), do: "unrecognised_kill_failure_target_not_verified"

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

  # The builtin exits 1 for EVERY failure, so the status alone cannot tell
  # "already dead" (ESRCH) from "the kernel refused" (EPERM). Only the errno
  # text can, and it is read with the locale pinned to C: macOS libc does not
  # translate `strerror` at all, but glibc does, and CI is glibc.
  #
  # `BASH_ENV` and `ENV` are unset for the same reason the target is passed
  # positionally. Bash sources `$BASH_ENV` for NON-INTERACTIVE shells, `bash -c`
  # included, so inheriting it hands whatever set it arbitrary execution -- once
  # per capture, once per stop, and once per poll of every grace window. Passing
  # the target safely is not worth much if the interpreter reading it was
  # configured by someone else.
  defp run_signal(path, args) do
    env = [{"BASH_ENV", nil}, {"ENV", nil}, {"LC_ALL", "C"}, {"LANG", "C"}]

    case System.cmd(path, args, stderr_to_stdout: true, env: env) do
      {_output, 0} -> :ok
      {output, _status} -> classify_failure(output)
    end
  rescue
    # bash resolved a moment ago and cannot be run now. A fork that hit EAGAIN
    # under process-table pressure is the case worth surviving -- that pressure
    # is exactly when a leaked-process reaper is most needed -- so this is
    # retriable rather than terminal.
    e in [ErlangError, ArgumentError] ->
      Logger.debug("symphony.port_reaper.signal_raised error=#{inspect(e)}")
      {:error, :spawn_failed}
  end

  # ESRCH is matched POSITIVELY and anything unrecognised is an error, rather
  # than the other way round.
  #
  # The two mistakes do not cost the same. A false `:refused` logs a warning. A
  # false `:gone` reports a SUCCESSFUL REAP to a caller that is about to `rm_rf`
  # the directory the process is still writing into -- the exact failure the
  # moduledoc calls the worst one available here, so defaulting to it was
  # building it in.
  #
  # Two real failures that reach this and are not EPERM: a seccomp or LSM filter
  # answers EACCES, whose text is "Permission denied" and not "Operation not
  # permitted"; and a bash whose builtin rejects the flag answers with a usage
  # error. Neither is evidence that the target exited.
  defp classify_failure(output) do
    cond do
      output =~ ~r/no such process/i -> :gone
      output =~ ~r/operation not permitted/i -> {:error, :refused}
      true -> {:error, :unknown}
    end
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
  # The check is a `kill -0` against the GROUP rather than a `ps` read of the
  # child's pgid, and that is load-bearing rather than a tidy-up.
  #
  # A process group's id is the pid of its leader, and that pid stays allocated
  # for as long as the group has any member at all. So "group `os_pid` answers
  # a signal" can only be true if the process holding pid `os_pid` -- our child,
  # since the port is open -- is the one that led it. A child that is NOT a
  # group leader has no group under its own id, the probe says so, and the
  # fallback keeps the VM. The BEAM's own group is unreachable here by
  # construction rather than by inspection.
  #
  # `ps` could not answer this at all in the case that matters most. A hook that
  # backgrounds a child and exits leaves the port OPEN -- ERTS withholds the
  # exit status until the inherited stdout reaches EOF and the orphan is still
  # holding it -- while `Port.info/2` goes on reporting the dead parent's pid.
  # `ps -o pgid= -p <dead pid>` fails there, which classified the live group as
  # `{:pid, <corpse>}`, SIGKILLed a pid nobody owns, and reported success while
  # the orphan the reap exists for kept running. It was also the module's only
  # dependency on a `ps` that busybox does not implement.
  #
  # Falling back is safe but not free -- it silently drops the descendants --
  # so it says so rather than degrading quietly.
  defp classify(os_pid) do
    case signal(signaller(), {:group, os_pid}, "-0") do
      :ok ->
        {:group, os_pid}

      # EPERM is an existence proof: the kernel can only refuse a signal to
      # something that is there.
      {:error, :refused} ->
        {:group, os_pid}

      :gone ->
        warn_no_group_kill(os_pid, "no_process_group_under_that_id")
        {:pid, os_pid}

      # Could not prove a group is there. The narrow target is the safe
      # direction -- it loses the descendants, where a group kill against a
      # group that is not ours would not be recoverable at all.
      {:error, reason} ->
        warn_no_group_kill(os_pid, "group_probe_failed_#{reason}")
        {:pid, os_pid}
    end
  end

  defp warn_no_group_kill(os_pid, reason) do
    Logger.warning(
      "symphony.port_reaper.no_group_kill os_pid=#{os_pid} reason=#{reason} " <>
        "detail=descendants_will_survive"
    )
  end
end
