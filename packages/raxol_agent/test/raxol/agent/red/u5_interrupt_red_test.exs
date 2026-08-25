defmodule Raxol.Agent.Red.U5InterruptRedTest do
  @moduledoc """
  U5-R — permanent **failing-first** contour reds for U5 "Interrupt = staged
  supervised kill" (AD-12), authored BEFORE the implementation exists,
  against the frozen contract and the staged-kill spike research.

  Every test here drives the real `Raxol.Agent.Interrupt`. The suite was authored
  **failing-first** (`@moduletag :harness_red`, excluded from CI) against the
  frozen contract while `interrupt/3` was still an unimplemented skeleton;
  nothing here is fitted to an implementation, the implementation is built to
  satisfy these. U5-I (AD-12, staged supervised kill) has since landed and
  implemented the behaviour, so the suite now runs GREEN in CI (the
  `:harness_red` tag is removed).

  Positive contours pinned:

    * P1 — staged event sequence (signal → wait → kill → turn_canceled), each
      journaled, in order, under one `turn_id`.
    * P2 — the turn terminates `:turn_canceled` with a reason.
    * P3 — the kill is effective mid-shell-Port: a rogue tool that never stops
      cooperatively is group-killed, OS-confirmed, zero orphans.
    * P3b — the kill is effective mid-provider-stream (no tool Port): the turn
      cancels with no trailing output event.
    * P4 — post-kill quiescence: no output event for the turn after kill-complete.
    * P5 — the OS process (and its grandchild) is actually gone — the spike's
      process-group ground truth, not `:exit_status`.
    * P6 — kill-claim integrity: a failed OS kill journals
      `:interrupt_kill_failed`, never a forged `:interrupt_killed`.
    * P7 — pgid derivation works on this host (group-kill, not the fallback).
    * P8 — the degraded per-pid fallback never claims a confirmed group kill
      (adversarial-review regression: confirmation must observe the GROUP).
    * P9 — the liveness oracle is state-aware: a zombie is dead, not alive.
    * P10 — a sink failure after the kill converts to an error return carrying
      the OS truth; it never raises out of the staged kill.

  The `:unix_only` tests spawn real OS processes; they are additionally guarded
  by that tag (auto-excluded on Windows).
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.Interrupt.Contours
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.KillLab

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "raxol_u5_red_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  describe "P1/P2 — staged event trace (pure journal, no tool Port)" do
    test "signal → wait → kill → turn_canceled are journaled in order under one turn_id",
         %{
           base: base
         } do
      {turn_id, dir, sink} = open_turn(base)

      # A turn is live and streaming when the interrupt lands.
      seed(sink, :turn_started, %{prompt: "long task"})
      seed(sink, :item_delta, %{chunk: "working"})

      {:ok, _outcome} =
        Interrupt.interrupt(
          %{turn_id: turn_id, port: nil, os_pid: nil},
          sink,
          []
        )

      Contours.assert_staging!(Contours.records(dir), turn_id)
    end

    test "the turn terminates :turn_canceled carrying a reason", %{base: base} do
      {turn_id, dir, sink} = open_turn(base)
      seed(sink, :turn_started, %{prompt: "long task"})

      {:ok, outcome} =
        Interrupt.interrupt(
          %{turn_id: turn_id, port: nil, os_pid: nil},
          sink,
          []
        )

      Contours.assert_turn_canceled!(Contours.records(dir), turn_id, outcome)
    end
  end

  describe "P4 — post-kill quiescence (the no-zombie-emission law)" do
    test "no item_delta/item_completed/tool_result for the turn after kill-complete",
         %{
           base: base
         } do
      {turn_id, dir, sink} = open_turn(base)

      # Pre-kill output exists (non-vacuous): the tool produced a result before
      # the interrupt. Quiescence forbids any output AFTER kill-complete.
      seed(sink, :turn_started, %{prompt: "long task"})

      seed(sink, :item_completed, %{item_type: "tool_result", result: "partial"})

      {:ok, _outcome} =
        Interrupt.interrupt(
          %{turn_id: turn_id, port: nil, os_pid: nil},
          sink,
          []
        )

      Contours.assert_quiescent!(Contours.records(dir), turn_id)
    end
  end

  describe "P3b — mid-provider-stream interrupt (no tool Port)" do
    test "the turn cancels with no trailing output after turn_canceled", %{
      base: base
    } do
      {turn_id, dir, sink} = open_turn(base)

      # Mid-stream: deltas were flowing when the cancel arrived.
      seed(sink, :turn_started, %{prompt: "stream please"})
      seed(sink, :item_delta, %{chunk: "half a sen"})

      {:ok, _outcome} =
        Interrupt.interrupt(
          %{turn_id: turn_id, port: nil, os_pid: nil},
          sink,
          []
        )

      Contours.assert_no_trailing_output!(Contours.records(dir), turn_id)
    end
  end

  describe "P3/P5 — kill effective mid-shell-Port (real OS processes)" do
    @tag :unix_only
    test "a rogue tool that ignores SIGTERM is group-killed and OS-confirmed dead",
         %{base: base} do
      lab = KillLab.spawn_rogue(sleep: 30)
      on_exit(fn -> KillLab.reap(lab) end)

      {turn_id, dir, sink} = open_turn(base)
      seed(sink, :turn_started, %{prompt: "run the rogue tool"})

      {:ok, outcome} =
        Interrupt.interrupt(
          %{turn_id: turn_id, port: lab.port, os_pid: lab.os_pid, grace_ms: 50},
          sink,
          []
        )

      # Effectiveness contour: OS ground truth, plus the staged trace present.
      Contours.assert_effective!(lab, outcome)
      Contours.assert_staging!(Contours.records(dir), turn_id)
    end

    @tag :unix_only
    test "the OS process AND its grandchild are gone — zero orphans (spike ground truth)",
         %{
           base: base
         } do
      lab = KillLab.spawn_rogue(sleep: 30)
      on_exit(fn -> KillLab.reap(lab) end)

      {turn_id, _dir, sink} = open_turn(base)
      seed(sink, :turn_started, %{prompt: "run the rogue tool"})

      {:ok, _outcome} =
        Interrupt.interrupt(
          %{turn_id: turn_id, port: lab.port, os_pid: lab.os_pid, grace_ms: 50},
          sink,
          []
        )

      assert KillLab.await_dead(lab.os_pid),
             "the tool's top process survived the interrupt"

      assert KillLab.dead?(lab.child_pid),
             "the tool's sleep grandchild was orphaned — the kill must reach the " <>
               "whole process group, not just the top pid"
    end
  end

  describe "P6 — kill-claim integrity (the OS kill signal fails)" do
    @tag :unix_only
    test "a kill whose signal fails journals :interrupt_kill_failed, never a killed success",
         %{
           base: base
         } do
      # Simulate an OS-level signal failure (e.g. a permission-denied kill) by
      # pointing the `kill` shell-out at `false`: every kill exits non-zero, the
      # rogue tool survives, and the staged kill must report the TRUTH — an
      # :interrupt_kill_failed fence (not :interrupt_killed), killed? false,
      # confirmed_dead? false. The pre-fix code discarded the kill exit status
      # and emitted :interrupt_killed unconditionally; this arm pins that closed.
      false_bin = System.find_executable("false") || "/usr/bin/false"
      prev = Application.get_env(:raxol_agent, :interrupt_kill_sh)
      Application.put_env(:raxol_agent, :interrupt_kill_sh, false_bin)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:raxol_agent, :interrupt_kill_sh)
          v -> Application.put_env(:raxol_agent, :interrupt_kill_sh, v)
        end
      end)

      lab = KillLab.spawn_rogue(sleep: 30)
      # Reap with the real shell (KillLab.reap does not honor the seam), so the
      # simulated-failure tool is not actually leaked.
      on_exit(fn -> KillLab.reap(lab) end)

      {turn_id, dir, sink} = open_turn(base)
      seed(sink, :turn_started, %{prompt: "run the rogue tool"})

      {:ok, outcome} =
        Interrupt.interrupt(
          %{turn_id: turn_id, port: lab.port, os_pid: lab.os_pid, grace_ms: 30},
          sink,
          []
        )

      refute outcome.killed?, "a failed OS kill must not report killed? = true"

      refute outcome.confirmed_dead?,
             "a failed OS kill must not claim OS-confirmed death (finding U5-#5 ABA guard)"

      Contours.assert_kill_failed!(Contours.records(dir), turn_id)

      # Ground truth: the tool the (simulated-failed) kill never touched is alive.
      assert KillLab.alive?(lab.os_pid),
             "the false-kill test process should still be alive — the kill was a no-op"
    end
  end

  describe "P7 — pgid derivation works on this host (group-kill, not the per-pid fallback)" do
    @tag :unix_only
    test "pgid_of returns a numeric pgid for a live child and the group path is chosen" do
      lab = KillLab.spawn_rogue(sleep: 30)
      on_exit(fn -> KillLab.reap(lab) end)

      pgid = Interrupt.pgid_of(lab.os_pid)

      assert is_integer(pgid) and pgid > 1,
             "pgid_of derived no numeric pgid for #{lab.os_pid} — group-kill silently " <>
               "degrades to the per-pid fallback (the macOS GNU-ps regression, U5-#4)"

      # BEAM makes each Port its own process-group leader → pgid == os_pid, so
      # the safe OS process-group kill path is taken, not the individual-signal
      # fallback that leaks the grandchild.
      assert pgid == lab.os_pid,
             "a BEAM port must be its own group leader (pgid == os_pid); got pgid=#{pgid}"

      assert Interrupt.group_leader_safe?(lab.os_pid),
             "group_leader_safe? rejected a genuine group leader — the kill would fall " <>
               "back to per-pid signalling instead of the process-group SIGKILL"
    end
  end

  describe "P8 — degraded per-pid fallback never claims a confirmed group kill" do
    @tag :unix_only
    test "a non-group-leader target (fallback path) yields kill_failed, not a false killed",
         %{base: base} do
      lab = KillLab.spawn_rogue_nested(sleep: 30)
      on_exit(fn -> KillLab.reap(lab) end)

      # Target the MID shell: pgid != pid, so the kill must take the per-pid
      # fallback — the same degraded path a host with broken pgid derivation
      # takes for EVERY kill. MID's grandchild sleep is what a depth-1 sweep
      # misses; the pre-fix code still confirmed death off the top pid alone
      # and journaled a false :interrupt_killed while the grandchild lived.
      refute Interrupt.group_leader_safe?(lab.child_pid),
             "test premise broken: the mid shell must not be its own group leader"

      {turn_id, dir, sink} = open_turn(base)
      seed(sink, :turn_started, %{prompt: "run the rogue tool"})

      {:ok, outcome} =
        Interrupt.interrupt(
          %{
            turn_id: turn_id,
            port: lab.port,
            os_pid: lab.child_pid,
            grace_ms: 50
          },
          sink,
          []
        )

      refute outcome.killed?,
             "a per-pid fallback sweep is not a group SIGKILL and must not report killed?"

      refute outcome.confirmed_dead?,
             "group death was never observable on the fallback path — confirming it " <>
               "off the top pid is the exact top-pid observation the effectiveness law condemns"

      Contours.assert_kill_failed!(Contours.records(dir), turn_id)
    end
  end

  describe "P11 — an orphan whose parent already exited is still reaped" do
    @tag :unix_only
    test "the group is resolved off the surviving group, not off the corpse's pgid" do
      # The commonest leak shape: the tool backgrounds something and exits. Its
      # own pid is a corpse, so a `ps -o pgid= -p <corpse>` read comes back
      # empty, the group-kill path is never taken, and the per-pid fallback's
      # ppid sweep cannot see the orphan either -- it was reparented to init the
      # moment its parent died. Both halves of the old derivation miss it.
      #
      # The surviving process GROUP still names it, which is what resolving via
      # `kill -0 -<pgid>` finds.
      lab = KillLab.spawn_orphaning(sleep: 30)
      on_exit(fn -> KillLab.reap(lab) end)

      assert KillLab.await_dead(lab.os_pid, 3_000),
             "test premise broken: the tool's top process should have exited on its own"

      assert KillLab.alive?(lab.child_pid),
             "test premise broken: the orphan should still be running"

      assert Interrupt.group_leader_safe?(lab.os_pid),
             "a corpse still leads a live group -- resolving the target off `ps` " <>
               "cannot see that, and drops to a sweep that cannot reach the orphan"

      {disposition, confirmed?, _os_pid} = Interrupt.kill_os_pid(lab.os_pid)

      assert KillLab.await_dead(lab.child_pid, 3_000),
             "the orphan survived the kill: this is the leak the group path exists to close"

      assert disposition == :killed
      assert confirmed?, "the group was signalled, so group death is observable"
    end
  end

  describe "P9 — the liveness oracle is state-aware (a zombie is dead, not alive)" do
    @tag :unix_only
    test "a killed-but-unreaped (zombie) child is reported dead, though ps -p exits 0" do
      lab = KillLab.spawn_zombie(sleep: 30)
      on_exit(fn -> KillLab.reap(lab) end)

      assert await(fn -> KillLab.zombie?(lab.child_pid) end, 3_000),
             "the short-lived child never became a zombie — cannot exercise the oracle"

      # Raw `ps -p` still exits 0 for a zombie: the pre-fix oracle called it
      # alive and burned the whole confirmation budget on an already-dead
      # process (confirmed_dead? false on a genuinely dead tool — a lie and a
      # flake vector on loaded machines).
      assert KillLab.alive?(lab.child_pid),
             "test premise broken: ps -p should still see the zombie"

      refute Interrupt.os_alive?(lab.child_pid),
             "a zombie is a KILLED process awaiting reap — the interrupt's " <>
               "liveness oracle must report it dead"
    end
  end

  describe "P10 — a sink failure after the kill never raises out of the staged kill" do
    test "a sink dying on the kill fence yields {:error, {:sink_failure, _, outcome}}",
         %{
           base: base
         } do
      {turn_id, dir, sink} = open_turn(base)
      seed(sink, :turn_started, %{prompt: "long task"})

      # The kill (here the tool-less bookkeeping fence) has already run when
      # the kill-stage emit fires; a journal-writer failure at that point must
      # not escape as a raise and leave the caller guessing whether the kill
      # happened — the OS truth rides back inside the error.
      kill = Interrupt.kill_stage()

      failing = fn
        ^kill, _payload -> raise "journal writer down"
        type, payload -> sink.(type, payload)
      end

      assert {:error, {:sink_failure, %RuntimeError{}, outcome}} =
               Interrupt.interrupt(
                 %{turn_id: turn_id, port: nil, os_pid: nil},
                 failing,
                 []
               )

      assert outcome.turn_id == turn_id
      assert Interrupt.kill_stage() in outcome.stages

      # The journal holds the pre-kill stages, and no forged records after the
      # sink died — the caller owns reconciliation, the journal never lies.
      types =
        for r <- Contours.records(dir), r["turn_id"] == turn_id, do: r["type"]

      assert "interrupt_signaled" in types
      assert "interrupt_waited" in types
      refute "interrupt_killed" in types
      refute "turn_canceled" in types
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp await(fun, budget_ms) do
    cond do
      fun.() ->
        true

      budget_ms <= 0 ->
        false

      true ->
        Process.sleep(20)
        await(fun, budget_ms - 20)
    end
  end

  # Open a fresh session journal + a durable sink for one turn.
  defp open_turn(base) do
    turn_id = "turn-#{System.unique_integer([:positive])}"
    session_id = "u5-red-#{System.unique_integer([:positive])}"
    {:ok, journal} = FileStore.open(session_id, base_dir: base)
    # The writer is linked to this test process; unlink so it survives to
    # on_exit (else it dies with the test and close/1 races a dead writer).
    Process.unlink(journal.writer)

    on_exit(fn ->
      try do
        if Process.alive?(journal.writer), do: FileStore.close(journal)
      catch
        :exit, _ -> :ok
      end
    end)

    sink = Contours.journal_sink(journal, session_id, turn_id)
    {turn_id, journal.dir, sink}
  end

  defp seed(sink, type, payload), do: sink.(type, payload)
end
