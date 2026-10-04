defmodule Raxol.Agent.SpawnedPort do
  @moduledoc """
  Lifecycle helpers shared by every port that spawns an OS process.

  The agent spawns processes from four places -- the native CLI backend, the
  two shell tools, and the directive executor -- and each one had drifted into
  its own answer for the same two questions. This module holds the answers
  once.

  ## Why stdin is `/dev/null`

  Every spawner here passes its input over argv: the native backend puts the
  prompt in `-p`, the shell tools pass the command to `sh -c`, and `op` takes
  its reference as an argument. None of them ever calls `Port.command/2`, so
  a child that reads stdin must see EOF at once.

  No port option gives it that on Unix. Opened for both directions, the port
  hands the child a pipe that carries nothing and never closes, so anything
  that drains stdin blocks until the caller's deadline. Opened with `:in`,
  erts skips the stdin `dup2` entirely (`erl_child_setup.c`) and the child
  inherits the BEAM's own fd 0 -- under the TUI, the user's terminal. The
  child then races the TUI for keystrokes (a key being typed for `/login`
  included) and can rewrite its termios. erts does start the child in a new
  session, so `/dev/tty` is unreachable; fd 0 is the whole problem.

  So on Unix the redirect is done by a shell: `spawn_spec/2` wraps an
  executable in `sh -c 'exec "$@" </dev/null'`, and `null_stdin_command/1`
  prefixes an `sh -c` script with `exec </dev/null`. Neither passes `:in`:
  with the redirect in place the pipe is moot, and leaving it open means a
  spawner that loses the redirect hangs its stdin test on every host instead
  of only under a terminal. Windows is the exception: there erts opens `NUL`
  as the child's stdin for an input-only port (`win32/sys.c`), so `:in` is
  the whole fix and no shell is involved.

  The wrapper shell is not transparent, which is what the rest of
  `spawn_spec/2` handles. The executable is expanded to an absolute path, so
  `exec` never parses it as an option or looks it up on PATH. The variables
  that make `sh` print or run code on its own (`SHELLOPTS`, `BASHOPTS`, `PS4`,
  `BASH_ENV`, `ENV`) are removed from its environment. And anything `sh`
  writes before the `exec` -- bash-as-sh warns on an uninstalled `LC_ALL`, for
  one -- precedes a marker line, so `target_output/2` can return only what the
  target itself wrote.

  Note what EOF on stdin changes besides the hang. A command that prompts for
  input reads EOF and continues down its non-interactive path, which for tools
  like `ssh`, `git` and `curl` can mean falling through to another credential
  source rather than failing. That is the correct behaviour for a shell tool,
  and the sandbox (`Raxol.Agent.Actions.Code.shell_allow/2`, the jail flag,
  the allow/denylist) is what decides whether a command runs at all.

  The opposite case -- a child that must actually RECEIVE stdin -- is not
  solvable this way at all, because a spawned port cannot half-close. See
  `Raxol.System.PortCommand`, which feeds stdin from a temp file for exactly
  that reason.

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

  @exec_marker "<<raxol:exec>>"
  @exec_script "printf '%s\\n' '#{@exec_marker}'; exec \"$@\" </dev/null"
  @shell_env for var <- ~w(SHELLOPTS BASHOPTS PS4 BASH_ENV ENV),
                 do: {String.to_charlist(var), false}

  @typedoc """
  How to open a port for `executable` so its stdin is `/dev/null`.

  `:path` and `:args` go to `{:spawn_executable, path}` and `{:args, args}`;
  `:opts` are appended to the caller's port options (the caller must not pass
  `:in` or `:env` itself). `:exec_marker` is the line the wrapper prints just
  before `exec`, or nil when there is no wrapper; hand the spec to
  `target_output/2` or `exec_marker_line?/2` to drop what precedes it.
  """
  @type spawn_spec :: %{
          path: String.t(),
          args: [String.t()],
          opts: list(),
          exec_marker: String.t() | nil
        }

  @doc """
  A port spec that runs `executable` with `args` and `/dev/null` for stdin.

  On Unix the executable runs under `sh -c 'exec "$@" </dev/null'` -- passed
  as argv, never interpolated, and `exec` keeps the os pid the caller's
  deadline kill targets. On Unix a missing or non-executable `executable`
  therefore exits 126/127 with `sh`'s diagnostic after the marker instead of
  raising from `Port.open/2`. On Windows, and on a Unix host with no `sh`, it
  is a direct spawn with `:in`.
  """
  @spec spawn_spec(String.t(), [String.t()]) :: spawn_spec()
  def spawn_spec(executable, args), do: spawn_spec(executable, args, :os.type())

  @doc false
  @spec spawn_spec(String.t(), [String.t()], {atom(), atom()}) :: spawn_spec()
  def spawn_spec(executable, args, {:win32, _}), do: direct_spec(executable, args)

  def spawn_spec(executable, args, _unix) do
    case shell() do
      nil ->
        direct_spec(executable, args)

      sh ->
        %{
          path: sh,
          args: ["-c", @exec_script, "sh", Path.expand(executable) | args],
          opts: [{:env, @shell_env}],
          exec_marker: @exec_marker
        }
    end
  end

  defp direct_spec(executable, args),
    do: %{path: executable, args: args, opts: [:in], exec_marker: nil}

  defp shell do
    if File.exists?("/bin/sh"), do: "/bin/sh", else: System.find_executable("sh")
  end

  @doc """
  Prefix an `sh -c` script so it runs with `/dev/null` for stdin.

  For spawners whose target IS a shell script; open the port without `:in`
  (see the moduledoc). Unix-only, like `sh -c` itself.
  """
  @spec null_stdin_command(String.t()) :: String.t()
  def null_stdin_command(command), do: "exec </dev/null\n" <> command

  @doc """
  The target's own output: everything after the wrapper's marker line.

  `{:ok, output}` when `spec` has no wrapper (the output is already the
  target's) or the marker was seen; `:error` when the wrapper died before
  printing it.
  """
  @spec target_output(binary(), spawn_spec()) :: {:ok, binary()} | :error
  def target_output(output, %{exec_marker: nil}), do: {:ok, output}

  def target_output(output, %{exec_marker: marker}) do
    case :binary.split(output, marker <> "\n") do
      [_prelude, target] -> {:ok, target}
      [_no_marker] -> :error
    end
  end

  @doc """
  For a port opened in `{:line, _}` mode: true for the wrapper's marker line.
  Lines before it are the shell's, not the target's. A shell diagnostic
  without a trailing newline can share the marker's line, hence the suffix
  match. Always false when `spec` has no wrapper.
  """
  @spec exec_marker_line?(binary(), spawn_spec()) :: boolean()
  def exec_marker_line?(_line, %{exec_marker: nil}), do: false
  def exec_marker_line?(line, %{exec_marker: marker}), do: String.ends_with?(line, marker)

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
