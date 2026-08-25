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

  ## What lives here, and what does not

  Resolving a safe target and delivering a signal are `Raxol.Core.ProcessGroup`,
  shared with `Raxol.Agent.Interrupt` (which does the same job for the agent's
  shell tool). This module is the PORT-shaped layer on top: reading a target off
  a live port, the close, the grace-then-kill sequence, and the owner-death
  watcher.

  The split is where it is because the two callers agree exactly on the OS
  question -- which pid may be signalled, and did the signal land -- and agree on
  nothing above it. `Interrupt` stages a cooperative TERM before its KILL and
  needs a zombie-aware liveness oracle to confirm death; neither has anything to
  do with ports.
  """

  require Logger

  import Raxol.Core.ProcessGroup, only: [is_signallable: 1]

  alias Raxol.Core.ProcessGroup

  @typedoc "What may safely be signalled. See `Raxol.Core.ProcessGroup`."
  @type target :: ProcessGroup.target()

  @typedoc "Handle returned by `watch/1`, to be handed back to `release/1`."
  @type watcher :: pid() | :none

  @typedoc """
  Why a reap could not be carried out. See `Raxol.Core.ProcessGroup`.

  NONE of these may be reported as success: a caller that is about to delete the
  target's working directory is relying on the difference.
  """
  @type reason :: ProcessGroup.reason()

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
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 1 -> ProcessGroup.resolve(os_pid)
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
  def kill(target) when is_signallable(target), do: do_kill(target)

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
    poll_then_kill(target, grace_ms)
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

  # The grace, then the kill. `await_gone/3` answers `:timeout` when the target
  # outlived the grace, which is the only case that still needs a signal.
  defp poll_then_kill(target, deadline_ms) do
    case ProcessGroup.await_gone(target, deadline_ms) do
      :ok ->
        :ok

      :timeout ->
        # Operationally interesting: reaching here means the child ignored the
        # EOF or left subprocesses behind, which is a fact about the child worth
        # seeing at the default log level.
        Logger.warning(
          "symphony.port_reaper.grace_expired target=#{inspect(target)} action=killed"
        )

        do_kill(target)

      {:error, _reason} = err ->
        err
    end
  end

  defp do_kill(target), do: do_kill(target, @kill_attempts)

  defp do_kill(target, attempts_left) do
    case ProcessGroup.signal(target, "-KILL") do
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
        do_kill(target, attempts_left - 1)

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
end
