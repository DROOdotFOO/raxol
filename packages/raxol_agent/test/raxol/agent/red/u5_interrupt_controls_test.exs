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

  alias Raxol.Agent.Interrupt.Injectors.{
    LateResult,
    NaiveEscalate,
    Reference,
    SkipWait,
    TrailingOutput,
    TrustExitStatus,
    TrustReason,
    WaitKillTransposed
  }

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
    test "reference passes; skipping the wait stage fails the staging red", %{
      base: base,
      seed: seed
    } do
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

      # Fixed, not randomized: quiescence must hold regardless of how much
      # pre-kill output there was, so randomness here buys no extra coverage
      # — it only makes failures harder to reproduce without the seed.
      pre_kill = 2

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
    test "reference group-kill passes; trusting :exit_status leaves an orphan and fails the red",
         %{
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

      assert KillLab.alive?(bad_lab.child_pid),
             "the orphan the mutant left must still be alive here"

      Faults.assert_all_fired!(harness, %{seed: seed, sites: [:trust_exit_status]})
    end
  end

  describe "staging contour — dead injector :wait_kill_transposed" do
    test "reference passes; a kill-before-wait transposition fails the staging red", %{
      base: base,
      seed: seed
    } do
      harness = Faults.new()
      Faults.arm(harness, :wait_kill_transposed)

      # Green on correct.
      {t1, d1, s1} = open_turn(base)
      seed_output(s1, :turn_started, %{prompt: "task"})
      {:ok, _} = Reference.interrupt(%{turn_id: t1, port: nil, os_pid: nil}, s1, [])
      assert :ok = Contours.assert_staging!(Contours.records(d1), t1)

      # Red on mutant: signal → kill → wait breaks the ordered sequence (a
      # transposition, distinct from :skip_wait's omission).
      {t2, d2, s2} = open_turn(base)
      {:ok, _} = WaitKillTransposed.interrupt(%{turn_id: t2}, s2, faults: harness)

      err =
        assert_raise ExUnit.AssertionError, fn ->
          Contours.assert_staging!(Contours.records(d2), t2)
        end

      assert err.message =~ "staged-kill sequence"
      Faults.assert_all_fired!(harness, %{seed: seed, sites: [:wait_kill_transposed]})
    end
  end

  describe "turn-canceled contour — dead injector :trust_reason" do
    test "reference passes; a wrong terminal record type fails the turn-canceled red", %{
      base: base,
      seed: seed
    } do
      harness = Faults.new()
      Faults.arm(harness, :trust_reason)

      # Green on correct.
      {t1, d1, s1} = open_turn(base)
      seed_output(s1, :turn_started, %{prompt: "task"})
      {:ok, out1} = Reference.interrupt(%{turn_id: t1, port: nil, os_pid: nil}, s1, [])
      assert :ok = Contours.assert_turn_canceled!(Contours.records(d1), t1, out1)

      # Red on mutant: the outcome carries the right :reason, but the journaled
      # terminal record is :turn_ended, not :turn_canceled.
      {t2, d2, s2} = open_turn(base)
      {:ok, out2} = TrustReason.interrupt(%{turn_id: t2}, s2, faults: harness)

      err =
        assert_raise ExUnit.AssertionError, fn ->
          Contours.assert_turn_canceled!(Contours.records(d2), t2, out2)
        end

      assert err.message =~ "did not terminate with turn_canceled"
      Faults.assert_all_fired!(harness, %{seed: seed, sites: [:trust_reason]})
    end
  end

  describe "no-trailing-output contour (P3b) — dead injector :trailing_output" do
    test "reference passes; a post-cancel stream chunk fails the mid-provider-stream red", %{
      base: base,
      seed: seed
    } do
      harness = Faults.new()
      Faults.arm(harness, :trailing_output)

      # Green on correct: mid-stream deltas before the cancel, nothing after.
      {t1, d1, s1} = open_turn(base)
      seed_output(s1, :turn_started, %{prompt: "stream please"})
      seed_output(s1, :item_delta, %{chunk: "half a sen"})
      {:ok, _} = Reference.interrupt(%{turn_id: t1, port: nil, os_pid: nil}, s1, [])
      assert :ok = Contours.assert_no_trailing_output!(Contours.records(d1), t1)

      # Red on mutant: a stream chunk lands AFTER :turn_canceled.
      {t2, d2, s2} = open_turn(base)
      seed_output(s2, :turn_started, %{prompt: "stream please"})
      seed_output(s2, :item_delta, %{chunk: "half a sen"})
      {:ok, _} = TrailingOutput.interrupt(%{turn_id: t2}, s2, faults: harness)

      err =
        assert_raise ExUnit.AssertionError, fn ->
          Contours.assert_no_trailing_output!(Contours.records(d2), t2)
        end

      assert err.message =~ "trailing output"
      Faults.assert_all_fired!(harness, %{seed: seed, sites: [:trailing_output]})
    end
  end

  describe "escalation conditionality — dead injector :naive_escalate" do
    @tag :unix_only
    test "a cooperative tool short-circuits after signal; killing it anyway fails the red", %{
      base: base,
      seed: seed
    } do
      harness = Faults.new()
      Faults.arm(harness, :naive_escalate)

      # Green on correct: KillLab.spawn_nice is the COOPERATIVE tool (dies on
      # SIGTERM) — previously defined but never exercised by any test. The
      # reference must short-circuit: no wait stage, no kill stage.
      nice_lab = KillLab.spawn_nice(sleep: 30)
      on_exit(fn -> KillLab.reap(nice_lab) end)
      {t1, d1, s1} = open_turn(base)

      {:ok, out1} =
        Reference.interrupt(
          %{turn_id: t1, port: nice_lab.port, os_pid: nice_lab.os_pid, grace_ms: 300},
          s1,
          []
        )

      assert :ok = Contours.assert_short_circuit!(Contours.records(d1), t1)
      refute out1.killed?, "a cooperative tool must not be reported as hard-killed"

      # Red on mutant: NaiveEscalate also sends the real cooperative signal
      # (the tool dies from it, same as the reference case above) but never
      # checks before escalating — it hard-kills the group regardless.
      nice_lab2 = KillLab.spawn_nice(sleep: 30)
      on_exit(fn -> KillLab.reap(nice_lab2) end)
      {t2, d2, s2} = open_turn(base)

      {:ok, _out2} =
        NaiveEscalate.interrupt(
          %{turn_id: t2, port: nice_lab2.port, os_pid: nice_lab2.os_pid, grace_ms: 300},
          s2,
          faults: harness
        )

      err =
        assert_raise ExUnit.AssertionError, fn ->
          Contours.assert_short_circuit!(Contours.records(d2), t2)
        end

      assert err.message =~ "still hard-killed"
      Faults.assert_all_fired!(harness, %{seed: seed, sites: [:naive_escalate]})
    end
  end

  describe "blast radius — bystander survival (safety-critical for kill -9 -<pgid>)" do
    @tag :unix_only
    test "killing the target's process group leaves a bystander in a different group alive", %{
      base: base
    } do
      target = KillLab.spawn_rogue(sleep: 30)
      on_exit(fn -> KillLab.reap(target) end)
      bystander = KillLab.spawn_rogue(sleep: 30)
      on_exit(fn -> KillLab.reap(bystander) end)

      # BEAM makes each Port its own process-group leader (spike:
      # pgid == os_pid, per port) — these two rogue tools sit in DIFFERENT
      # groups even though both are "rogue".
      refute target.os_pid == bystander.os_pid

      {t1, _dir, s1} = open_turn(base)

      {:ok, _out} =
        Reference.interrupt(
          %{turn_id: t1, port: target.port, os_pid: target.os_pid, grace_ms: 50},
          s1,
          []
        )

      assert KillLab.await_dead(target.os_pid), "target top pid survived its own interrupt"
      assert KillLab.await_dead(target.child_pid), "target grandchild survived its own interrupt"

      assert KillLab.alive?(bystander.os_pid),
             "bystander top pid died from an interrupt aimed at a different group — blast radius leaked"

      assert KillLab.alive?(bystander.child_pid),
             "bystander grandchild died from an interrupt aimed at a different group — blast radius leaked"
    end

    @tag :unix_only
    test "group_kill declines the -pgid kill for a pid that is not its own group's leader" do
      lab = KillLab.spawn_rogue(sleep: 30)
      on_exit(fn -> KillLab.reap(lab) end)

      # The grandchild shares its parent's process group (pgid == the top
      # pid's os_pid) but is NOT that group's leader (its own pid != that
      # pgid). Asking to group-kill BY the grandchild's pid must decline the
      # `-pgid` kill and fall back to an individual kill instead — a mis-taken
      # pid must never be able to SIGKILL a whole group by proxy.
      assert {:fallback, _children} = KillLab.group_kill(lab.child_pid)

      KillLab.reap(lab)
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

    test "the pure-journal fault sites are all alive (m1)", %{base: base} do
      harness = Faults.new()
      Faults.arm(harness, :skip_wait)
      Faults.arm(harness, :late_result)
      Faults.arm(harness, :trust_reason)
      Faults.arm(harness, :trailing_output)
      Faults.arm(harness, :wait_kill_transposed)

      {t1, _d1, s1} = open_turn(base)
      {:ok, _} = SkipWait.interrupt(%{turn_id: t1}, s1, faults: harness)

      {t2, _d2, s2} = open_turn(base)
      {:ok, _} = LateResult.interrupt(%{turn_id: t2}, s2, faults: harness)

      {t3, _d3, s3} = open_turn(base)
      {:ok, _} = TrustReason.interrupt(%{turn_id: t3}, s3, faults: harness)

      {t4, _d4, s4} = open_turn(base)
      {:ok, _} = TrailingOutput.interrupt(%{turn_id: t4}, s4, faults: harness)

      {t5, _d5, s5} = open_turn(base)
      {:ok, _} = WaitKillTransposed.interrupt(%{turn_id: t5}, s5, faults: harness)

      fired = Faults.assert_all_fired!(harness, :m1_self_test)
      assert fired[:skip_wait] >= 1
      assert fired[:late_result] >= 1
      assert fired[:trust_reason] >= 1
      assert fired[:trailing_output] >= 1
      assert fired[:wait_kill_transposed] >= 1
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
