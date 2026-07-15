defmodule Raxol.Agent.Red.U5InterruptControlsTest do
  @moduledoc """
  U5-R negative controls — the tests that **test the U5-R reds**
  (`harness-invariants.md` meta-invariant 4: one mutation per contour must make
  its property fail). Unlike the positive reds these are NOT `:harness_red`:
  they RUN IN CI and stay green, because a green here means "the contour check
  correctly PASSES a correct staged kill and FAILS a broken one" — teeth that do
  not depend on U5-I existing.

  Each control follows the negative-control shape:

    1. run the CORRECT `Reference` staged kill → the contour passes (green on
       correct), then
    2. run the matching dead injector → the SAME contour raises (red on mutant),
       and record the fault site fired.

  Plus the meta layer: every named fault site is proven alive (m1), and a dead
  injector (armed-but-never-fired) fails loudly and dumps its seed/schedule (m2).

  The `:unix_only` control spawns real OS processes (the effectiveness contour is
  inherently an OS-level claim); the pure-journal controls are deterministic.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.Agent.Interrupt.Contours
  alias Raxol.Agent.Interrupt.Faults
  alias Raxol.Agent.Interrupt.Injectors.{LateResult, Reference, SkipWait, TrustExitStatus}
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.KillLab

  setup do
    base = Path.join(System.tmp_dir!(), "raxol_u5_ctl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    # A seed makes the pre-kill output count reproducible and is dumped on any
    # dead-injector failure (meta-inv 2).
    seed = System.unique_integer([:positive])
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    {:ok, base: base, seed: seed}
  end

  describe "staging contour — dead injector :skip_wait" do
    test "reference passes; skipping the wait stage fails the staging red", %{base: base, seed: seed} do
      harness = Faults.new()
      Faults.arm(harness, :skip_wait)

      # Green on correct.
      {t1, d1, s1} = open_turn(base)
      seed_output(s1, :turn_started, %{prompt: "task"})
      {:ok, _} = Reference.interrupt(%{turn_id: t1, port: nil, os_pid: nil}, s1, [])
      assert :ok = Contours.assert_staging!(Contours.records(d1), t1)

      # Red on mutant: signal → kill (no wait) breaks the ordered sequence.
      {t2, d2, s2} = open_turn(base)
      {:ok, _} = SkipWait.interrupt(%{turn_id: t2}, s2, faults: harness)

      err =
        assert_raise ExUnit.AssertionError, fn ->
          Contours.assert_staging!(Contours.records(d2), t2)
        end

      assert err.message =~ "staged-kill sequence"
      Faults.assert_all_fired!(harness, %{seed: seed, sites: [:skip_wait]})
    end
  end

  describe "quiescence contour — dead injector :late_result" do
    test "reference passes; a tool_result after kill-complete fails the quiescence red", %{
      base: base,
      seed: seed
    } do
      harness = Faults.new()
      Faults.arm(harness, :late_result)

      pre_kill = 1 + :rand.uniform(3)

      # Green on correct: pre-kill output, nothing after the kill fence.
      {t1, d1, s1} = open_turn(base)
      seed_output(s1, :turn_started, %{prompt: "task"})
      for _ <- 1..pre_kill, do: seed_output(s1, :item_completed, %{item_type: "tool_result"})
      {:ok, _} = Reference.interrupt(%{turn_id: t1, port: nil, os_pid: nil}, s1, [])
      assert :ok = Contours.assert_quiescent!(Contours.records(d1), t1)

      # Red on mutant: a zombie tool_result escapes the kill fence.
      {t2, d2, s2} = open_turn(base)
      seed_output(s2, :turn_started, %{prompt: "task"})
      for _ <- 1..pre_kill, do: seed_output(s2, :item_completed, %{item_type: "tool_result"})
      {:ok, _} = LateResult.interrupt(%{turn_id: t2}, s2, faults: harness)

      err =
        assert_raise ExUnit.AssertionError, fn ->
          Contours.assert_quiescent!(Contours.records(d2), t2)
        end

      assert err.message =~ "post-kill quiescence violated"
      Faults.assert_all_fired!(harness, %{seed: seed, pre_kill: pre_kill, sites: [:late_result]})
    end
  end

  describe "effectiveness contour — dead injector :trust_exit_status" do
    @tag :unix_only
    test "reference group-kill passes; trusting :exit_status leaves an orphan and fails the red", %{
      base: base,
      seed: seed
    } do
      harness = Faults.new()
      Faults.arm(harness, :trust_exit_status)

      # Green on correct: the process-group SIGKILL takes the whole subtree.
      ref_lab = KillLab.spawn_rogue(sleep: 30)
      on_exit(fn -> KillLab.reap(ref_lab) end)
      {t1, _d1, s1} = open_turn(base)

      {:ok, out1} =
        Reference.interrupt(
          %{turn_id: t1, port: ref_lab.port, os_pid: ref_lab.os_pid, grace_ms: 50},
          s1,
          []
        )

      assert :ok = Contours.assert_effective!(ref_lab, out1)
      assert KillLab.dead?(ref_lab.child_pid), "reference group-kill must reap the grandchild"

      # Red on mutant: top-pid-only kill orphans the grandchild; trusting
      # :exit_status forges "dead".
      bad_lab = KillLab.spawn_rogue(sleep: 30)
      on_exit(fn -> KillLab.reap(bad_lab) end)
      {t2, _d2, s2} = open_turn(base)

      {:ok, out2} =
        TrustExitStatus.interrupt(
          %{turn_id: t2, port: bad_lab.port, os_pid: bad_lab.os_pid},
          s2,
          faults: harness
        )

      err =
        assert_raise ExUnit.AssertionError, fn ->
          Contours.assert_effective!(bad_lab, out2)
        end

      assert err.message =~ "grandchild"
      assert KillLab.alive?(bad_lab.child_pid), "the orphan the mutant left must still be alive here"

      Faults.assert_all_fired!(harness, %{seed: seed, sites: [:trust_exit_status]})
    end
  end

  describe "meta — the harness proves itself" do
    test "an armed site that never fires fails loudly and dumps the seed/schedule (m1/m2)", %{
      seed: seed
    } do
      harness = Faults.new()
      Faults.arm(harness, :skip_wait)
      Faults.arm(harness, :late_result)
      # Only one of the two fires.
      Faults.record_fired(harness, :late_result)

      schedule = %{seed: seed, sites: [:skip_wait, :late_result]}

      err =
        assert_raise ExUnit.AssertionError, fn ->
          Faults.assert_all_fired!(harness, schedule)
        end

      assert err.message =~ "dead injector"
      assert err.message =~ "skip_wait"
      # m2: the failure carries the seed so the run reproduces.
      assert err.message =~ "seed: #{seed}"
    end

    test "the pure-journal fault sites are both alive (m1)", %{base: base} do
      harness = Faults.new()
      Faults.arm(harness, :skip_wait)
      Faults.arm(harness, :late_result)

      {t1, _d1, s1} = open_turn(base)
      {:ok, _} = SkipWait.interrupt(%{turn_id: t1}, s1, faults: harness)

      {t2, _d2, s2} = open_turn(base)
      {:ok, _} = LateResult.interrupt(%{turn_id: t2}, s2, faults: harness)

      fired = Faults.assert_all_fired!(harness, :m1_self_test)
      assert fired[:skip_wait] >= 1
      assert fired[:late_result] >= 1
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp open_turn(base) do
    turn_id = "turn-#{System.unique_integer([:positive])}"
    session_id = "u5-ctl-#{System.unique_integer([:positive])}"
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

  defp seed_output(sink, type, payload), do: sink.(type, payload)
end
