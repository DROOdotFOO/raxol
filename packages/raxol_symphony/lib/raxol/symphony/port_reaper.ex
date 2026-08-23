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
  first, then insist).

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
      nil -> :none
      {:os_pid, os_pid} -> classify(os_pid)
    end
  end

  @doc """
  SIGKILL the target now.

  For callers that have already stopped waiting, where a process that traps
  SIGTERM must not get to keep running anyway.
  """
  @spec kill(target()) :: :ok
  def kill(:none), do: :ok

  def kill(target) do
    case signal(target, "-KILL") do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "symphony.port_reaper.kill_failed target=#{inspect(target)} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Wait up to `grace_ms` for the target to exit on its own, then SIGKILL it.

  For a clean shutdown, where closing the port has already delivered the EOF a
  well-behaved stdio child treats as "shut down": that child should be allowed
  to flush and exit on its own terms. The kill is the backstop for the two
  cases EOF does not cover -- a child that never reads stdin, and the tool
  subprocesses that outlive a parent which DID exit cleanly.
  """
  @spec await_exit(target(), non_neg_integer()) :: :ok
  def await_exit(:none, _grace_ms), do: :ok

  def await_exit(target, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + grace_ms
    poll_until_gone(target, deadline)
  end

  defp poll_until_gone(target, deadline) do
    cond do
      not alive?(target) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.debug("symphony.port_reaper.grace_expired target=#{inspect(target)}")
        kill(target)

      true ->
        Process.sleep(@poll_ms)
        poll_until_gone(target, deadline)
    end
  end

  # `kill -0` reports whether anything signallable is left. Against a GROUP that
  # is the question worth asking: the leader can be gone while an orphaned tool
  # subprocess keeps the group alive.
  #
  # A zombie answers "alive" here, since it still holds its pid. `erl_child_setup`
  # reaps its own children promptly, so that resolves on its own rather than
  # costing the full grace.
  defp alive?(:none), do: false

  defp alive?(target) do
    match?({:ok, _}, signal(target, "-0"))
  end

  defp signal(target, flag) do
    case System.find_executable("kill") do
      nil ->
        {:error, :no_kill_executable}

      kill_path ->
        case System.cmd(kill_path, [flag, signal_arg(target)], stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, String.trim(output)}}
        end
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
  defp classify(os_pid) do
    if group_leader?(os_pid), do: {:group, os_pid}, else: {:pid, os_pid}
  end

  # A `ps` that is missing, fails, or answers something unparseable resolves the
  # same conservative way, for the same reason.
  defp group_leader?(os_pid) do
    with ps_path when is_binary(ps_path) <- System.find_executable("ps"),
         {output, 0} <-
           System.cmd(ps_path, ["-o", "pgid=", "-p", "#{os_pid}"], stderr_to_stdout: true) do
      String.trim(output) == "#{os_pid}"
    else
      _ -> false
    end
  end
end
