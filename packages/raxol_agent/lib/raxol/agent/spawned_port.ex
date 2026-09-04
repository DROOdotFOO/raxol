defmodule Raxol.Agent.SpawnedPort do
  @moduledoc """
  Lifecycle helpers shared by every port that spawns an OS process.

  The agent spawns processes from four places -- the native CLI backend, the
  two shell tools, and the directive executor -- and each one had drifted into
  its own answer for the same two questions. This module holds the answers
  once.

  ## Why stdin is closed

  Every spawner here passes its input over argv: the native backend puts the
  prompt in `-p`, and both shell tools pass the command to `sh -c`. None of
  them ever calls `Port.command/2`. Opening the port for both directions
  therefore hands the child a write pipe that carries nothing and is never
  closed, which reads to the child as "more input is coming" forever. Anything
  that drains stdin before doing its work then blocks until the caller's
  deadline and dies having produced nothing.

  Passing `:in` opens the port for input only, which points the child's stdin
  at `/dev/null` so a read returns EOF immediately. The one case it would break
  is a child whose parent-death signal is EOF on stdin, which needs the pipe
  held open; nothing spawned here works that way.

  The opposite case -- a child that must actually RECEIVE stdin -- is not
  solvable this way at all, because a spawned port cannot half-close. See
  `Raxol.System.PortCommand`, which feeds stdin from a temp file for exactly
  that reason.

  Note what closing stdin changes besides the hang. A command that prompts for
  input used to block on the open pipe and get killed at the deadline; it now
  reads EOF and continues down its non-interactive path, which for tools like
  `ssh`, `git` and `curl` can mean falling through to another credential source
  rather than failing. That is the correct behaviour for a shell tool, and the
  sandbox (`Raxol.Agent.Actions.Code.shell_allow/2`, the jail flag, the
  allow/denylist) is what decides whether a command runs at all -- a stalled
  pipe was never a security control. It is recorded here because the change is
  easy to read as purely a hang fix.

  ## Why closing needs a guard and a drain

  On a timeout the caller SIGKILLs the process group first, so by the time the
  port is closed it has usually already died on its own -- and `Port.close/1`
  raises on a port that is already gone. `Port.info/1` narrows that window but
  cannot close it, since the port can die between the check and the close, so
  the rescue is what makes it correct rather than merely unlikely.

  A port that died on its own has already queued its `{port, {:exit_status,
  _}}` to the owner, and closing does not retract a message that was already
  sent. Left there it never matches again -- every collect loop matches on its
  own `^port` -- so it accumulates in a long-lived session process that runs
  many commands. `close/1` therefore drains that message after closing.
  """

  @doc """
  Close a spawned port and drain the exit status it may already have queued.

  Safe to call on a port that has already died, which is the common case on a
  timeout path. Always returns `:ok`.

  The drain is `after 0`: it collects the status when the port died before the
  close, which is precisely the case that leaks. A status that arrives later
  still goes unread -- closing a live port suppresses it, so that window is
  narrow, but it is not zero.
  """
  @spec close(port()) :: :ok
  def close(port) when is_port(port) do
    safe_close(port)
    drain_exit_status(port)
  end

  defp safe_close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp drain_exit_status(port) do
    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      0 -> :ok
    end
  end
end
