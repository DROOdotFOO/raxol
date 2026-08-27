defmodule Raxol.AgentClientProtocol.Test.Teardown do
  @moduledoc """
  Stopping a supervisor from `on_exit` without asserting anything about
  whether it was still alive.

  Every end-to-end test in this package builds a `Transport.Paired` pair and
  starts an agent and a client supervisor with `start_link/2`, which links them
  to the TEST process. `on_exit` runs in `ExUnit.OnExitHandler`, a different
  process, after the test process is already gone -- so the link has usually,
  but not always, taken both supervisors down before the callback runs.

  That "usually" is the whole problem. `catch_exit/1` is an ASSERTION: it fails
  the test when the expression returns normally. Written as
  `catch_exit(Supervisor.stop(sup, :normal, 500))` it therefore passed only in
  the race where the supervisor was ALREADY DEAD (`Supervisor.stop` exits, and
  the exit is caught) and failed in the race where the teardown WORKED
  (`Supervisor.stop` returns `:ok`, and there is no exit to catch). The test
  asserted that its own cleanup had failed.

  It surfaced as an unrelated red X on other PRs, which is the expensive shape:
  reported against the test that owns the supervisor, in a package the PR never
  touched, at a line inside a callback rather than in the body.

  ## Why a monitor rather than a list of tolerable exit reasons

  There is no small set of reasons to enumerate. A supervisor caught mid-
  shutdown answers with a NESTED exit -- `GenServer.stop` wrapping
  `:sys.terminate` wrapping `shutdown` -- and which layer you get depends on
  how far along the link-driven shutdown already was. Matching on that is
  matching on a race.

  So the exit is discarded and the monitor is the verdict instead. The
  postcondition a teardown actually wants is "this process is gone", which a
  `:DOWN` states directly and a return value only implies.
  """

  # Long enough for an orderly shutdown of the two-process pairs in this
  # package, short enough that a wedged supervisor cannot hold the whole suite.
  # Spent at most twice PER supervisor: once waiting on `Supervisor.stop`, once
  # on the `:DOWN`. `stop_all/1` therefore has a worst-case budget of
  # `2 * @stop_timeout_ms * length(supervisors)`.
  @stop_timeout_ms 500

  @doc """
  Stop each supervisor in turn, treating an already-dead one as success.

  Every entry is visited even if an earlier one was already gone: a helper that
  gave up partway would leak the supervisors after the first dead one, and that
  leak shows up as an unrelated later test inheriting a process it never
  started.
  """
  @spec stop_all([pid()]) :: :ok
  def stop_all(supervisors) when is_list(supervisors) do
    Enum.each(supervisors, &stop_quietly/1)
  end

  @doc """
  Stop one supervisor and wait for it to actually be gone.

  Returns `:ok` whether the captured supervisor PID was alive or already dead.
  It exits only if a process survives the final untrappable kill; returning
  success without the promised postcondition would hide a cross-test leak.

  A supervisor that does not go down inside the budget is killed, so this
  cannot hang a suite on a wedged `terminate/2`.
  """
  @spec stop_quietly(pid()) :: :ok
  def stop_quietly(supervisor) when is_pid(supervisor), do: stop_and_await(supervisor)

  defp stop_and_await(pid) do
    # Snapshot and monitor the tree BEFORE the stop. Killing only a wedged
    # supervisor is insufficient: its `:killed` exit reaches a trapping child
    # as an ordinary, trappable signal, so that child can survive the parent.
    monitors =
      pid
      |> supervision_tree()
      |> Enum.uniq()
      |> Map.new(&{&1, Process.monitor(&1)})

    try do
      Supervisor.stop(pid, :normal, @stop_timeout_ms)
    catch
      # Discarded on purpose. This is not a swallowed error: the `:DOWN` below
      # is the check, and it is a stronger one than this return value.
      :exit, _reason -> :ok
    end

    monitors
    |> Map.keys()
    |> Enum.reverse()
    |> Enum.each(&kill_if_alive/1)

    Enum.each(monitors, fn {monitored_pid, ref} ->
      await_down(monitored_pid, ref)
    end)
  end

  defp await_down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @stop_timeout_ms ->
        Process.demonitor(ref, [:flush])
        exit({:teardown_process_survived_kill, pid})
    end
  end

  defp supervision_tree(pid) do
    children =
      try do
        Supervisor.which_children(pid)
      catch
        :exit, _reason -> []
      end

    descendants =
      Enum.flat_map(children, fn
        {_id, child, :supervisor, _modules} when is_pid(child) -> supervision_tree(child)
        {_id, child, _type, _modules} when is_pid(child) -> [child]
        _other -> []
      end)

    [pid | descendants]
  end

  defp kill_if_alive(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end
end
