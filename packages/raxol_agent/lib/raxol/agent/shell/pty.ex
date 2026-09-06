defmodule Raxol.Agent.Shell.Pty do
  @moduledoc """
  Give a spawned command a controlling terminal, with no new dependency.

  ## Why `script(1)` rather than a NIF or a hex package

  `Port.open({:spawn_executable, _}, _)` hands the child three pipes. There is
  no BEAM primitive that hands it a pty instead: `openpty`/`forkpty` are libc
  calls, so a native pty means a NIF or a port driver. This package has
  neither, and the one native artifact in the umbrella (`raxol_terminal`'s
  termbox2 NIF) is a renderer for the terminal the BEAM is *already* attached
  to — it allocates nothing for a child.

  The repo's existing answer to "this needs a real pty" is already "ask the OS
  for one": `Raxol.Terminal.PtyHarness` boots its fixture app inside tmux or
  expect. `script(1)` is the same move without a multiplexer, and it is present
  on macOS (BSD) and on any Linux with util-linux or busybox. So a tty costs a
  fork of a binary that is already installed, rather than a C toolchain in the
  build.

  ## Why the flavour is probed and not derived from `:os.type/0`

  The two argv forms are incompatible — BSD takes `[file | command]`
  positionally, util-linux and busybox take the command through `-c` with the
  file last — and the split is not "macOS vs Linux". A `--version` probe does
  not separate them either: busybox answers a usage error like BSD does, but
  speaks the util-linux argv. So the probe runs the candidate for real against
  `exit 3` and keeps whichever reports 3 back, which is exactly the property
  the caller depends on (the child's status must survive the wrapper). The
  answer is cached in `:persistent_term` because it cannot change while the VM
  runs.

  The probe spawns through a `Port` with `:in`, never `System.cmd/3`. BSD
  `script` puts *its own* stdin into raw mode when that stdin is a tty, and
  `System.cmd/3` would hand it the terminal the developer is running the suite
  in. A port's child never sees that fd at all.

  ## Why the pty child's stdin is left open

  A port opened with `:in` points the child's stdin at `/dev/null` (see
  `Raxol.Agent.SpawnedPort` for why every other spawner here wants that). Under
  `script` the immediate EOF is copied to the pty master, and the line
  discipline echoes it back as `^D\\b\\b` — so every pty command's output would
  start with three bytes the command never wrote. Holding the pipe open instead
  costs a command that reads stdin its EOF, and it blocks until the caller's
  deadline. That is the correct semantics for this mode: a pty means "a
  terminal is attached", and a terminal does not EOF. The non-pty path keeps
  `:in`.

  ## Why killing a pty job needs `inner_groups/1`

  `script` allocates the pty and then calls `login_tty`, which `setsid`s the
  command into a NEW session and process group. So the BEAM's per-port
  guarantee (the port program leads its own group, `pgid == os_pid`) covers
  `script` and stops there: `kill -9 -<script_pid>` does not reach the command
  or anything it forked. Closing the master does raise SIGHUP on the pty's
  foreground group, but SIGHUP is catchable and ignorable, so relying on it
  reintroduces exactly the orphan the shell action's wall-clock timeout exists
  to prevent. `inner_groups/1` names the sessions to kill first, and each is
  killed through `Raxol.Agent.Interrupt.kill_os_pid/1`, which probes the group
  before signalling rather than trusting a pid we derived.
  """

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.SpawnedPort

  @flavours [:bsd, :util_linux]
  @probe_command "exit 3"
  @probe_status 3
  @probe_timeout_ms 5_000

  @typedoc "The `{executable, argv, env}` triple to hand `Port.open/2`."
  @type spec :: {String.t(), [String.t()], [{charlist(), charlist()}]}

  @doc """
  The `{executable, argv, env}` that runs `command` under a controlling
  terminal, or `:unavailable` on a host with no usable `script(1)`.

  `shell_path` is the shell the command runs under. The BSD form execs it
  directly. util-linux's `-c` instead runs the command through `$SHELL`,
  which would silently hand a developer's zsh or fish a `sh` command line, so
  that flavour carries `SHELL` in the returned env — the same shell on both,
  and the same shell the non-pty path uses.
  """
  @spec spawn_spec(String.t(), String.t()) :: {:ok, spec()} | :unavailable
  def spawn_spec(shell_path, command)
      when is_binary(shell_path) and is_binary(command) do
    case flavour(shell_path) do
      :none ->
        :unavailable

      flavour ->
        {:ok, {script_path(), args(flavour, shell_path, command), env(flavour, shell_path)}}
    end
  end

  @doc "Whether this host can allocate a pty for a child."
  @spec available?(String.t()) :: boolean()
  def available?(shell_path) when is_binary(shell_path),
    do: flavour(shell_path) != :none

  @doc """
  The process groups running INSIDE the pty of the `script` process `os_pid` —
  the ones a group kill of `os_pid` cannot reach.

  One `ps` table scan for `os_pid`'s direct children; each is a session leader
  (`script` `setsid`s it), so killing its group reaches everything it forked.
  A child that `setsid`s again is beyond one level, which is the honest bound
  here: nothing enumerable links it back.

  Empty when `ps` is unavailable or the process has no children, which is the
  safe answer — the caller still group-kills `os_pid` itself.
  """
  @spec inner_groups(non_neg_integer() | nil) :: [pos_integer()]
  def inner_groups(os_pid) when is_integer(os_pid) and os_pid > 1 do
    case System.cmd("ps", ["-eo", "pid=,ppid="], stderr_to_stdout: true) do
      {out, 0} -> children_of(out, os_pid)
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  def inner_groups(_os_pid), do: []

  @doc """
  Kill everything behind the `script` process `os_pid`, and report
  `{killed?, confirmed?}` for the command's OWN process group.

  The claim is about the session inside the pty, because that is where the
  command runs. Killing it makes `script` exit by itself, so the kill of
  `script`'s own group afterwards is teardown for the case where it does not:
  by the time that runs, "there is no group under this id" usually means it
  already exited, and letting that answer downgrade a landed kill would report
  a failure for the ordinary success path.

  `{false, false}` when nothing was running inside the pty. No group was
  killed, and saying one was would be a claim about a process that had already
  gone.
  """
  @spec kill_tree(non_neg_integer() | nil) :: {boolean(), boolean()}
  def kill_tree(os_pid) do
    results = os_pid |> inner_groups() |> Enum.map(&Interrupt.kill_os_pid/1)
    _teardown = Interrupt.kill_os_pid(os_pid)

    {results != [] and Enum.all?(results, fn {disposition, _, _} -> disposition == :killed end),
     results != [] and Enum.all?(results, fn {_, confirmed?, _} -> confirmed? end)}
  end

  # -- flavour resolution ----------------------------------------------------

  defp flavour(shell_path) do
    case :persistent_term.get(cache_key(), :unknown) do
      :unknown ->
        resolved = probe(shell_path)
        :persistent_term.put(cache_key(), resolved)
        resolved

      cached ->
        cached
    end
  end

  defp cache_key, do: {__MODULE__, :flavour}

  defp probe(shell_path) do
    case script_path() do
      nil -> :none
      path -> Enum.find(preference(), :none, &works?(path, &1, shell_path))
    end
  end

  # BSD hosts are tried BSD-form first and glibc/musl hosts util-linux-form
  # first, purely to spend one fork instead of two on the common case. Either
  # order reaches the same verdict, because the probe is what decides.
  defp preference do
    case :os.type() do
      {:unix, os} when os in [:darwin, :freebsd, :openbsd, :netbsd] -> @flavours
      _ -> Enum.reverse(@flavours)
    end
  end

  defp works?(path, flavour, shell_path) do
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :in,
        :exit_status,
        :stderr_to_stdout,
        {:args, args(flavour, shell_path, @probe_command)},
        {:env, env(flavour, shell_path)}
      ])

    probe_status(port) == @probe_status
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp probe_status(port) do
    receive do
      {^port, {:data, _ignored}} -> probe_status(port)
      {^port, {:exit_status, status}} -> status
    after
      @probe_timeout_ms ->
        SpawnedPort.close(port)
        :timeout
    end
  end

  # `-q` suppresses the "Script started/done" banner, which would otherwise be
  # indistinguishable from the command's own output. util-linux needs `-e` to
  # report the child's status instead of its own; BSD does that by default and
  # has no such flag.
  defp args(:bsd, shell_path, command),
    do: ["-q", "/dev/null", shell_path, "-c", command]

  defp args(:util_linux, _shell_path, command),
    do: ["-q", "-e", "-c", command, "/dev/null"]

  defp env(:bsd, _shell_path), do: []

  defp env(:util_linux, shell_path),
    do: [{~c"SHELL", String.to_charlist(shell_path)}]

  defp script_path, do: System.find_executable("script")

  # -- process table ---------------------------------------------------------

  defp children_of(ps_output, parent) do
    ps_output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&child_pid(&1, parent))
  end

  defp child_pid(line, parent) do
    with [pid, ppid] <- line |> String.split(" ", trim: true) |> Enum.take(2),
         {pid, ""} <- Integer.parse(pid),
         {^parent, ""} <- Integer.parse(ppid),
         true <- pid > 1 do
      [pid]
    else
      _ -> []
    end
  end
end
