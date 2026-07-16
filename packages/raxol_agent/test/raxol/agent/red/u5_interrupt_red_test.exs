defmodule Raxol.Agent.Red.U5InterruptRedTest do
  @moduledoc """
  U5-R — permanent **failing-first** contour reds for U5 "Interrupt = staged
  supervised kill" (AD-12), authored BEFORE the implementation exists, against
  the frozen contract in `docs/proposals/in-flight/harness-roadmap.md` (U5),
  `harness-research/spike-u5-kill.md`, and `harness-freeze-contracts.md`.

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
    base = Path.join(System.tmp_dir!(), "raxol_u5_red_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  describe "P1/P2 — staged event trace (pure journal, no tool Port)" do
    test "signal → wait → kill → turn_canceled are journaled in order under one turn_id", %{
      base: base
    } do
      {turn_id, dir, sink} = open_turn(base)

      # A turn is live and streaming when the interrupt lands.
      seed(sink, :turn_started, %{prompt: "long task"})
      seed(sink, :item_delta, %{chunk: "working"})

      {:ok, _outcome} =
        Interrupt.interrupt(%{turn_id: turn_id, port: nil, os_pid: nil}, sink, [])

      Contours.assert_staging!(Contours.records(dir), turn_id)
    end

    test "the turn terminates :turn_canceled carrying a reason", %{base: base} do
      {turn_id, dir, sink} = open_turn(base)
      seed(sink, :turn_started, %{prompt: "long task"})

      {:ok, outcome} =
        Interrupt.interrupt(%{turn_id: turn_id, port: nil, os_pid: nil}, sink, [])

      Contours.assert_turn_canceled!(Contours.records(dir), turn_id, outcome)
    end
  end

  describe "P4 — post-kill quiescence (the no-zombie-emission law)" do
    test "no item_delta/item_completed/tool_result for the turn after kill-complete", %{
      base: base
    } do
      {turn_id, dir, sink} = open_turn(base)

      # Pre-kill output exists (non-vacuous): the tool produced a result before
      # the interrupt. Quiescence forbids any output AFTER kill-complete.
      seed(sink, :turn_started, %{prompt: "long task"})
      seed(sink, :item_completed, %{item_type: "tool_result", result: "partial"})

      {:ok, _outcome} =
        Interrupt.interrupt(%{turn_id: turn_id, port: nil, os_pid: nil}, sink, [])

      Contours.assert_quiescent!(Contours.records(dir), turn_id)
    end
  end

  describe "P3b — mid-provider-stream interrupt (no tool Port)" do
    test "the turn cancels with no trailing output after turn_canceled", %{base: base} do
      {turn_id, dir, sink} = open_turn(base)

      # Mid-stream: deltas were flowing when the cancel arrived.
      seed(sink, :turn_started, %{prompt: "stream please"})
      seed(sink, :item_delta, %{chunk: "half a sen"})

      {:ok, _outcome} =
        Interrupt.interrupt(%{turn_id: turn_id, port: nil, os_pid: nil}, sink, [])

      Contours.assert_no_trailing_output!(Contours.records(dir), turn_id)
    end
  end

  describe "P3/P5 — kill effective mid-shell-Port (real OS processes)" do
    @tag :unix_only
    test "a rogue tool that ignores SIGTERM is group-killed and OS-confirmed dead", %{base: base} do
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
    test "the OS process AND its grandchild are gone — zero orphans (spike ground truth)", %{
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
    test "a kill whose signal fails journals :interrupt_kill_failed, never a killed success", %{
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

  # --- helpers ---------------------------------------------------------------

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
