defmodule Raxol.Agent.Interrupt do
  @moduledoc """
  U5 — Interrupt is a **staged supervised kill** of a running turn/tool (AD-12).

  This module freezes the observable contract the U5-R red suite is authored
  against — a stable staging vocabulary + a behaviour — AND carries the U5-I
  implementation of `interrupt/3` (the staged supervised kill) built to satisfy
  it. The reds and the implementation reference one source of truth.

  ## What interrupt IS (from the dispositions + the U5 spike)

  Interrupt is not a flag the loop polls. It is a bounded escalation, each stage
  a **durable event** (the staging is observable in the journal):

      cooperative signal  →  bounded wait  →  OS process-group SIGKILL

  mapped to the vocabulary below:

    * `:interrupt_signaled` — the cooperative cancel request (group SIGTERM);
      a well-behaved tool stops here.
    * `:interrupt_waited`   — the bounded grace window elapsed without the tool
      exiting cooperatively (the empirical regime gap is orders of magnitude:
      a nice tool exits in ~2–11 ms, a rogue one never; the exact grace value
      is a per-tool policy knob, not a contract, see `default_grace_ms/0`).
    * `:interrupt_killed`   — the hard **process-group** SIGKILL landed and OS
      death was confirmed **out-of-band** (`ps`), never by trusting
      `:exit_status`. This is the **kill-complete** fence.
    * `:interrupt_kill_failed` — the OS kill signal did NOT land: a `kill`
      shell-out reported a non-zero status, or the kill path threw. It is
      emitted **in place of** `:interrupt_killed` so the journal never claims a
      kill that did not happen — the kill-complete fence is withheld,
      `killed?`/`confirmed_dead?` stay `false`, and post-kill quiescence is never
      *falsely* claimed. The cancellation intent is still recorded by the
      trailing `:turn_canceled` (the turn is over either way; what changed is the
      truthfulness of the kill claim).
    * `:turn_canceled`      — the terminal turn bracket carrying `%{reason}`
      (new loop vocabulary; already frozen into the journal's CONVERSATIONAL
      tip set by `harness-freeze-contracts.md` §1.1).

  ## The two laws U5-R pins

  1. **Effectiveness (the spike verdict).** Killing the BEAM process that owns
     the Port buys nothing against a hostile tool — `Port.close` /
     `Process.exit(owner, :kill)` leave the OS process alive and orphan its
     grandchild, and a surviving grandchild forges "`:exit_status` never
     arrived". The ONLY thing that works is the OS **process-group** SIGKILL
     (`kill -9 -<os_pid>`; BEAM already makes each port program its own pgroup
     leader, so `pgid == os_pid`), confirmed dead at the OS level. **Never trust
     `:exit_status` (or its absence) as the death signal.**

  2. **Post-kill quiescence (the no-zombie-emission law).** After the
     `:interrupt_killed` (kill-complete) event, NO `item_delta` / `item_completed`
     / tool-result event for that turn may **ever** appear. A late result folded
     out of the journal after kill-complete is a contract violation.

  ## The behaviour seam

  `interrupt/3` takes:

    * a `t:tool_ref/0` — the turn id plus (when a shell tool is running) the
      `Port` and its captured `os_pid`. `port`/`os_pid` are `nil` when the
      interrupt lands mid-provider-stream (nothing to group-kill; the loop is
      simply canceled and `:turn_canceled` emitted with no trailing output).
    * a `t:sink/0` — the durable-emit callback. In production this reaches the
      journal via `EmitBridge`/`SessionStreamer`; the U5-R red suite passes a
      `Raxol.Agent.Journal.FileStore`-backed sink so the staged trace is
      fold-checkable without the full session tree. Either way, **each stage
      emits a durable event through this seam** — that IS the "staging is
      observable" contract.

  `interrupt/3` implements this behaviour; the U5-R reds run green against it.
  """

  @signal :interrupt_signaled
  @wait :interrupt_waited
  @kill :interrupt_killed
  @kill_failed :interrupt_kill_failed
  @terminal :turn_canceled
  @default_grace_ms 300

  # Executable for the mutating `kill` shell-outs. Overridable via
  # `config :raxol_agent, :interrupt_kill_sh` so a test can force an OS-level
  # signal failure (a permission-denied kill) without an unkillable live
  # process. Only the `kill` calls honor this seam — every `ps`/pgid read uses
  # the real binary, so liveness and pgid derivation stay truthful.
  @kill_sh "/bin/sh"

  @typedoc "The three staged-kill event types, in escalation order."
  @type stage :: :interrupt_signaled | :interrupt_waited | :interrupt_killed

  @typedoc "The terminal turn bracket emitted once the kill is complete."
  @type terminal :: :turn_canceled

  @typedoc "Why the turn was canceled (carried in the `:turn_canceled` payload)."
  @type reason :: atom() | {atom(), term()}

  @typedoc """
  A handle on the turn (and its running tool, if any) to interrupt.

    * `:turn_id` — the turn whose staged events all share this id.
    * `:port` / `:os_pid` — the running shell tool's Port and captured OS pid;
      both `nil` when no tool is running (mid-provider-stream interrupt).
    * `:grace_ms` — optional per-tool override of `default_grace_ms/0`.
  """
  @type tool_ref :: %{
          required(:turn_id) => String.t(),
          optional(:port) => port() | nil,
          optional(:os_pid) => non_neg_integer() | nil,
          optional(:grace_ms) => pos_integer()
        }

  @typedoc """
  The durable-emit callback. Called once per staged event and once for the
  terminal `:turn_canceled`; returns `:ok`. This is the boundary at which "each
  stage emits a durable event" is satisfied.
  """
  @type sink :: (stage() | terminal(), map() -> :ok)

  @typedoc """
  The result of a staged kill.

    * `:stages` — the staged event types actually emitted, in order.
    * `:reason` — the `:turn_canceled` reason.
    * `:killed?` — a group SIGKILL was issued (false when there was no tool).
    * `:confirmed_dead?` — OS-level death was confirmed **out-of-band**, never
      inferred from `:exit_status`.
  """
  @type outcome :: %{
          turn_id: String.t(),
          stages: [stage() | :interrupt_kill_failed],
          reason: reason(),
          os_pid: non_neg_integer() | nil,
          killed?: boolean(),
          confirmed_dead?: boolean()
        }

  @doc """
  Run the staged supervised kill for `tool_ref`, emitting each stage through
  `sink`. Implemented by `interrupt/3` (and by the U5-R control injectors).
  """
  @callback interrupt(tool_ref(), sink(), keyword()) ::
              {:ok, outcome()} | {:error, term()}

  @doc """
  Staged supervised kill entry point — the U5-I implementation (AD-12).

  Drives the turn (and its running shell tool, if any) through the staged
  shutdown and emits each stage as a durable event through `sink`:

      cooperative group SIGTERM  →  bounded grace window  →  group SIGKILL

  Escalation is **conditional** (the substantive half of "staged"): after the
  cooperative signal a real tool gets its grace window to exit on its own. If it
  does, the kill short-circuits — `:interrupt_signaled` then straight to
  `:turn_canceled`, no wait/kill stage (per this module's own contract: the wait
  stage IS "the grace window elapsed WITHOUT the tool exiting"). Only a tool that
  survives the window escalates: journal `:interrupt_waited`, group-SIGKILL,
  confirm OS-level death **out-of-band** (`ps`, never `:exit_status`), then
  `:interrupt_killed` and `:turn_canceled`.

  A tool-less interrupt (mid-provider-stream: `os_pid`/`port` `nil`) has nothing
  to signal or wait on and always runs the full 4-stage bookkeeping sequence
  straight through (the kill stage is a no-op fence in that case), then cancels
  with no trailing output.

  Options:

    * `:reason` — the `:turn_canceled` reason (default `:interrupted`).
    * `:actor` — who requested the interrupt; threaded into each emitted
      payload's `:actor` field when present (U11's optional actor attribution).

  Never raises on an OS-level failure mid-kill: the kill path is guarded so a
  failed signal (`kill` returned non-zero) or a thrown kill still terminates the
  turn with `:turn_canceled`, keeping post-kill quiescence intact. But it does
  NOT forge the kill-complete fence: a failed/thrown kill emits
  `:interrupt_kill_failed` (not `:interrupt_killed`) with `killed?` and
  `confirmed_dead?` both `false`, so the journal never claims a kill that did not
  happen. The BEAM process that owns the Port is never used as the death signal
  — a hostile tool survives BEAM teardown, so only the OS group-kill,
  OS-confirmed, counts, and OS confirmation is trusted **only when the kill
  signal itself succeeded** (a failed signal cannot claim a recycled pid's
  absence as its own success; the residual ABA window is documented on
  `await_dead/2`).
  """
  @spec interrupt(tool_ref(), sink(), keyword()) ::
          {:ok, outcome()} | {:error, term()}
  def interrupt(tool_ref, sink, opts \\ [])

  def interrupt(%{turn_id: turn_id} = ref, sink, opts)
      when is_binary(turn_id) and is_function(sink, 2) do
    reason = Keyword.get(opts, :reason, :interrupted)
    grace_ms = Map.get(ref, :grace_ms) || @default_grace_ms

    signal(ref)
    emit(sink, @signal, %{}, opts)

    case cooperative_exit(ref, grace_ms) do
      {:short_circuit, os_pid} ->
        emit(sink, @terminal, %{reason: reason}, opts)

        {:ok,
         %{
           turn_id: turn_id,
           stages: [@signal],
           reason: reason,
           os_pid: os_pid,
           killed?: false,
           confirmed_dead?: true
         }}

      :escalate ->
        emit(sink, @wait, %{grace_ms: grace_ms}, opts)

        {disposition, confirmed?, os_pid} = hard_kill(ref)
        kill_stage = kill_stage_for(disposition)

        emit(sink, kill_stage, %{os_pid: os_pid}, opts)
        emit(sink, @terminal, %{reason: reason}, opts)

        {:ok,
         %{
           turn_id: turn_id,
           stages: [@signal, @wait, kill_stage],
           reason: reason,
           os_pid: os_pid,
           killed?: disposition == :killed,
           confirmed_dead?: confirmed?
         }}
    end
  end

  def interrupt(tool_ref, _sink, _opts) do
    {:error, {:invalid_tool_ref, tool_ref}}
  end

  # The kill-complete fence reflects the truth of the hard kill: a genuine group
  # SIGKILL (or the tool-less no-op bookkeeping fence) lands `:interrupt_killed`;
  # a failed/thrown signal lands the distinct `:interrupt_kill_failed` so the
  # journal never claims a kill that did not happen.
  defp kill_stage_for(:failed), do: @kill_failed
  defp kill_stage_for(_), do: @kill

  @doc "The stage-1 event type — cooperative cancel (group SIGTERM)."
  @spec signal_stage() :: :interrupt_signaled
  def signal_stage, do: @signal

  @doc "The stage-2 event type — the bounded grace window elapsed."
  @spec wait_stage() :: :interrupt_waited
  def wait_stage, do: @wait

  @doc "The stage-3 event type — group SIGKILL landed, OS death confirmed (kill-complete)."
  @spec kill_stage() :: :interrupt_killed
  def kill_stage, do: @kill

  @doc """
  The kill-failure fence — emitted in place of `kill_stage/0` when the OS kill
  signal did not land (a `kill` returned non-zero, or the kill path threw). Not
  part of the frozen success `sequence/0`; it is the honest alternative to a
  forged `:interrupt_killed`.
  """
  @spec kill_failed_stage() :: :interrupt_kill_failed
  def kill_failed_stage, do: @kill_failed

  @doc "The three staged-kill event types, in escalation order."
  @spec stages() :: [stage()]
  def stages, do: [@signal, @wait, @kill]

  @doc "The terminal turn-bracket event type (`:turn_canceled`)."
  @spec terminal() :: :turn_canceled
  def terminal, do: @terminal

  @doc """
  The full observable sequence a staged kill emits into the journal, in order:
  `[:interrupt_signaled, :interrupt_waited, :interrupt_killed, :turn_canceled]`.
  """
  @spec sequence() :: [stage() | terminal()]
  def sequence, do: stages() ++ [@terminal]

  @doc """
  Default grace window (ms) between the cooperative signal and the hard kill.

  Policy, not contract: the spike found the nice/rogue regime gap is orders of
  magnitude, so the exact value is not delicate. The reds assert the wait
  **stage** happens, never a specific latency.
  """
  @spec default_grace_ms() :: pos_integer()
  def default_grace_ms, do: @default_grace_ms

  # --- staging internals -----------------------------------------------------

  # Emit one staged event through the durable sink, threading actor attribution
  # into the payload when the caller supplied it (U11's optional :actor opt).
  defp emit(sink, type, payload, opts) do
    payload =
      case Keyword.get(opts, :actor) do
        nil -> payload
        actor -> Map.put(payload, :actor, actor)
      end

    sink.(type, payload)
  end

  # Stage 1 — the cooperative cancel request. A real tool gets the OS
  # process-group SIGTERM (signaling just the top pid does NOT cascade to the
  # group). A tool-less interrupt (mid-provider-stream) has nothing to signal;
  # the loop is simply canceled.
  defp signal(%{os_pid: os_pid}) when is_integer(os_pid) do
    _ = group_signal(os_pid, "-TERM")
    :ok
  end

  defp signal(_ref), do: :ok

  # Did the tool exit on its own inside the grace window? A real tool → poll the
  # OS out-of-band. Tool-less → nothing to wait for, always escalate to run the
  # full bookkeeping sequence.
  defp cooperative_exit(%{os_pid: os_pid}, grace_ms) when is_integer(os_pid) do
    if await_dead(os_pid, grace_ms), do: {:short_circuit, os_pid}, else: :escalate
  end

  defp cooperative_exit(_ref, _grace_ms), do: :escalate

  # Stage 3 — the hard kill. A real tool that survived the grace window gets the
  # OS process-group SIGKILL. Returns `{disposition, confirmed?, os_pid}`:
  #
  #   * `:killed`  — the kill signal landed (`kill` exited 0); death is then
  #     confirmed out-of-band (`ps`), never via `:exit_status`.
  #   * `:failed`  — the kill signal did NOT land (`kill` non-zero) or the kill
  #     path threw. The kill claim is a lie waiting to happen, so it is refused:
  #     the caller emits `:interrupt_kill_failed` instead of `:interrupt_killed`.
  #   * `:noop`    — a tool-less interrupt kills nothing (the kill stage is a
  #     no-op bookkeeping fence for the frozen 4-stage sequence).
  #
  # `confirmed?` is `false` unless the signal itself succeeded: a failed signal
  # must never claim a (possibly recycled) pid's absence as its own kill (the
  # ABA guard, finding U5-#5). Guarded so an OS-level failure mid-kill cannot
  # raise; a throw is treated as `:failed` (kill status unknown ⇒ not killed).
  defp hard_kill(%{os_pid: os_pid}) when is_integer(os_pid) do
    {signal_ok?, _mode} = group_signal(os_pid, "-9")
    disposition = if signal_ok?, do: :killed, else: :failed
    {disposition, signal_ok? and await_dead(os_pid), os_pid}
  rescue
    _ -> {:failed, false, os_pid}
  catch
    _, _ -> {:failed, false, os_pid}
  end

  defp hard_kill(_ref), do: {:noop, false, nil}

  # --- OS process-group primitives -------------------------------------------
  #
  # The spike verdict: only an OS process-group SIGKILL kills a hostile tool
  # clean, and `:exit_status` lies (a surviving grandchild forges "port open").
  # These shell out to POSIX `kill`/`ps` and are guarded so a group-kill can
  # never target this VM's own group or a pid that is not its group's leader.

  # Signal the tool's process group. Fires `kill <signal> -<os_pid>` only when
  # `os_pid` is genuinely the group leader (BEAM's per-port pgroup-leader
  # guarantee: pgid == os_pid) and the group is not this VM's own — otherwise
  # falls back to signaling the parent + enumerated children individually, so a
  # mis-derived pgid can never SIGKILL an unrelated group.
  #
  # Returns `{ok?, mode}` where `ok?` is whether the signal actually landed —
  # the `kill` exit status, NOT discarded (finding U5-#1). The group path is
  # `ok?` iff its single `kill` exited 0; the fallback is `ok?` iff the parent
  # kill AND every enumerated child kill exited 0. `{false, :noop}` when there
  # is nothing signalable (a non-positive/invalid pid).
  defp group_signal(os_pid, signal)
       when is_integer(os_pid) and os_pid > 1 and is_binary(signal) do
    if group_leader_safe?(os_pid) do
      {_out, status} =
        System.cmd(kill_sh(), ["-c", "kill #{signal} -#{os_pid} 2>/dev/null"])

      {status == 0, :group}
    else
      children = children_of(os_pid)

      {_out, status} =
        System.cmd(kill_sh(), ["-c", "kill #{signal} #{os_pid} 2>/dev/null"])

      child_ok? = children |> Enum.map(&individual_signal(&1, signal)) |> Enum.all?()
      {status == 0 and child_ok?, {:fallback, children}}
    end
  end

  defp group_signal(_os_pid, _signal), do: {false, :noop}

  # Signal one pid; returns whether the `kill` exited 0 (status not discarded).
  defp individual_signal(pid, signal) when is_integer(pid) and pid > 1 do
    {_out, status} = System.cmd(kill_sh(), ["-c", "kill #{signal} #{pid} 2>/dev/null"])
    status == 0
  end

  defp individual_signal(_pid, _signal), do: false

  defp kill_sh, do: Application.get_env(:raxol_agent, :interrupt_kill_sh, @kill_sh)

  # Poll `ps` until `os_pid` is gone or the budget elapses. The OS death oracle
  # — never the Port's `:exit_status`.
  #
  # Residual ABA window (finding U5-#5): this observes the *pid*, not identity,
  # so if a pid were reaped and recycled between our SIGKILL and the poll, `ps`
  # would report a different process by the same number as "gone". That window
  # is OS-inherent and not fully closable here; `hard_kill/1` bounds the damage
  # by trusting this confirmation ONLY when the kill signal itself succeeded, so
  # a *failed* kill can never launder a recycled pid's absence into a confirmed
  # death.
  defp await_dead(os_pid, budget_ms \\ 500)

  defp await_dead(os_pid, budget_ms) when budget_ms <= 0, do: dead?(os_pid)

  defp await_dead(os_pid, budget_ms) do
    if dead?(os_pid) do
      true
    else
      Process.sleep(10)
      await_dead(os_pid, budget_ms - 10)
    end
  end

  defp dead?(os_pid), do: not alive?(os_pid)

  defp alive?(os_pid) when is_integer(os_pid) do
    {_out, status} =
      System.cmd("ps", ["-p", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  # A group-kill of `-os_pid` is safe ONLY when os_pid is genuinely the group's
  # leader (pgid == os_pid) and that group is not this VM's own group.
  #
  # `@doc false` public (not private) so the U5 pgid regression can assert group
  # derivation works on this host — a nil pgid silently degrades group-kill to
  # the per-pid fallback, which is exactly the macOS regression finding U5-#4.
  @doc false
  def group_leader_safe?(os_pid) do
    with pgid when is_integer(pgid) <- pgid_of(os_pid),
         own when is_integer(own) <- own_pgid() do
      pgid == os_pid and pgid != own
    else
      _ -> false
    end
  end

  # Derive a pid's process-group id. The primary form (`-o pgid=`, empty-header
  # suppression) works on GNU ps and modern macOS/BSD ps; the fallback requests
  # the single labeled `pgid` column and parses the numeric value out of the
  # last row, for ps builds that reject `=`-suppressed headers (finding U5-#4:
  # a nil pgid here loses the group-kill path on macOS/BSD). `@doc false` public
  # for the regression test.
  @doc false
  def pgid_of(pid) do
    pid_s = Integer.to_string(pid)
    pgid_bare(["-o", "pgid=", "-p", pid_s]) || pgid_labeled(["-o", "pgid", "-p", pid_s])
  end

  # `-o pgid=` → a single bare number on stdout (or empty on an unsupported ps).
  defp pgid_bare(args) do
    case System.cmd("ps", args, stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> parse_int()
      _ -> nil
    end
  end

  # `-o pgid` → header row + a data row whose last whitespace token is the pgid.
  defp pgid_labeled(args) do
    case System.cmd("ps", args, stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> List.last()
        |> case do
          nil -> nil
          line -> line |> String.trim() |> parse_int()
        end

      _ ->
        nil
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
          case line |> String.split(~r/\s+/, trim: true) |> Enum.map(&parse_int/1) do
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
end
