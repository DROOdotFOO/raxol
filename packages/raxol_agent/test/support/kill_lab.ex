defmodule Raxol.Agent.KillLab do
  @moduledoc """
  Real OS-process ground truth for the U5-R interrupt reds (spike topology
  from the staged-kill research spike).

  U5's load-bearing claim is an **OS-level** one — a hostile tool survives BEAM
  teardown and only dies to a process-group SIGKILL, and `:exit_status` lies.
  So U5-R cannot assert on BEAM state; it must observe the OS. This lab:

    * spawns a **rogue** shell tool that ignores SIGTERM/SIGINT and holds a
      long-lived `sleep` **grandchild** (the orphan bait), returning the tool's
      captured `os_pid` and the grandchild pid;
    * answers OS-level liveness via `ps` (never via the Port's `:exit_status`);
    * provides the two kill primitives the negative controls need to tell a
      correct group-kill from a `:exit_status`-trusting top-pid kill.

  ## Safety

  Every group-kill is guarded: it refuses unless `ps` confirms `pgid == os_pid`
  (BEAM's per-port pgroup-leader guarantee) AND the group is not this VM's own
  group — a mis-derived pgid must never be able to SIGKILL the test runner.
  `reap/1` is best-effort and never raises; register it in `on_exit` so a red
  test that dies before killing (the skeleton raises `:not_implemented`) never
  leaks a `sleep`.
  """

  @doc """
  Spawn a rogue shell tool: it traps SIGTERM/SIGINT, launches a `sleep`
  grandchild, prints the grandchild pid, then `wait`s. Returns
  `%{port: port, os_pid: os_pid, child_pid: child_pid}`.

  Options: `:sleep` (grandchild sleep seconds, default 30).
  """
  @spec spawn_rogue(keyword()) :: %{
          port: port(),
          os_pid: non_neg_integer(),
          child_pid: non_neg_integer()
        }
  def spawn_rogue(opts \\ []) do
    secs = Keyword.get(opts, :sleep, 30)
    cmd = "trap '' TERM INT; sleep #{secs} & echo RAXOL_CHILD $!; wait"
    spawn_tool(cmd)
  end

  @doc """
  Spawn a **cooperative** shell tool that also holds a `sleep` grandchild but
  does NOT trap signals — a well-behaved tool that still leaks its subprocess
  under a naive top-pid signal (spike gotcha #4). Same return shape.
  """
  @spec spawn_nice(keyword()) :: %{
          port: port(),
          os_pid: non_neg_integer(),
          child_pid: non_neg_integer()
        }
  def spawn_nice(opts \\ []) do
    secs = Keyword.get(opts, :sleep, 30)
    cmd = "sleep #{secs} & echo RAXOL_CHILD $!; wait"
    spawn_tool(cmd)
  end

  @doc """
  Spawn a rogue tool whose interesting subtree hangs off a **non-group-leader**
  mid shell: `bash (port, group leader) → sh MID (traps TERM/INT) → sh → sleep`.
  Returns `%{port:, os_pid:, child_pid:}` where `child_pid` is MID — a pid with
  `pgid != pid`, so signaling it forces the per-pid fallback path, and MID's
  *grandchild* `sleep` is exactly what a depth-1 child sweep misses. Used by
  the degraded-fallback claim regression.
  """
  @spec spawn_rogue_nested(keyword()) :: %{
          port: port(),
          os_pid: non_neg_integer(),
          child_pid: non_neg_integer()
        }
  def spawn_rogue_nested(opts \\ []) do
    secs = Keyword.get(opts, :sleep, 30)

    cmd =
      ~s[sh -c 'trap "" TERM INT; sh -c "sleep #{secs} & wait" & wait' & ] <>
        ~s[echo RAXOL_CHILD $!; wait]

    spawn_tool(cmd)
  end

  @doc """
  Spawn a tool that **exits immediately** after backgrounding its child, so the
  child is orphaned and reparented to init while the tool's own pid becomes a
  corpse. Returns `%{port:, os_pid:, child_pid:}`.

  The port stays OPEN throughout: ERTS withholds the exit status until the
  inherited stdout reaches EOF, and the orphan is still holding it, so
  `Port.info/2` goes on reporting a pid that has already been reaped.

  This is the topology a pgid-via-`ps` derivation cannot resolve -- `ps` cannot
  see a corpse, so the group is never found -- and that a ppid sweep cannot
  reach either, since the orphan's ppid is already `1`. Only the surviving
  process GROUP still names it.
  """
  @spec spawn_orphaning(keyword()) :: %{
          port: port(),
          os_pid: non_neg_integer(),
          child_pid: non_neg_integer()
        }
  def spawn_orphaning(opts \\ []) do
    secs = Keyword.get(opts, :sleep, 30)
    cmd = "sleep #{secs} & echo RAXOL_CHILD $!; exit 0"
    spawn_tool(cmd)
  end

  @doc """
  Spawn a tool that manufactures a **zombie**: a short-lived child exits under
  a parent (`exec sleep`) that never reaps it, so the child sits in STAT `Z`
  until the parent dies. Returns `%{port:, os_pid:, child_pid:}` where
  `child_pid` becomes the zombie. Used by the state-aware-liveness regression
  (`ps -p` exits 0 for a zombie; a liveness oracle must not call it alive).
  """
  @spec spawn_zombie(keyword()) :: %{
          port: port(),
          os_pid: non_neg_integer(),
          child_pid: non_neg_integer()
        }
  def spawn_zombie(opts \\ []) do
    secs = Keyword.get(opts, :sleep, 30)
    cmd = "sleep 0.2 & echo RAXOL_CHILD $!; exec sleep #{secs}"
    spawn_tool(cmd)
  end

  @doc "True iff `ps` reports `pid` in a zombie (`Z*`) state."
  @spec zombie?(non_neg_integer()) :: boolean()
  def zombie?(pid) when is_integer(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> String.starts_with?("Z")
      _ -> false
    end
  end

  defp spawn_tool(cmd) do
    port =
      Port.open(
        {:spawn_executable, bash()},
        [:binary, :exit_status, args: ["-c", cmd]]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> raise "port has no os_pid"
      end

    child_pid = await_child!(port, 2_000)
    %{port: port, os_pid: os_pid, child_pid: child_pid}
  end

  # Read the "RAXOL_CHILD <pid>" line the tool prints so the reds can assert on
  # the grandchild directly (the orphan the top-pid kill leaks).
  defp await_child!(port, timeout) do
    receive do
      {^port, {:data, data}} ->
        case Regex.run(~r/RAXOL_CHILD (\d+)/, data) do
          [_, pid] -> String.to_integer(pid)
          _ -> await_child!(port, timeout)
        end
    after
      timeout -> raise "rogue tool never reported its grandchild pid"
    end
  end

  @doc "True iff `ps -p <pid>` reports the process alive (a single, non-polling check)."
  @spec alive?(non_neg_integer()) :: boolean()
  def alive?(pid) when is_integer(pid) do
    {_out, status} =
      System.cmd("ps", ["-p", Integer.to_string(pid)], stderr_to_stdout: true)

    status == 0
  end

  @doc "True iff `ps` reports the process gone. The OS oracle — never `:exit_status`."
  @spec dead?(non_neg_integer()) :: boolean()
  def dead?(pid), do: not alive?(pid)

  @doc "Poll `ps` until `pid` is gone or `budget_ms` elapses; returns `true` if it died."
  @spec await_dead(non_neg_integer(), non_neg_integer()) :: boolean()
  def await_dead(pid, budget_ms \\ 500) do
    cond do
      dead?(pid) ->
        true

      budget_ms <= 0 ->
        false

      true ->
        Process.sleep(10)
        await_dead(pid, budget_ms - 10)
    end
  end

  @doc """
  The **wrong** kill a `:exit_status`-trusting implementation performs: SIGKILL
  the tool's **top** pid only, orphaning its grandchild (spike gotcha #2). Used
  by the dead injector; the grandchild survives and the effectiveness contour
  catches it.
  """
  @spec top_pid_kill(non_neg_integer()) :: :ok
  def top_pid_kill(os_pid) when is_integer(os_pid) and os_pid > 1 do
    _ = System.cmd("/bin/sh", ["-c", "kill -9 #{os_pid} 2>/dev/null"])
    :ok
  end

  @doc """
  The **correct** kill: the OS **process-group** SIGKILL (`kill -9 -<os_pid>`),
  used by the reference control to prove the effectiveness contour has a passing
  case. Guarded so it can never SIGKILL the test runner (see moduledoc). Returns
  `:group` when the group-kill fired, `{:fallback, ...}` when it declined and
  swept the tool + its enumerated children individually instead.
  """
  @spec group_kill(non_neg_integer()) ::
          :group | {:fallback, [non_neg_integer()]}
  def group_kill(os_pid), do: group_signal(os_pid, "-9")

  @doc """
  The **cooperative** signal: OS process-group SIGTERM (`kill -TERM -<os_pid>`)
  — the staging kill's SIGNAL-stage primitive. A well-behaved tool exits on
  this alone (spike: ~4-11ms); a rogue one ignores it and survives to the
  escalation. Signaling just the top pid does NOT cascade to the group (spike
  gotcha #4) — that's why this, like `group_kill/1`, always targets `-os_pid`.
  Guarded identically (see moduledoc).
  """
  @spec signal_group(non_neg_integer()) ::
          :group | {:fallback, [non_neg_integer()]}
  def signal_group(os_pid), do: group_signal(os_pid, "-TERM")

  defp group_signal(os_pid, signal)
       when is_integer(os_pid) and os_pid > 1 and is_binary(signal) do
    if group_leader_safe?(os_pid) do
      _ = System.cmd("/bin/sh", ["-c", "kill #{signal} -#{os_pid} 2>/dev/null"])
      :group
    else
      # Platform did not make the port a pgroup leader: sweep children by ppid
      # (while the parent is alive to give the linkage), then signal the parent.
      children = children_of(os_pid)
      _ = System.cmd("/bin/sh", ["-c", "kill #{signal} #{os_pid} 2>/dev/null"])
      Enum.each(children, &individual_signal(&1, signal))
      {:fallback, children}
    end
  end

  defp individual_signal(pid, signal) do
    _ = System.cmd("/bin/sh", ["-c", "kill #{signal} #{pid} 2>/dev/null"])
    :ok
  end

  @doc """
  Best-effort teardown — group-kill if safe, then belt-and-suspenders
  individual kills. Every shell-out is already `_ = System.cmd(...)` (status
  ignored, stderr silenced); nothing here is expected to raise, so this does
  NOT swallow exceptions with a bare rescue (repo convention against broad
  rescues) — a genuine crash here should surface, not `:ok`-through.
  """
  @spec reap(map()) :: :ok
  def reap(%{os_pid: os_pid} = lab) do
    if group_leader_safe?(os_pid) do
      _ = System.cmd("/bin/sh", ["-c", "kill -9 -#{os_pid} 2>/dev/null"])
    end

    _ = System.cmd("/bin/sh", ["-c", "kill -9 #{os_pid} 2>/dev/null"])

    if child = Map.get(lab, :child_pid),
      do: System.cmd("/bin/sh", ["-c", "kill -9 #{child} 2>/dev/null"])

    :ok
  end

  # A group-kill of -os_pid is safe ONLY when os_pid is genuinely the group's
  # leader (pgid == os_pid) and that group is not this VM's own group.
  defp group_leader_safe?(os_pid) do
    with pgid when is_integer(pgid) <- pgid_of(os_pid),
         own when is_integer(own) <- own_pgid() do
      pgid == os_pid and pgid != own
    else
      _ -> false
    end
  end

  defp pgid_of(pid) do
    case System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> parse_int()
      _ -> nil
    end
  end

  defp own_pgid, do: pgid_of(os_getpid())

  defp os_getpid, do: :os.getpid() |> to_string() |> String.to_integer()

  defp children_of(ppid) do
    case System.cmd("ps", ["-o", "pid=", "--ppid", Integer.to_string(ppid)],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_int/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        # BSD ps (macOS) lacks --ppid; fall back to a full-table scan.
        bsd_children_of(ppid)
    end
  end

  defp bsd_children_of(ppid) do
    case System.cmd("ps", ["-Ao", "pid=,ppid="], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case line
               |> String.split(~r/\s+/, trim: true)
               |> Enum.map(&parse_int/1) do
            [pid, ^ppid] when is_integer(pid) -> [pid]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp parse_int(str) do
    case Integer.parse(String.trim(str)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp bash, do: System.find_executable("bash") || "/bin/bash"
end
