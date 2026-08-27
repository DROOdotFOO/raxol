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
  @spec stop_all([pid() | atom()]) :: :ok
  def stop_all(supervisors) when is_list(supervisors) do
    Enum.each(supervisors, &stop_quietly/1)
  end

  @doc """
  Stop one supervisor and wait for it to actually be gone.

  Returns `:ok` whether it was alive, already dead, or never registered.
  Nothing here asserts: a teardown helper has no verdict to give, and the one
  it used to give was inverted.

  A supervisor that does not go down inside the budget is killed, so this
  cannot hang a suite on a wedged `terminate/2`.
  """
  @spec stop_quietly(pid() | atom()) :: :ok
  def stop_quietly(supervisor) do
    case GenServer.whereis(supervisor) do
      nil -> :ok
      pid -> stop_and_await(pid)
    end
  end

  defp stop_and_await(pid) do
    # Monitored BEFORE the stop, so a supervisor that dies during the call is
    # still reported rather than leaving nothing to wait on. Monitoring a pid
    # that is already dead delivers `:DOWN` with `:noproc` immediately, which
    # is the same answer by a shorter route.
    ref = Process.monitor(pid)

    try do
      Supervisor.stop(pid, :normal, @stop_timeout_ms)
    catch
      # Discarded on purpose. This is not a swallowed error: the `:DOWN` below
      # is the check, and it is a stronger one than this return value.
      :exit, _reason -> :ok
    end

    await_down(pid, ref)
  end

  defp await_down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @stop_timeout_ms ->
        Process.demonitor(ref, [:flush])
        # `:kill` rather than a trappable reason: the only way to be here is a
        # supervisor that already declined an orderly stop.
        Process.exit(pid, :kill)
        :ok
    end
  end
end
